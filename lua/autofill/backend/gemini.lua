local util = require('autofill.util')
local request = require('autofill.transport.request')
local prompt = require('autofill.backend.prompt')

local M = {}

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
  util.log('debug', 'Gemini prompt:\n' .. user_message)

  local url = 'https://generativelanguage.googleapis.com/v1beta/models/'
    .. gemini_config.model
    .. ':streamGenerateContent?alt=sse'

  local collected = {}
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
    stream = true,
    on_error = opts.on_error,
    on_data = function(payload)
      local ok, data = pcall(vim.json.decode, payload)
      if not ok then return end
      if data.candidates
        and data.candidates[1]
        and data.candidates[1].content
        and data.candidates[1].content.parts
      then
        for _, part in ipairs(data.candidates[1].content.parts) do
          if part.text then
            table.insert(collected, part.text)
            if on_partial then
              local text_so_far = table.concat(collected):gsub('^%s*\n', '')
              if text_so_far ~= '' then
                on_partial(text_so_far)
              end
            end
          end
        end
      end
    end,
  }, function(_stdout)
    -- Fallback: if streaming didn't collect anything, parse full response
    if #collected == 0 and _stdout and _stdout ~= '' then
      local ok, resp = pcall(vim.json.decode, _stdout)
      if ok
        and resp.candidates
        and resp.candidates[1]
        and resp.candidates[1].content
        and resp.candidates[1].content.parts
      then
        for _, part in ipairs(resp.candidates[1].content.parts) do
          if part.text then
            table.insert(collected, part.text)
          end
        end
      end
    end

    local result = table.concat(collected):gsub('^%s*\n', '')

    if result ~= '' then
      util.log('debug', 'Gemini response: ' .. result)
      if opts.on_complete then opts.on_complete(result) end
    else
      util.log('debug', 'Gemini returned empty response')
    end
  end)
end

return M
