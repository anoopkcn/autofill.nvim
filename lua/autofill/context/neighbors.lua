local utf8 = require('autofill.utf8')

local M = {}

local import_cache = {}
local candidate_cache = {}
local snapshot_cache = {}
local candidate_generation = 0
local IMPORT_SCAN_LINES = 80

local SUPPORTED_IMPORT_FILETYPES = {
  go = true,
  javascript = true,
  javascriptreact = true,
  lua = true,
  python = true,
  rust = true,
  typescript = true,
  typescriptreact = true,
}

local function get_changedtick(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return -1
  end
  return vim.api.nvim_buf_get_changedtick(bufnr)
end

local function add_import_name(names, ordered, raw_name, mode)
  if type(raw_name) ~= 'string' then return end

  local name = vim.trim(raw_name)
  if name == '' then return end

  if mode == 'path' then
    name = name:match('([^/\\]+)$') or name
    name = name:gsub('%.[^.]+$', '')
  elseif mode == 'module' then
    name = name:gsub('::', '.')
    name = name:match('([^.]+)$') or name
  end

  if name == '' or names[name] then
    return
  end

  names[name] = true
  ordered[#ordered + 1] = name
end

local function strip_line_comments(text, prefix)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local start = line:find(prefix, 1, true)
    if start then
      line = line:sub(1, start - 1)
    end
    out[#out + 1] = line
  end
  return table.concat(out, '\n')
end

local function sanitize_import_text(filetype, text)
  if filetype == 'javascript'
    or filetype == 'javascriptreact'
    or filetype == 'typescript'
    or filetype == 'typescriptreact'
    or filetype == 'go'
    or filetype == 'rust'
  then
    text = text:gsub('/%*.-%*/', '')
    text = strip_line_comments(text, '//')
  elseif filetype == 'lua' then
    text = strip_line_comments(text, '--')
  elseif filetype == 'python' then
    text = strip_line_comments(text, '#')
  end

  return text
end

local function extract_javascript_imports(text, names, ordered)
  local pending = nil

  local function try_statement(statement)
    local spec = statement:match('^import%s+.-from%s+[\'"]([^\'"]+)[\'"]')
      or statement:match('^export%s+.-from%s+[\'"]([^\'"]+)[\'"]')
      or statement:match('^import%s*[\'"]([^\'"]+)[\'"]')
    if spec then
      add_import_name(names, ordered, spec, 'path')
      return true
    end
    return false
  end

  for line in text:gmatch('[^\n]+') do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      if pending then
        pending = pending .. ' ' .. trimmed
        if try_statement(pending) then
          pending = nil
        end
      elseif trimmed:match('^import%s') or trimmed:match('^export%s') then
        if not try_statement(trimmed) then
          pending = trimmed
        end
      end

      for spec in trimmed:gmatch('require%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%)') do
        add_import_name(names, ordered, spec, 'path')
      end
      for spec in trimmed:gmatch('import%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%)') do
        add_import_name(names, ordered, spec, 'path')
      end
    end
  end
end

local function extract_lua_imports(text, names, ordered)
  for spec in text:gmatch('require%s*%(%s*[\'"]([^\'"]+)[\'"]%s*%)') do
    add_import_name(names, ordered, spec, 'module')
  end
  for spec in text:gmatch('require%s+[\'"]([^\'"]+)[\'"]') do
    add_import_name(names, ordered, spec, 'module')
  end
end

local function extract_python_imports(text, names, ordered)
  for line in text:gmatch('[^\n]+') do
    local from_module = line:match('^%s*from%s+([%w_%.]+)%s+import%s+')
    if from_module then
      add_import_name(names, ordered, from_module, 'module')
    end

    local import_clause = line:match('^%s*import%s+([%w_%.%s,]+)')
    if import_clause then
      for module in import_clause:gmatch('([%w_%.]+)') do
        add_import_name(names, ordered, module, 'module')
      end
    end
  end
end

local function extract_go_imports(text, names, ordered)
  local in_block = false

  for line in text:gmatch('[^\n]+') do
    if line:match('^%s*import%s*%(%s*$') then
      in_block = true
    elseif in_block then
      if line:match('^%s*%)') then
        in_block = false
      else
        for spec in line:gmatch('[\'"`]([^\'"`]+)[\'"`]') do
          add_import_name(names, ordered, spec, 'path')
        end
      end
    else
      local spec = line:match('^%s*import%s+[_%.%w]*%s*[\'"`]([^\'"`]+)[\'"`]')
      if spec then
        add_import_name(names, ordered, spec, 'path')
      end
    end
  end
end

local function extract_rust_imports(text, names, ordered)
  for line in text:gmatch('[^\n]+') do
    local path = line:match('^%s*use%s+([^;]+);')
    if path then
      path = path:gsub('%s+as%s+[%w_]+$', '')
      path = path:gsub('::%b{}', '')
      add_import_name(names, ordered, path, 'module')
    end

    local module = line:match('^%s*pub%s+mod%s+([%w_]+)%s*;')
      or line:match('^%s*mod%s+([%w_]+)%s*;')
    if module then
      add_import_name(names, ordered, module, 'module')
    end
  end
end

local function extract_import_names(filetype, text)
  local names = {}
  local ordered = {}

  if not SUPPORTED_IMPORT_FILETYPES[filetype] then
    return names, ordered
  end

  text = sanitize_import_text(filetype, text)

  if filetype == 'javascript'
    or filetype == 'javascriptreact'
    or filetype == 'typescript'
    or filetype == 'typescriptreact'
  then
    extract_javascript_imports(text, names, ordered)
  elseif filetype == 'lua' then
    extract_lua_imports(text, names, ordered)
  elseif filetype == 'python' then
    extract_python_imports(text, names, ordered)
  elseif filetype == 'go' then
    extract_go_imports(text, names, ordered)
  elseif filetype == 'rust' then
    extract_rust_imports(text, names, ordered)
  end

  return names, ordered
end

local function get_import_names(bufnr)
  local changedtick = get_changedtick(bufnr)
  local cached = import_cache[bufnr]
  if cached and cached.changedtick == changedtick then
    return cached.names, cached.signature
  end

  local filetype = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, IMPORT_SCAN_LINES, false)
  local text = table.concat(lines, '\n')
  local names, ordered = extract_import_names(filetype, text)
  table.sort(ordered)
  local signature = table.concat(ordered, ',')
  import_cache[bufnr] = {
    changedtick = changedtick,
    names = names,
    signature = signature,
  }

  return names, signature
end

local function score_buffer(buf, current_bufnr, current_dir, current_ft, import_names)
  if buf.bufnr == current_bufnr then return -1 end

  local name = buf.name
  if not name or name == '' then return -1 end

  local score = 0

  -- Same directory bonus
  local dir = vim.fn.fnamemodify(name, ':h')
  if dir == current_dir then
    score = score + 3
  end

  -- Same filetype bonus
  local ft = vim.bo[buf.bufnr].filetype
  if ft == current_ft then
    score = score + 2
  end

  -- Import detection bonus
  local basename = vim.fn.fnamemodify(name, ':t:r')
  if import_names[basename] then
    score = score + 5
  end

  return score
end

local function build_candidates(bufnr, current_dir, current_ft, import_names)
  local bufs = vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })
  local candidates = {}

  for _, buf in ipairs(bufs) do
    local s = score_buffer(buf, bufnr, current_dir, current_ft, import_names)
    if s >= 0 then
      table.insert(candidates, { buf = buf, score = s })
    end
  end

  table.sort(candidates, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (a.buf.lastused or 0) > (b.buf.lastused or 0)
  end)

  return candidates
