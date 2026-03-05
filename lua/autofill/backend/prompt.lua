local M = {}

M.SYSTEM_PROMPT = [[You are a code completion engine. Output ONLY the completion text that should be inserted at the cursor position. Do not include any explanation, markdown formatting, or code fences. Do not repeat the text before the cursor. Output only the new text to be inserted.]]

local function trim_text(text, max_chars)
  if not text or #text <= max_chars then
    return text
  end
  return text:sub(1, max_chars) .. '...'
end

function M.build_user_message(ctx)
  local parts = {}

  table.insert(parts, 'File: ' .. (ctx.filename ~= '' and vim.fn.fnamemodify(ctx.filename, ':t') or 'unnamed'))
  table.insert(parts, 'Language: ' .. (ctx.filetype ~= '' and ctx.filetype or 'unknown'))

  -- Related files (neighbors)
  if ctx.neighbors and #ctx.neighbors > 0 then
    table.insert(parts, '')
    table.insert(parts, 'Related files:')
    for _, nb in ipairs(ctx.neighbors) do
      table.insert(parts, '--- ' .. nb.filename .. ' ---')
      table.insert(parts, nb.content)
    end
  end

  -- File outline from LSP symbols
  if ctx.lsp and ctx.lsp.symbols and #ctx.lsp.symbols > 0 then
    table.insert(parts, '')
    table.insert(parts, 'File outline:')
    local count = math.min(15, #ctx.lsp.symbols)
    for i = 1, count do
      local sym = ctx.lsp.symbols[i]
      local entry = '  ' .. sym.kind .. ' ' .. sym.name .. ' (line ' .. sym.line .. ')'
      if sym.container and sym.container ~= '' then
        entry = entry .. ' in ' .. sym.container
      end
      table.insert(parts, entry)
    end
  end

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
        table.insert(parts, '  Line ' .. d.line .. ' [' .. sev .. ']: ' .. trim_text(d.message, 120))
      end
    end
  end

  table.insert(parts, '')
  table.insert(parts, ctx.before_cursor .. '<CURSOR>' .. ctx.after_cursor)

  return table.concat(parts, '\n')
end

return M
