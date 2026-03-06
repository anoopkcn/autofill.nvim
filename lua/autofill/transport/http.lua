local M = {}
local STATUS_MARKER = '\n__AUTOFILL_HTTP_STATUS__:'
local STATUS_PATTERN = STATUS_MARKER .. '(%d%d%d)\n?$'
local ERROR_MT = {
  __tostring = function(err)
    return err.message or 'Request failed'
  end,
}

local function make_error(kind, fields)
  fields = fields or {}
  fields.ok = false
  fields.kind = kind
  return setmetatable(fields, ERROR_MT)
end

local function split_http_output(raw)
  raw = raw or ''

  local status = tonumber(raw:match(STATUS_PATTERN))
  if status then
    raw = raw:gsub(STATUS_PATTERN, '', 1)
  end

  return raw, status
end

local function format_transport_message(result)
  local stderr = vim.trim(result.stderr or '')
  if stderr ~= '' then
    return stderr:match('^[^\n]*') or stderr
  end
  return 'curl exited with code ' .. tostring(result.code)
end

local function format_http_message(status, body)
  local api_msg = M._parse_error(body or '')
  if api_msg and api_msg ~= '' then
    return 'HTTP ' .. tostring(status) .. ': ' .. api_msg
  end
  return 'HTTP ' .. tostring(status)
end

local function make_success(status, body, stderr)
  return {
    ok = true,
    status = status,
    body = body or '',
    stderr = stderr or '',
  }
end

function M._parse_error(raw)
  if not raw or raw == '' then
    return ''
  end

  local ok, data = pcall(vim.json.decode, raw)
  if ok then
    -- Anthropic: { error: { message: "..." } }
    if data.error and data.error.message then
      return data.error.message
    end
    -- OpenAI-style: { error: { message: "..." } }  (same shape)
    -- Gemini: { error: { message: "...", status: "..." } }
    if data.error and type(data.error) == 'string' then
      return data.error
    end
  end
  -- Fallback: first line of raw output
  local first_line = raw:match('^[^\n]*') or raw
  return first_line:sub(1, 200)
end

local function normalize_sse_chunk(data)
  if not data or data == '' then
    return ''
  end
  data = data:gsub('\r\n', '\n')
  return data:gsub('\r', '\n')
end