end

local function get_candidates(bufnr, current_dir, current_ft, import_names, import_signature)
  local cached = candidate_cache[bufnr]
  if cached
    and cached.generation == candidate_generation
    and cached.import_signature == import_signature
    and cached.current_dir == current_dir
    and cached.current_ft == current_ft
  then
    return cached.candidates
  end

  local candidates = build_candidates(bufnr, current_dir, current_ft, import_names)
  candidate_cache[bufnr] = {
    generation = candidate_generation,
    import_signature = import_signature,
    current_dir = current_dir,
    current_ft = current_ft,
    candidates = candidates,
  }

  return candidates
end

local function get_snapshot(buf, budget)
  if not buf or not buf.bufnr or not vim.api.nvim_buf_is_valid(buf.bufnr) then
    return nil
  end

  local changedtick = get_changedtick(buf.bufnr)
  local cached = snapshot_cache[buf.bufnr]
  if cached and cached.changedtick == changedtick and cached.budget == budget then
    return cached.snapshot
  end

  local lines = vim.api.nvim_buf_get_lines(buf.bufnr, 0, 40, false)
  local content = table.concat(lines, '\n')
  if #content > budget then
    content = utf8.safe_sub_left(content, budget)
  end

  local snapshot = {
    filename = vim.fn.fnamemodify(buf.name, ':t'),
    content = content,
  }

  snapshot_cache[buf.bufnr] = {
    changedtick = changedtick,
    budget = budget,
    snapshot = snapshot,
  }

  return snapshot
end

function M.get_context(bufnr)
  local config = require('autofill.config').get()
  local nb_config = config.neighbors
  if not nb_config or not nb_config.enabled then return nil end

  local current_name = vim.api.nvim_buf_get_name(bufnr)
  local current_dir = vim.fn.fnamemodify(current_name, ':h')
  local current_ft = vim.bo[bufnr].filetype
  local import_names, import_signature = get_import_names(bufnr)
  local candidates = get_candidates(bufnr, current_dir, current_ft, import_names, import_signature)

  local max_files = nb_config.max_files or 2
  if max_files <= 0 then return nil end

  local total_budget = nb_config.budget or 2000
  local per_file_budget = math.max(1, math.floor(total_budget / max_files))

  local neighbors = {}
  for i = 1, math.min(max_files, #candidates) do
    local snapshot = get_snapshot(candidates[i].buf, per_file_budget)
    if snapshot then
      neighbors[#neighbors + 1] = snapshot
    end
  end

  if #neighbors == 0 then return nil end
  return neighbors
end

function M.get_revision(bufnr)
  local _, import_signature = get_import_names(bufnr)
  return table.concat({
    'imports=',
    import_signature or '',
    ':candidates=',
    tostring(candidate_generation),
  })
end

function M.mark_candidates_dirty()
  candidate_generation = candidate_generation + 1
end

function M.clear(bufnr)
  import_cache[bufnr] = nil
  candidate_cache[bufnr] = nil
  snapshot_cache[bufnr] = nil
end

return M
