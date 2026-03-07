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
  if not ok or not resp then
    return ''
  end

  if type(resp.output_text) == 'string' and resp.output_text ~= '' then
    return resp.output_text
  end

  if type(resp.output) ~= 'table' then
    return ''
  end

  local text = ''
  for _, item in ipairs(resp.output) do
    if item and item.type == 'message' and type(item.content) == 'table' then
      for _, part in ipairs(item.content) do
        if part and part.type == 'output_text' and part.text then
          text = text .. part.text
        end
      end
    end
  end

  return text
end

local function append_stream_payload(state, payload, on_partial)
  local ok, data = pcall(vim.json.decode, payload)
  if not ok or type(data) ~= 'table' then
    return
  end

  if data.type == 'response.output_text.delta' and data.delta then
    append_result(state, data.delta, on_partial)
    return
  end

  if data.type == 'response.output_text.done' and #state.parts == 0 and data.text then
    append_result(state, data.text, on_partial)
  end
end

function M.complete(ctx, opts)
  -- Backward compatible: if opts is a function, wrap it
  if type(opts) == 'function' then
    opts = { on_complete = opts }
  end
  opts = opts or {}

  local config = require('autofill.config').get()
  local openai_config = config.openai

  local api_key, api_key_err = util.get_api_key(openai_config.api_key_env, { silent = opts.on_error ~= nil })
  if not api_key then
    if opts.on_error then
      opts.on_error(api_key_err)
    end
    return
  end

  local prompt_request = opts.prompt_request or prompt.build_request(ctx)
  local user_message = prompt_request.user_message
  util.log('debug', 'OpenAI prompt prepared (' .. #user_message .. ' chars, mode=' .. prompt_request.mode .. ')')

  local use_stream = config.streaming_display
  local state = { parts = {}, text = '', dirty = false }
  local on_partial = opts.on_partial

  local body = {
    model = openai_config.model,
    instructions = prompt_request.system_prompt,
    input = user_message,
    max_output_tokens = config.max_tokens,
    stream = use_stream,
    text = {
      format = { type = 'text' },
    },
  }
  if prompt_request.temperature ~= nil then
    body.temperature = prompt_request.temperature
  end

  request.send({
    url = 'https://api.openai.com/v1/responses',
    headers = {
      ['content-type'] = 'application/json',
      ['authorization'] = 'Bearer ' .. api_key,
    },
    body = body,
    timeout_ms = openai_config.timeout_ms,
    stream = use_stream,
    session_key = opts.request_session_key,
    on_error = opts.on_error,
    on_data = function(payload)
      append_stream_payload(state, payload, on_partial)
    end,
  }, function(response)
    local body = response and response.body or ''
    if not use_stream and body ~= '' then
      state.parts[#state.parts + 1] = extract_response_text(body)
      state.dirty = true
    end

    local result = trim_result(get_text(state))

    if result ~= '' then
      util.log('debug', 'OpenAI response received (' .. #result .. ' chars)')
      if opts.on_complete then opts.on_complete(result) end
    else
      util.log('debug', 'OpenAI returned empty response')
    end
  end)
end

return M
