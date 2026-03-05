local util = require('autofill.util')
local request = require('autofill.transport.request')

local M = {}

local SYSTEM_PROMPT = [[You are a code completion engine. Output ONLY the completion text that should be inserted at the cursor position. Do not include any explanation, markdown formatting, or code fences. Do not repeat the text before the cursor. Output only the new text to be inserted.]]

local function build_user_message(ctx)
  local parts = {}

  table.insert(parts, 'File: ' .. (ctx.filename ~= '' and vim.fn.fnamemodify(ctx.filename, ':t') or 'unnamed'))
  table.insert(parts, 'Language: ' .. (ctx.filetype ~= '' and ctx.filetype or 'unknown'))

  if ctx.treesitter then
    local ts = ctx.treesitter
    if ts.scopes and #ts.scopes > 0 then
      table.insert(parts, '')
      table.insert(parts, 'Scope chain:')
      for _, scope in ipairs(ts.scopes) do
        table.insert(parts, '  ' .. scope.type .. ' (line ' .. scope.line .. '): ' .. scope.header)
      end
    end
    if ts.in_comment then
      table.insert(parts, 'Cursor is inside a comment.')
    end
    if ts.in_string then
      table.insert(parts, 'Cursor is inside a string.')
    end
  end

  if ctx.lsp then
    local lsp_ctx = ctx.lsp
    if lsp_ctx.diagnostics and #lsp_ctx.diagnostics > 0 then
      table.insert(parts, '')
      table.insert(parts, 'Nearby diagnostics:')
      for _, d in ipairs(lsp_ctx.diagnostics) do
        local sev = ({ 'ERROR', 'WARN', 'INFO', 'HINT' })[d.severity] or 'INFO'
        table.insert(parts, '  Line ' .. d.line .. ' [' .. sev .. ']: ' .. d.message)
      end
    end
  end

  table.insert(parts, '')
  table.insert(parts, ctx.before_cursor .. '<CURSOR>' .. ctx.after_cursor)

  return table.concat(parts, '\n')
end

function M.complete(ctx, callback)
  local config = require('autofill.config').get()
  local claude_config = config.claude

  local api_key = util.get_api_key(claude_config.api_key_env)
  if not api_key then return end

  local user_message = build_user_message(ctx)
  util.log('debug', 'Claude prompt:\n' .. user_message)

  local collected = ''

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
      system = SYSTEM_PROMPT,
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
        collected = collected .. data.delta.text
      end
    end,
  }, function(_stdout)
    -- Streaming done; if we collected via on_data, use that.
    -- If not (non-streaming fallback), parse stdout.
    if collected == '' and _stdout and _stdout ~= '' then
      local ok, resp = pcall(vim.json.decode, _stdout)
      if ok and resp.content and resp.content[1] then
        collected = resp.content[1].text or ''
      end
    end

    -- Trim leading/trailing whitespace artifacts
    collected = collected:gsub('^%s*\n', '')

    if collected ~= '' then
      util.log('debug', 'Claude response: ' .. collected)
      callback(collected)
    else
      util.log('debug', 'Claude returned empty response')
    end
  end)
end

return M
