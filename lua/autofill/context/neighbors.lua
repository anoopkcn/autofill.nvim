local utf8 = require('autofill.utf8')

local M = {}

local import_cache = {}
local candidate_cache = {}
local snapshot_cache = {}
local candidate_generation = 0
local IMPORT_SCAN_LINES = 80
local SNAPSHOT_LINE_LIMIT = 40
local SNAPSHOT_CACHE_MAX = 32

local readdir_cache = {}
local READDIR_TTL_MS = 3000

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

local FILETYPE_EXTENSIONS = {
  go = { 'go' },
  javascript = { 'js', 'mjs', 'cjs', 'jsx' },
  javascriptreact = { 'jsx', 'js', 'mjs', 'cjs' },
  lua = { 'lua' },
  python = { 'py' },
  rust = { 'rs' },
  typescript = { 'ts', 'tsx', 'js', 'mjs', 'cjs' },
  typescriptreact = { 'tsx', 'ts', 'jsx', 'js' },
}

local function get_changedtick(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return -1
  end
  return vim.api.nvim_buf_get_changedtick(bufnr)
end

local function normalize_path(path)
  if not path or path == '' then
    return ''
  end
  return vim.fs.normalize(path)
end

local function current_dir_for_path(path)
  if not path or path == '' then
    return ''
  end
  return normalize_path(vim.fn.fnamemodify(path, ':h'))
end

local function get_readdir(dir)
  local cached = readdir_cache[dir]
  if cached and (vim.uv.now() - cached.time) < READDIR_TTL_MS then
    return cached.entries
  end
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok or type(entries) ~= 'table' then entries = {} end
  readdir_cache[dir] = { entries = entries, time = vim.uv.now() }
  return entries
end

local function basename_without_extension(path)
  return vim.fn.fnamemodify(path, ':t:r')
end

local function allowed_extension_set(current_name, current_ft)
  local seen = {}

  local current_ext = current_name:match('%.([^./\\]+)$')
  if current_ext and current_ext ~= '' then
    seen[current_ext] = true
  end

  for _, ext in ipairs(FILETYPE_EXTENSIONS[current_ft] or {}) do
    seen[ext] = true
  end

  return seen
end

local function file_signature(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime then
    return nil
  end

  return table.concat({
    tostring(stat.size or 0),
    ':',
    tostring(stat.mtime.sec or 0),
    ':',
    tostring(stat.mtime.nsec or 0),
  })
end

local function directory_signature(dir, extension_set, scan_limit)
  if not dir or dir == '' then
    return ''
  end

  local entries = get_readdir(dir)
  if #entries == 0 then
    return ''
  end

  table.sort(entries)

  local parts = {}
  local added = 0
  for _, entry in ipairs(entries) do
    local ext = entry:match('%.([^./\\]+)$')
    if ext and extension_set[ext] then
      local path = normalize_path(dir .. '/' .. entry)
      local signature = file_signature(path)
      if signature then
        parts[#parts + 1] = entry .. ':' .. signature
        added = added + 1
        if added >= scan_limit then
          break
        end
      end
    end
  end

  return table.concat(parts, '|')
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

local function score_candidate(path, current_dir, same_filetype, import_names)
  local name = normalize_path(path)
  if name == '' then
    return -1
  end

  local score = 0

  if current_dir ~= '' and current_dir_for_path(name) == current_dir then
    score = score + 3
  end

  if same_filetype then
    score = score + 2
  end

  local basename = basename_without_extension(name)
  if import_names[basename] then
    score = score + 5
  end

  return score
end

local function build_loaded_candidates(bufnr, current_name, current_dir, current_ft, import_names, bufinfo)
  local bufs = bufinfo or vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })
  local candidates = {}
  local seen_paths = {}

  for _, buf in ipairs(bufs) do
    if buf.bufnr ~= bufnr then
      local path = normalize_path(buf.name)
      if path ~= '' and path ~= current_name then
        local score = score_candidate(path, current_dir, vim.bo[buf.bufnr].filetype == current_ft, import_names)
        if score >= 0 then
          candidates[#candidates + 1] = {
            kind = 'buffer',
            bufnr = buf.bufnr,
            path = path,
            score = score,
            lastused = buf.lastused or 0,
          }
          seen_paths[path] = true
        end
      end
    end
  end

  return candidates, seen_paths
end

local function loaded_buffer_signature(current_bufnr, bufinfo)
  local bufs = bufinfo or vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })
  local parts = {}

  for _, buf in ipairs(bufs) do
    if buf.bufnr ~= current_bufnr then
      local path = normalize_path(buf.name)
      if path ~= '' then
        parts[#parts + 1] = table.concat({
          path,
          ':',
          vim.bo[buf.bufnr].filetype or '',
          ':',
          tostring(buf.lastused or 0),
          ':',
          tostring(get_changedtick(buf.bufnr)),
        })
      end
    end
  end

  table.sort(parts)
  return table.concat(parts, '|')
end

