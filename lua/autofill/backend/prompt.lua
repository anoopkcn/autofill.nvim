local M = {}

M.SYSTEM_PROMPTS = {
  code = [[You are a code completion engine. Continue the code at the cursor. Preserve syntax, indentation, naming, and local style. Fit the completion to both the text before and after the cursor. Output ONLY the text that should be inserted at the cursor. Do not include explanations, markdown, or code fences. Do not repeat the text before the cursor.]],
  prose = [[You are a prose completion engine. Continue the prose or comment at the cursor. Preserve tone, formatting, and local style. Fit the completion to both the text before and after the cursor. Output ONLY the text that should be inserted at the cursor. Do not include explanations, markdown, or code fences. Do not repeat the text before the cursor.]],
}

M.SYSTEM_PROMPT = M.SYSTEM_PROMPTS.code

local PROVIDER_FALLBACK_FIELDS = {
  treesitter = 'treesitter',
  lsp = 'lsp',
  neighbors = 'neighbors',
}

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

local function get_provider_data(ctx, name)
  if ctx.providers and ctx.providers[name] ~= nil then
    return ctx.providers[name]
  end

  if name == 'buffer' then
    return {
      before = ctx.before_cursor or '',
      after = ctx.after_cursor or '',
      is_truncated_before = ctx.is_truncated_before,
      is_truncated_after = ctx.is_truncated_after,
    }
  end

  local field = PROVIDER_FALLBACK_FIELDS[name]
  if field then
    return ctx[field]
  end

  return nil
end

