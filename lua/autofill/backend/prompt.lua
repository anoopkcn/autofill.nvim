local M = {}

M.SYSTEM_PROMPT = [[You are a code completion engine. Output ONLY the completion text that should be inserted at the cursor position. Do not include any explanation, markdown formatting, or code fences. Do not repeat the text before the cursor. Output only the new text to be inserted.]]

local function trim_text(text, max_chars)
  text = tostring(text or '')
  max_chars = math.max(max_chars or 0, 0)

  if text == '' or #text <= max_chars then
    return text
  end

  if max_chars == 0 then
    return ''
  end

  if max_chars <= 3 then
    return string.rep('.', max_chars)
  end

  return text:sub(1, max_chars - 3) .. '...'
end

local function join_sections(sections)
  if #sections == 0 then
    return ''
  end
  return table.concat(sections, '\n\n')
end

local function marked_title(title, truncated)
  if truncated then
    return title .. ' (truncated):'
  end
  return title .. ':'
end

local function fit_section_text(section, budget)
  if not section or budget <= 0 then
    return nil
  end

  if #section <= budget then
    return section
  end

  local title, body = section:match('^([^\n]+)\n(.*)$')
  if not title then
    return trim_text(section, budget)
  end

  if not title:find('%(truncated%)', 1, true) then
    title = title:gsub(':$', ' (truncated):')
  end

  local available = budget - #title - 1
  if available <= 0 then
    return trim_text(title, budget)
  end

  return title .. '\n' .. trim_text(body, available)
end

local function build_section(title, lines, max_chars, truncated)
  if not lines or #lines == 0 or max_chars <= 0 then
    return nil
  end

  local body = table.concat(lines, '\n')
  local header = marked_title(title, truncated)
  local text = header .. '\n' .. body
  if #text <= max_chars then
    return text
  end

  header = marked_title(title, true)
  local available = max_chars - #header - 1
  if available <= 0 then
    return trim_text(header, max_chars)
  end

  return header .. '\n' .. trim_text(body, available)
end

local function build_neighbors_section(ctx, prompt_config)
  if not ctx.neighbors or #ctx.neighbors == 0 then
    return nil
  end

  local lines = {}
  local truncated = false
  for i, nb in ipairs(ctx.neighbors) do
    local content = tostring(nb.content or '')
    local file_truncated = nb.is_truncated == true
    if #content > prompt_config.max_neighbor_file_chars then
      content = trim_text(content, prompt_config.max_neighbor_file_chars)
      file_truncated = true
    end

    local header = '--- ' .. nb.filename
    if file_truncated then
      header = header .. ' (truncated)'
      truncated = true
    end
    header = header .. ' ---'

    lines[#lines + 1] = header
    lines[#lines + 1] = content
    if i < #ctx.neighbors then
      lines[#lines + 1] = ''
    end
  end

  return build_section('Related files', lines, prompt_config.max_neighbors_chars, truncated)
end

local function build_outline_section(ctx, prompt_config)
  if not ctx.lsp or not ctx.lsp.symbols or #ctx.lsp.symbols == 0 or prompt_config.max_symbol_count == 0 then
    return nil
  end

  local lines = {}
  local count = math.min(prompt_config.max_symbol_count, #ctx.lsp.symbols)
  local truncated = count < #ctx.lsp.symbols
  for i = 1, count do
    local sym = ctx.lsp.symbols[i]
    local entry = '  ' .. sym.kind .. ' ' .. sym.name .. ' (line ' .. sym.line .. ')'
    if sym.container and sym.container ~= '' then
      entry = entry .. ' in ' .. sym.container
    end
    lines[#lines + 1] = trim_text(entry, 180)
  end

  return build_section('File outline', lines, prompt_config.max_outline_chars, truncated)
end

local function build_scope_section(ctx, prompt_config)
  if not ctx.treesitter or not ctx.treesitter.scopes or #ctx.treesitter.scopes == 0 or prompt_config.max_scope_count == 0 then
    return nil
  end

  local lines = {}
  local count = math.min(prompt_config.max_scope_count, #ctx.treesitter.scopes)
  local truncated = count < #ctx.treesitter.scopes
  for i = 1, count do
    local scope = ctx.treesitter.scopes[i]
    lines[#lines + 1] = trim_text('  ' .. scope.type .. ' (line ' .. scope.line .. '): ' .. scope.header, 180)
  end

  if ctx.treesitter.in_comment then
    lines[#lines + 1] = 'Cursor is inside a comment.'
  end
  if ctx.treesitter.in_string then
    lines[#lines + 1] = 'Cursor is inside a string.'
  end

  return build_section('Scope chain', lines, prompt_config.max_scope_chars, truncated)
end

local function build_diagnostics_section(ctx, prompt_config)
  if not ctx.lsp or not ctx.lsp.diagnostics or #ctx.lsp.diagnostics == 0 or prompt_config.max_diagnostic_count == 0 then
    return nil
  end

  local lines = {}
  local count = math.min(prompt_config.max_diagnostic_count, #ctx.lsp.diagnostics)
  local truncated = count < #ctx.lsp.diagnostics
  for i = 1, count do
    local d = ctx.lsp.diagnostics[i]
    local sev = ({ 'ERROR', 'WARN', 'INFO', 'HINT' })[d.severity] or 'INFO'
    lines[#lines + 1] = '  Line ' .. d.line .. ' [' .. sev .. ']: ' .. trim_text(d.message, 120)
  end

  return build_section('Nearby diagnostics', lines, prompt_config.max_diagnostics_chars, truncated)
end

local function build_context_notes(ctx)
  local lines = {}
  if ctx.is_truncated_before then
    lines[#lines + 1] = 'Context before the cursor was truncated.'
  end
  if ctx.is_truncated_after then
    lines[#lines + 1] = 'Context after the cursor was truncated.'
  end

  if #lines == 0 then
    return nil
  end

  return build_section('Context notes', lines, 400, false)
end

function M.build_user_message(ctx)
  if ctx._user_message then
    return ctx._user_message
  end

  local config = require('autofill.config').get()
  local prompt_config = config.prompt

  local prefix_sections = {
    table.concat({
      'File: ' .. (ctx.filename ~= '' and vim.fn.fnamemodify(ctx.filename, ':t') or 'unnamed'),
      'Language: ' .. (ctx.filetype ~= '' and ctx.filetype or 'unknown'),
    }, '\n'),
  }

  local context_notes = build_context_notes(ctx)
  if context_notes then
    prefix_sections[#prefix_sections + 1] = context_notes
  end

  local cursor_section = ctx.before_cursor .. '<CURSOR>' .. ctx.after_cursor
  local optional_sections = {
    build_neighbors_section(ctx, prompt_config),
    build_outline_section(ctx, prompt_config),
    build_scope_section(ctx, prompt_config),
    build_diagnostics_section(ctx, prompt_config),
  }

  local function render_with(optional)
    local sections = vim.list_extend(vim.deepcopy(prefix_sections), optional)
    sections[#sections + 1] = cursor_section
    return join_sections(sections)
  end

  local selected_sections = {}
  for _, section in ipairs(optional_sections) do
    if section then
      local base_message = render_with(selected_sections)
      local remaining = prompt_config.max_chars - #base_message
      if remaining > 2 then
        local fitted = fit_section_text(section, remaining - 2)
        if fitted and fitted ~= '' then
          selected_sections[#selected_sections + 1] = fitted
        end
      end
    end
  end

  ctx._user_message = render_with(selected_sections)
  return ctx._user_message
end

return M