local function build_disk_candidates(current_name, current_dir, import_names, extension_set, seen_paths, scan_limit)
  local candidates = {}
  if current_dir == '' or vim.tbl_isempty(extension_set) then
    return candidates
  end

  local entries = get_readdir(current_dir)
  if #entries == 0 then
    return candidates
  end

  local added = 0
  for _, entry in ipairs(entries) do
    if added >= scan_limit then
      break
    end

    local ext = entry:match('%.([^./\\]+)$')
    if ext and extension_set[ext] then
      local path = normalize_path(current_dir .. '/' .. entry)
      if path ~= '' and path ~= current_name and not seen_paths[path] then
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == 'file' then
          candidates[#candidates + 1] = {
            kind = 'file',
            path = path,
            score = score_candidate(path, current_dir, true, import_names),
            lastused = 0,
          }
          added = added + 1
        end
      end
    end
  end

  return candidates
end

local function build_candidates(bufnr, current_name, current_dir, current_ft, import_names, nb_config, bufinfo)
  local candidates, seen_paths = build_loaded_candidates(bufnr, current_name, current_dir, current_ft, import_names, bufinfo)
  local extension_set = allowed_extension_set(current_name, current_ft)

  if nb_config.include_disk_files then
    local disk_candidates = build_disk_candidates(
      current_name,
      current_dir,
      import_names,
      extension_set,
      seen_paths,
      nb_config.disk_scan_limit or 32
    )
    for _, candidate in ipairs(disk_candidates) do
      candidates[#candidates + 1] = candidate
    end
  end

  table.sort(candidates, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.kind ~= b.kind then
      return a.kind == 'buffer'
    end
    if (a.lastused or 0) ~= (b.lastused or 0) then
      return (a.lastused or 0) > (b.lastused or 0)
    end
    return a.path < b.path
  end)

  return candidates
end

local function get_candidates(bufnr, current_name, current_dir, current_ft, import_names, import_signature, extension_set, nb_config)
  local bufinfo = vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })
  local dir_sig = directory_signature(current_dir, extension_set, nb_config.disk_scan_limit or 32)
  local loaded_sig = loaded_buffer_signature(bufnr, bufinfo)
  local cached = candidate_cache[bufnr]
  if cached
    and cached.generation == candidate_generation
    and cached.import_signature == import_signature
    and cached.current_name == current_name
    and cached.current_dir == current_dir
    and cached.current_ft == current_ft
    and cached.directory_signature == dir_sig
    and cached.loaded_signature == loaded_sig
    and cached.include_disk_files == nb_config.include_disk_files
    and cached.disk_scan_limit == nb_config.disk_scan_limit
  then
    return cached.candidates
  end

  local candidates = build_candidates(bufnr, current_name, current_dir, current_ft, import_names, nb_config, bufinfo)
  candidate_cache[bufnr] = {
    generation = candidate_generation,
    import_signature = import_signature,
    current_name = current_name,
    current_dir = current_dir,
    current_ft = current_ft,
    directory_signature = dir_sig,
    loaded_signature = loaded_sig,
    include_disk_files = nb_config.include_disk_files,
    disk_scan_limit = nb_config.disk_scan_limit,
    candidates = candidates,
  }

  return candidates
end

local function get_buffer_snapshot(candidate, budget)
  if not candidate or not candidate.bufnr or not vim.api.nvim_buf_is_valid(candidate.bufnr) then
    return nil
  end

  local cache_key = 'buf:' .. tostring(candidate.bufnr)
  local changedtick = get_changedtick(candidate.bufnr)
  local cached = snapshot_cache[cache_key]
  if cached and cached.changedtick == changedtick and cached.budget == budget then
    return cached.snapshot
  end

  local lines = vim.api.nvim_buf_get_lines(candidate.bufnr, 0, SNAPSHOT_LINE_LIMIT, false)
  local content = table.concat(lines, '\n')
  local is_truncated = false
  if #content > budget then
    content = utf8.safe_sub_left(content, budget)
    is_truncated = true
  end
  if vim.api.nvim_buf_line_count(candidate.bufnr) > SNAPSHOT_LINE_LIMIT then
    is_truncated = true
  end

  local snapshot = {
    filename = vim.fn.fnamemodify(candidate.path, ':t'),
    content = content,
    is_truncated = is_truncated,
  }

  snapshot_cache[cache_key] = {
    changedtick = changedtick,
    budget = budget,
    snapshot = snapshot,
  }

  return snapshot
end