local function build_neighbors_section(neighbors_data, prompt_config)
  if not neighbors_data or #neighbors_data == 0 then
    return nil
  end

  local lines = {}
  local truncated = false
  for i, nb in ipairs(neighbors_data) do
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
    if i < #neighbors_data then
      lines[#lines + 1] = ''
    end
  end

  return build_section('Related files', lines, prompt_config.max_neighbors_chars, truncated)
end

local function build_outline_section(lsp_data, prompt_config)
  if not lsp_data or not lsp_data.symbols or #lsp_data.symbols == 0 or prompt_config.max_symbol_count == 0 then
    return nil
  end

  local lines = {}
  local count = math.min(prompt_config.max_symbol_count, #lsp_data.symbols)
  local truncated = count < #lsp_data.symbols
  for i = 1, count do
    local sym = lsp_data.symbols[i]
    local entry = '  ' .. sym.kind .. ' ' .. sym.name .. ' (line ' .. sym.line .. ')'
    if sym.container and sym.container ~= '' then
      entry = entry .. ' in ' .. sym.container
    end
    lines[#lines + 1] = trim_text(entry, 180)
  end

  return build_section('File outline', lines, prompt_config.max_outline_chars, truncated)
end

local function build_scope_section(treesitter_data, prompt_config)
  if not treesitter_data or not treesitter_data.scopes or #treesitter_data.scopes == 0 or prompt_config.max_scope_count == 0 then
    return nil
  end

  local lines = {}
  local count = math.min(prompt_config.max_scope_count, #treesitter_data.scopes)
  local truncated = count < #treesitter_data.scopes
  for i = 1, count do
    local scope = treesitter_data.scopes[i]
    lines[#lines + 1] = trim_text('  ' .. scope.type .. ' (line ' .. scope.line .. '): ' .. scope.header, 180)
  end

  if treesitter_data.in_comment then
    lines[#lines + 1] = 'Cursor is inside a comment.'
  end
  if treesitter_data.in_string then
    lines[#lines + 1] = 'Cursor is inside a string.'
  end

  return build_section('Scope chain', lines, prompt_config.max_scope_chars, truncated)
end

local function build_diagnostics_section(lsp_data, prompt_config)
  if not lsp_data or not lsp_data.diagnostics or #lsp_data.diagnostics == 0 or prompt_config.max_diagnostic_count == 0 then
    return nil
  end

  local lines = {}
  local count = math.min(prompt_config.max_diagnostic_count, #lsp_data.diagnostics)
  local truncated = count < #lsp_data.diagnostics
  for i = 1, count do
    local d = lsp_data.diagnostics[i]
    local sev = ({ 'ERROR', 'WARN', 'INFO', 'HINT' })[d.severity] or 'INFO'
    lines[#lines + 1] = '  Line ' .. d.line .. ' [' .. sev .. ']: ' .. trim_text(d.message, 120)
  end

  return build_section('Nearby diagnostics', lines, prompt_config.max_diagnostics_chars, truncated)
end

local function build_context_notes(buffer_data)
  local lines = {}
  if buffer_data and buffer_data.is_truncated_before then
    lines[#lines + 1] = 'Context before the cursor was truncated.'
  end
  if buffer_data and buffer_data.is_truncated_after then
    lines[#lines + 1] = 'Context after the cursor was truncated.'
  end

  if #lines == 0 then
    return nil
  end

  return build_section('Context notes', lines, 400, false)
end

local function build_task_section(mode)
  local task = 'Task: Continue the current code at <CURSOR>.'
  if mode == 'prose' then
    task = 'Task: Continue the current prose/comment at <CURSOR>.'
  end
  return task
end

local function prose_filetype(prompt_config, filetype)
  filetype = tostring(filetype or '')
  for _, prose_filetype in ipairs(prompt_config.prose_filetypes or {}) do
    if prose_filetype == filetype then
      return true
    end
  end
  return false
end

local function resolve_mode_with_config(ctx, prompt_config)
  local mode = prompt_config.mode or 'auto'
  if mode == 'code' or mode == 'prose' then
    return mode
  end

  if prose_filetype(prompt_config, ctx.filetype) then
    return 'prose'
  end

  local treesitter_data = get_provider_data(ctx, 'treesitter')
  if treesitter_data and treesitter_data.in_comment then
    return 'prose'
  end

  return 'code'
end

local function build_section_entries(ctx, prompt_config, mode)
  local buffer_data = get_provider_data(ctx, 'buffer')
  local treesitter_data = get_provider_data(ctx, 'treesitter')
  local lsp_data = get_provider_data(ctx, 'lsp')
  local neighbors_data = get_provider_data(ctx, 'neighbors')

  return {
    {
      id = 'metadata',
      required = true,
      text = table.concat({
        'File: ' .. (ctx.filename ~= '' and vim.fn.fnamemodify(ctx.filename, ':t') or 'unnamed'),
        'Language: ' .. (ctx.filetype ~= '' and ctx.filetype or 'unknown'),
      }, '\n'),
    },
    {
      id = 'task',
      required = true,
      text = build_task_section(mode),
    },
    {
      id = 'context_notes',
      required = true,
      text = build_context_notes(buffer_data),
    },
    {
      id = 'neighbors',
      text = build_neighbors_section(neighbors_data, prompt_config),
    },
    {
      id = 'outline',
      text = build_outline_section(lsp_data, prompt_config),
    },
    {
      id = 'scope',
      text = build_scope_section(treesitter_data, prompt_config),
    },
    {
      id = 'diagnostics',
      text = build_diagnostics_section(lsp_data, prompt_config),
    },
    {
      id = 'cursor',
      required = true,
      text = (buffer_data and buffer_data.before or ctx.before_cursor or '') .. '<CURSOR>' .. (buffer_data and buffer_data.after or ctx.after_cursor or ''),
    },
  }
end

local function build_user_message_with_config(ctx, prompt_config, mode)
  local sections = build_section_entries(ctx, prompt_config, mode)

  local final_parts = {}
  local optional_sections = {}
  local cursor_section = ''
  local running_len = 0
  local separator_len = 2

  for _, section in ipairs(sections) do
    if section.text and section.text ~= '' then
      if section.id == 'cursor' then
        cursor_section = section.text
      elseif section.required then
        if running_len > 0 then
          running_len = running_len + separator_len
        end
        final_parts[#final_parts + 1] = section.text
        running_len = running_len + #section.text
      else
        optional_sections[#optional_sections + 1] = section.text
      end
    end
  end

  for _, section in ipairs(optional_sections) do
    local base_len = running_len + separator_len + #cursor_section + separator_len
    local remaining = prompt_config.max_chars - base_len
    if remaining > 2 then
      local fitted = fit_section_text(section, remaining - separator_len)
      if fitted and fitted ~= '' then
        final_parts[#final_parts + 1] = fitted
        running_len = running_len + separator_len + #fitted
      end
    end
  end

  final_parts[#final_parts + 1] = cursor_section
  return join_sections(final_parts)
end

function M.resolve_mode(ctx, prompt_config)
  if prompt_config == nil then
    prompt_config = require('autofill.config').get().prompt or {}
  end
  return resolve_mode_with_config(ctx or {}, prompt_config)
end

function M.build_user_message(ctx, mode)
  local prompt_config = require('autofill.config').get().prompt or {}
  return build_user_message_with_config(ctx, prompt_config, mode or resolve_mode_with_config(ctx or {}, prompt_config))
end

function M.build_request(ctx)
  local config = require('autofill.config').get()
  local prompt_config = config.prompt or {}
  local mode = resolve_mode_with_config(ctx or {}, prompt_config)
  local temperature_config = config.temperature or {}

  return {
    mode = mode,
    system_prompt = M.SYSTEM_PROMPTS[mode] or M.SYSTEM_PROMPTS.code,
    user_message = build_user_message_with_config(ctx, prompt_config, mode),
    temperature = temperature_config[mode],
  }
end

return M
