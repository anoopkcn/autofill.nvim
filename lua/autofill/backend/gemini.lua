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

local function append_response_parts(state, payload, on_partial)
  if not payload
    or not payload.candidates
    or not payload.candidates[1]
    or not payload.candidates[1].content
    or not payload.candidates[1].content.parts
  then
    return
  end

  for _, part in ipairs(payload.candidates[1].content.parts) do
    if part.text then
      append_result(state, part.text, on_partial)
    end
  end
end

function M.complete(ctx, opts)
  -- Backward compatible: if opts is a function, wrap it
  if type(opts) == 'function' then
    opts = { on_complete = opts }
  end
  opts = opts or {}

  local config = require('autofill.config').get()
  local gemini_config = config.gemini

  local api_key, api_key_err = util.get_api_key(gemini_config.api_key_env, { silent = opts.on_error ~= nil })
  if not api_key then
    if opts.on_error then
      opts.on_error(api_key_err)
    end
    return
  end

  local user_message = prompt.build_user_message(ctx)
  util.log('debug', 'Gemini prompt prepared (' .. #user_message .. ' chars)')

  local use_stream = config.streaming_display
  local url = 'https://generativelanguage.googleapis.com/v1beta/models/'
    .. gemini_config.model
    .. (use_stream and ':streamGenerateContent?alt=sse' or ':generateContent')

  local state = { parts = {}, text = '', dirty = false }
  local on_partial = opts.on_partial

  request.send({
    url = url,
    headers = {
      ['content-type'] = 'application/json',
      ['x-goog-api-key'] = api_key,
    },
    body = {
      systemInstruction = {
        parts = { { text = prompt.SYSTEM_PROMPT } },
      },
      contents = {
        {
          role = 'user',
          parts = { { text = user_message } },
        },
      },
      generationConfig = {
        maxOutputTokens = config.max_tokens,
      },
    },
    timeout_ms = gemini_config.timeout_ms,
    stream = use_stream,
    session_key = opts.request_session_key,
    on_error = opts.on_error,
    on_data = function(payload)
      local ok, data = pcall(vim.json.decode, payload)
      if not ok then return end
      append_response_parts(state, data, on_partial)
    end,
  }, function(response)
    local body = response and response.body or ''
    if not use_stream and body ~= '' then
      local ok, resp = pcall(vim.json.decode, body)
      if ok then
        append_response_parts(state, resp)
      end
    end

    local result = trim_result(get_text(state))

    if result ~= '' then
      util.log('debug', 'Gemini response received (' .. #result .. ' chars)')
      if opts.on_complete then opts.on_complete(result) end
    else
      util.log('debug', 'Gemini returned empty response')
    end
  end)
end

return M
