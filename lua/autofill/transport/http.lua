local util = require('autofill.util')

local M = {}

function M._parse_error(raw)
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
  return raw:match('^[^\n]*'):sub(1, 200)
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

  local args = { 'curl', '-s', '-X', 'POST' }

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

  local stdout_buf = ''
  local raw_chunks = {}
  local got_sse = false

  local system_opts = {}

  if stream and on_data then
    system_opts.stdout = function(err, data)
      if err then
        vim.schedule(function()
          if on_error then on_error(err) end
        end)
        return
      end
      if not data then return end
      table.insert(raw_chunks, data)
      stdout_buf = stdout_buf .. data
      while true do
        local nl = stdout_buf:find('\n')
        if not nl then break end
        local line = stdout_buf:sub(1, nl - 1)
        stdout_buf = stdout_buf:sub(nl + 1)
        if line:match('^data: ') then
          got_sse = true
          local payload = line:sub(7)
          if payload ~= '[DONE]' then
            vim.schedule(function()
              on_data(payload)
            end)
          end
        end
      end
    end
  end

  local obj = vim.system(args, system_opts, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local msg = result.stderr or ('curl exited with code ' .. result.code)
        if on_error then on_error(msg) end
        return
      end

      -- In streaming mode, stdout was consumed by the callback
      local output = stream and table.concat(raw_chunks) or result.stdout

      -- If streaming but never got SSE data, the response is likely an error
      if stream and not got_sse and output and output ~= '' then
        local api_msg = M._parse_error(output)
        if on_error then
          on_error(api_msg)
        end
        return
      end

      if on_done then
        on_done(output)
      end
    end)
  end)

  return obj
end

return M
