local util = require('autofill.util')
local request = require('autofill.transport.request')
local prompt = require('autofill.backend.prompt')

local M = {}

local function trim_result(text)
  return (text or ''):gsub('^%s*\n', '')
end

local function get_text(state)
  if state.dirty then
    state.text = table.concat(state.parts)
    state.dirty = false
  end
  return state.text
end

local function append_result(state, chunk, on_partial)
  if not chunk or chunk == '' then return end

  state.parts[#state.parts + 1] = chunk
  state.dirty = true
  if on_partial then
    local partial = trim_result(get_text(state))
    if partial ~= '' then
      on_partial(partial)
    end
  end
end

local function extract_response_text(body)
  local ok, resp = pcall(vim.json.decode, body)
  if not ok or not resp.content then
    return ''
  end

  local text = ''
  for _, block in ipairs(resp.content) do
    if block and block.text then
      text = text .. block.text
    end
  end
  return text
end

function M.complete(ctx, opts)
  -- Backward compatible: if opts is a function, wrap it
  if type(opts) == 'function' then
    opts = { on_complete = opts }
  end
  opts = opts or {}

  local config = require('autofill.config').get()
  local claude_config = config.claude

  local api_key, api_key_err = util.get_api_key(claude_config.api_key_env, { silent = opts.on_error ~= nil })
  if not api_key then
    if opts.on_error then
      opts.on_error(api_key_err)
    end
    return
  end

  local prompt_request = opts.prompt_request or prompt.build_request(ctx)
  local user_message = prompt_request.user_message
  util.log('debug', 'Claude prompt prepared (' .. #user_message .. ' chars, mode=' .. prompt_request.mode .. ')')

  local use_stream = config.streaming_display
  local state = { parts = {}, text = '', dirty = false }
  local on_partial = opts.on_partial

  local body = {
    model = claude_config.model,
    max_tokens = config.max_tokens,
    stream = use_stream,
    system = prompt_request.system_prompt,
    messages = {
      { role = 'user', content = user_message },
    },
  }
  if prompt_request.temperature ~= nil then
    body.temperature = prompt_request.temperature
  end

  request.send({
    url = 'https://api.anthropic.com/v1/messages',
    headers = {
      ['content-type'] = 'application/json',
      ['x-api-key'] = api_key,
      ['anthropic-version'] = '2023-06-01',
    },
    body = body,
    timeout_ms = claude_config.timeout_ms,
    stream = use_stream,
    session_key = opts.request_session_key,
    on_error = opts.on_error,
    on_data = function(payload)
      local ok, data = pcall(vim.json.decode, payload)
      if not ok then return end
      if data.type == 'content_block_delta' and data.delta and data.delta.text then
        append_result(state, data.delta.text, on_partial)
      end
    end,
  }, function(response)
    local body = response and response.body or ''
    if not use_stream and body ~= '' then
      state.parts[#state.parts + 1] = extract_response_text(body)
      state.dirty = true
    end

    local result = trim_result(get_text(state))

    if result ~= '' then
      util.log('debug', 'Claude response received (' .. #result .. ' chars)')
      if opts.on_complete then opts.on_complete(result) end
    else
      util.log('debug', 'Claude returned empty response')
    end
  end)
end

return M