local function parse_sse_event(block)
  local event = {
    data_lines = {},
  }

  for _, line in ipairs(vim.split(block, '\n', { plain = true })) do
    if line ~= '' and line:sub(1, 1) ~= ':' then
      local field, value = line:match('^([^:]+):?(.*)$')
      if field and field ~= '' then
        if value:sub(1, 1) == ' ' then
          value = value:sub(2)
        end

        if field == 'data' then
          event.data_lines[#event.data_lines + 1] = value
        elseif field == 'event' then
          event.event = value
        elseif field == 'id' then
          event.id = value
        elseif field == 'retry' then
          event.retry = tonumber(value) or value
        end
      end
    end
  end

  if #event.data_lines == 0 and not event.event and not event.id and not event.retry then
    return nil
  end

  event.data = table.concat(event.data_lines, '\n')
  event.data_lines = nil
  return event
end

local function flush_sse_events(buffer_str, opts)
  opts = opts or {}

  local event_count = 0
  while true do
    local sep_start, sep_end = buffer_str:find('\n\n', 1, true)
    if not sep_start then break end

    local block = buffer_str:sub(1, sep_start - 1)
    buffer_str = buffer_str:sub(sep_end + 1)

    local event = parse_sse_event(block)
    if event then
      event_count = event_count + 1
      if opts.on_event then
        opts.on_event(event)
      end
    end
  end

  if opts.final and buffer_str ~= '' then
    local event = parse_sse_event(buffer_str)
    buffer_str = ''
    if event then
      event_count = event_count + 1
      if opts.on_event then
        opts.on_event(event)
      end
    end
  end

  return buffer_str, event_count
end

function M.request(opts)
  local url = opts.url
  local headers = opts.headers or {}
  local body = opts.body
  local timeout_ms = opts.timeout_ms or 10000
  local on_data = opts.on_data
  local on_done = opts.on_done
  local on_error = opts.on_error
  local stream = opts.stream or false

  local args = {
    'curl',
    '-sS',
    '-X',
    'POST',
    '-w',
    STATUS_MARKER .. '%{http_code}\n',
  }

  for key, value in pairs(headers) do
    table.insert(args, '-H')
    table.insert(args, key .. ': ' .. value)
  end

  if body then
    table.insert(args, '-d')
    table.insert(args, vim.json.encode(body))
  end

  table.insert(args, '--max-time')
  table.insert(args, tostring(math.ceil(timeout_ms / 1000)))

  if stream then
    table.insert(args, '-N')
  end

  table.insert(args, url)

  local sse_buf_parts = {}
  local sse_buf_str = ''
  local raw_chunks = {}
  local got_sse = false
  local stream_error = nil

  local system_opts = {}
  local function handle_sse_event(event)
    got_sse = true
    if on_data and event.data and event.data ~= '' and event.data ~= '[DONE]' then
      vim.schedule(function()
        on_data(event.data, event)
      end)
    end
  end

  if stream then
    system_opts.stdout = function(err, data)
      if err then
        stream_error = tostring(err)
        return
      end
      if not data then return end
      table.insert(raw_chunks, data)
      local normalized = normalize_sse_chunk(data)
      if normalized:find('\n\n', 1, true) then
        sse_buf_parts[#sse_buf_parts + 1] = normalized
        sse_buf_str = table.concat(sse_buf_parts)
        sse_buf_parts = {}
        sse_buf_str = flush_sse_events(sse_buf_str, { on_event = handle_sse_event })
        if sse_buf_str ~= '' then
          sse_buf_parts[1] = sse_buf_str
          sse_buf_str = ''
        end
      else
        sse_buf_parts[#sse_buf_parts + 1] = normalized
      end
    end
  end

  local obj = vim.system(args, system_opts, function(result)
    vim.schedule(function()
      local output = stream and table.concat(raw_chunks) or result.stdout or ''
      local local_status
      output, local_status = split_http_output(output)

      if stream then
        if #sse_buf_parts > 0 then
          sse_buf_str = table.concat(sse_buf_parts)
          sse_buf_parts = {}
        end
        local flushed_events
        sse_buf_str, flushed_events = flush_sse_events(split_http_output(sse_buf_str), {
          final = true,
          on_event = handle_sse_event,
        })
        if flushed_events > 0 then
          got_sse = true
        end
      end

      if stream_error then
        if on_error then
          on_error(make_error('transport', {
            code = result.code,
            status = local_status,
            body = output,
            stderr = result.stderr or stream_error,
            message = stream_error,
          }))
        end
        return
      end

      if result.code ~= 0 then
        if on_error then
          on_error(make_error('transport', {
            code = result.code,
            status = local_status,
            body = output,
            stderr = result.stderr or '',
            message = format_transport_message(result),
          }))
        end
        return
      end

      if local_status and (local_status < 200 or local_status >= 300) then
        if on_error then
          on_error(make_error('http', {
            status = local_status,
            body = output,
            stderr = result.stderr or '',
            message = format_http_message(local_status, output),
          }))
        end
        return
      end

      -- If streaming but never got SSE data, the response is likely an error
      if stream and not got_sse and output and output ~= '' then
        if on_error then
          on_error(make_error('protocol', {
            status = local_status,
            body = output,
            stderr = result.stderr or '',
            message = 'Expected streaming response but received non-SSE body: ' .. M._parse_error(output),
          }))
        end
        return
      end

      if on_done then
        on_done(make_success(local_status, output, result.stderr))
      end
    end)
  end)

  return obj
end

return M