local function get_file_snapshot(candidate, budget)
  if not candidate or not candidate.path or candidate.path == '' then
    return nil
  end

  local signature = file_signature(candidate.path)
  if not signature then
    return nil
  end

  local cache_key = 'file:' .. candidate.path
  local cached = snapshot_cache[cache_key]
  if cached and cached.signature == signature and cached.budget == budget then
    return cached.snapshot
  end

  local lines = vim.fn.readfile(candidate.path, '', SNAPSHOT_LINE_LIMIT + 1)
  if type(lines) ~= 'table' then
    return nil
  end

  local is_truncated = #lines > SNAPSHOT_LINE_LIMIT
  while #lines > SNAPSHOT_LINE_LIMIT do
    table.remove(lines)
  end

  local content = table.concat(lines, '\n')
  if #content > budget then
    content = utf8.safe_sub_left(content, budget)
    is_truncated = true
  end

  local snapshot = {
    filename = vim.fn.fnamemodify(candidate.path, ':t'),
    content = content,
    is_truncated = is_truncated,
  }

  snapshot_cache[cache_key] = {
    signature = signature,
    budget = budget,
    snapshot = snapshot,
  }

  -- Evict file entries if snapshot_cache grows too large
  local count = 0
  for _ in pairs(snapshot_cache) do
    count = count + 1
  end
  if count > SNAPSHOT_CACHE_MAX then
    for key in pairs(snapshot_cache) do
      if key:sub(1, 5) == 'file:' then
        snapshot_cache[key] = nil
      end
    end
  end

  return snapshot
end

local function get_snapshot(candidate, budget)
  if not candidate then
    return nil
  end
  if candidate.kind == 'buffer' then
    return get_buffer_snapshot(candidate, budget)
  end
  if candidate.kind == 'file' then
    return get_file_snapshot(candidate, budget)
  end
  return nil
end

function M.get_context(bufnr)
  local config = require('autofill.config').get()
  local nb_config = config.neighbors
  if not nb_config or not nb_config.enabled then return nil end

  local current_name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local current_dir = current_dir_for_path(current_name)
  local current_ft = vim.bo[bufnr].filetype
  local extension_set = allowed_extension_set(current_name, current_ft)
  local import_names, import_signature = get_import_names(bufnr)
  local candidates = get_candidates(bufnr, current_name, current_dir, current_ft, import_names, import_signature, extension_set, nb_config)

  local max_files = nb_config.max_files or 2
  if max_files <= 0 then return nil end

  local total_budget = nb_config.budget or 2000
  local per_file_budget = math.max(1, math.floor(total_budget / max_files))

  local neighbors = {}
  for i = 1, math.min(max_files, #candidates) do
    local snapshot = get_snapshot(candidates[i], per_file_budget)
    if snapshot then
      neighbors[#neighbors + 1] = snapshot
    end
  end

  if #neighbors == 0 then return nil end
  return neighbors
end

function M.get_revision(bufnr)
  local config = require('autofill.config').get()
  local nb_config = config.neighbors or {}
  local current_name = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local current_dir = current_dir_for_path(current_name)
  local current_ft = vim.bo[bufnr].filetype
  local extension_set = allowed_extension_set(current_name, current_ft)
  local import_names, import_signature = get_import_names(bufnr)
  local candidates = get_candidates(
    bufnr,
    current_name,
    current_dir,
    current_ft,
    import_names,
    import_signature,
    extension_set,
    nb_config
  )

  local top_signatures = {}
  local max_files = nb_config.max_files or 2
  for i = 1, math.min(max_files, #candidates) do
    local candidate = candidates[i]
    if candidate.kind == 'buffer' then
      top_signatures[#top_signatures + 1] = table.concat({
        candidate.path,
        ':buf:',
        tostring(get_changedtick(candidate.bufnr)),
      })
    elseif candidate.kind == 'file' then
      top_signatures[#top_signatures + 1] = table.concat({
        candidate.path,
        ':file:',
        file_signature(candidate.path) or '',
      })
    end
  end

  return table.concat({
    'imports=',
    import_signature or '',
    ':dir=',
    directory_signature(current_dir, extension_set, nb_config.disk_scan_limit or 32),
    ':candidates=',
    tostring(candidate_generation),
    ':top=',
    table.concat(top_signatures, ','),
  })
end

function M.get_quick_revision(bufnr)
  local _, import_signature = get_import_names(bufnr)

  local parts = {
    'gen=',
    tostring(candidate_generation),
    ':imports=',
    import_signature or '',
  }

  local cached = candidate_cache[bufnr]
  if cached and cached.candidates then
    local config = require('autofill.config').get()
    local nb_config = config.neighbors or {}
    local max_files = nb_config.max_files or 2
    for i = 1, math.min(max_files, #cached.candidates) do
      local candidate = cached.candidates[i]
      if candidate.kind == 'buffer' and candidate.bufnr then
        parts[#parts + 1] = ':'
        parts[#parts + 1] = candidate.path or ''
        parts[#parts + 1] = '='
        parts[#parts + 1] = tostring(get_changedtick(candidate.bufnr))
      end
    end
  end

  return table.concat(parts)
end

function M.mark_candidates_dirty()
  candidate_generation = candidate_generation + 1
  readdir_cache = {}
  for key in pairs(snapshot_cache) do
    if key:sub(1, 5) == 'file:' then
      snapshot_cache[key] = nil
    end
  end
end

function M.clear(bufnr)
  import_cache[bufnr] = nil
  candidate_cache[bufnr] = nil
  snapshot_cache['buf:' .. tostring(bufnr)] = nil
end

return M
