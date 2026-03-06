local util = require('autofill.util')
local request = require('autofill.transport.request')
local prompt = require('autofill.backend.prompt')

local M = {}

local DEFAULT_BASE_URL = 'https://api.helmholtz-blablador.fz-juelich.de/v1'

local function trim_result(text)
  return (text or ''):gsub('^%s*\n', '')
end

local function append_result(state, chunk, on_partial)
  if not chunk or chunk == '' then return end

  state.text = state.text .. chunk
  if on_partial then
    local partial = trim_result(state.text)
    if partial ~= '' then
      on_partial(partial)
    end
  end
end

local function normalize_base_url(url)
  url = tostring(url or DEFAULT_BASE_URL)
  return (url:gsub('/+$', ''))
end

local function extract_content_text(content)
  if type(content) == 'string' then
    return content
  end

  if type(content) ~= 'table' then
    return ''
  end

  if type(content.text) == 'string' then
    return content.text
  end

  local text = ''
  for _, item in ipairs(content) do
    if type(item) == 'string' then
      text = text .. item
    elseif type(item) == 'table' and type(item.text) == 'string' then
      text = text .. item.text
    end
  end

  return text
end

local function extract_choice_text(choice)
  if type(choice) ~= 'table' then
    return ''
  end

  if choice.message and choice.message.content then
    return extract_content_text(choice.message.content)
  end

  if choice.delta and choice.delta.content then
    return extract_content_text(choice.delta.content)
  end

  return ''
end

local function extract_response_text(body)
  local ok, resp = pcall(vim.json.decode, body)
  if not ok or type(resp) ~= 'table' or type(resp.choices) ~= 'table' then
    return ''
  end

  local text = ''
  for _, choice in ipairs(resp.choices) do
    text = text .. extract_choice_text(choice)
  end
  return text
end

local function append_stream_payload(state, payload, on_partial)
  local ok, data = pcall(vim.json.decode, payload)
  if not ok or type(data) ~= 'table' or type(data.choices) ~= 'table' then
    return
  end

  local chunk = extract_choice_text(data.choices[1])
  append_result(state, chunk, on_partial)
end

function M.complete(ctx, opts)
  if type(opts) == 'function' then
    opts = { on_complete = opts }
  end
  opts = opts or {}

  local config = require('autofill.config').get()
  local blablador_config = config.blablador

  local api_key, api_key_err = util.get_api_key(blablador_config.api_key_env, { silent = opts.on_error ~= nil })
  if not api_key then
    if opts.on_error then
      opts.on_error(api_key_err)
    end
    return
  end

  local user_message = prompt.build_user_message(ctx)
  util.log('debug', 'Blablador prompt prepared (' .. #user_message .. ' chars)')

  local use_stream = config.streaming_display
  local state = { text = '' }
  local on_partial = opts.on_partial

  request.send({
    url = normalize_base_url(blablador_config.base_url) .. '/chat/completions',
    headers = {
      ['content-type'] = 'application/json',
      ['authorization'] = 'Bearer ' .. api_key,
    },
    body = {
      model = blablador_config.model,
      messages = {
        { role = 'system', content = prompt.SYSTEM_PROMPT },
        { role = 'user', content = user_message },
      },
      max_tokens = config.max_tokens,
      stream = use_stream,
    },
    timeout_ms = blablador_config.timeout_ms,
    stream = use_stream,
    session_key = opts.request_session_key,
    on_error = opts.on_error,
    on_data = function(payload)
      append_stream_payload(state, payload, on_partial)
    end,
  }, function(response)
    local body = response and response.body or ''
    if not use_stream and body ~= '' then
      state.text = state.text .. extract_response_text(body)
    end

    local result = trim_result(state.text)

    if result ~= '' then
      util.log('debug', 'Blablador response received (' .. #result .. ' chars)')
      if opts.on_complete then opts.on_complete(result) end
    else
      util.log('debug', 'Blablador returned empty response')
    end
  end)
end

return M
