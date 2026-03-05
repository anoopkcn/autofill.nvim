local util = require('autofill.util')
local request = require('autofill.transport.request')
local prompt = require('autofill.backend.prompt')

local M = {}

function M.complete(ctx, opts)
  -- Backward compatible: if opts is a function, wrap it
  if type(opts) == 'function' then
    opts = { on_complete = opts }
  end

  local config = require('autofill.config').get()
  local claude_config = config.claude

  local api_key = util.get_api_key(claude_config.api_key_env)
  if not api_key then return end

  local user_message = prompt.build_user_message(ctx)
  util.log('debug', 'Claude prompt:\n' .. user_message)

  local collected = {}
  local on_partial = opts.on_partial

  request.send({
    url = 'https://api.anthropic.com/v1/messages',
    headers = {
      ['content-type'] = 'application/json',
      ['x-api-key'] = api_key,
      ['anthropic-version'] = '2023-06-01',
    },
    body = {
      model = claude_config.model,
      max_tokens = config.max_tokens,
      stream = true,
      system = prompt.SYSTEM_PROMPT,
      messages = {
        { role = 'user', content = user_message },
      },
    },
    timeout_ms = claude_config.timeout_ms,
    stream = true,
    on_data = function(payload)
      local ok, data = pcall(vim.json.decode, payload)
      if not ok then return end
      if data.type == 'content_block_delta' and data.delta and data.delta.text then
        table.insert(collected, data.delta.text)
        if on_partial then
          local text_so_far = table.concat(collected):gsub('^%s*\n', '')
          if text_so_far ~= '' then
            on_partial(text_so_far)
          end
        end
      end
    end,
  }, function(_stdout)
    -- Streaming done; if we collected via on_data, use that.
    -- If not (non-streaming fallback), parse stdout.
    if #collected == 0 and _stdout and _stdout ~= '' then
      local ok, resp = pcall(vim.json.decode, _stdout)
      if ok and resp.content and resp.content[1] then
        table.insert(collected, resp.content[1].text or '')
      end
    end

    local result = table.concat(collected):gsub('^%s*\n', '')

    if result ~= '' then
      util.log('debug', 'Claude response: ' .. result)
      if opts.on_complete then opts.on_complete(result) end
    else
      util.log('debug', 'Claude returned empty response')
    end
  end)
end

return M
