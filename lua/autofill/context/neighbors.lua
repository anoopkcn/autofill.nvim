local utf8 = require('autofill.utf8')

local M = {}

local import_cache = {}
local candidate_cache = {}
local snapshot_cache = {}
local candidate_generation = 0

local function get_changedtick(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return -1
  end
  return vim.api.nvim_buf_get_changedtick(bufnr)
end

local function get_import_names(bufnr)
  local changedtick = get_changedtick(bufnr)
  local cached = import_cache[bufnr]
  if cached and cached.changedtick == changedtick then
    return cached.names, cached.signature
  end

  local names = {}
  local ordered = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 30, false)
  for _, line in ipairs(lines) do
    -- Match quoted strings in import/require statements
    for name in line:gmatch('["\']([^"\']+)["\']') do
      -- Extract basename (last path component, without extension)
      local base = name:match('([^/\\]+)$') or name
      base = base:gsub('%.[^.]+$', '')
      if not names[base] then
        names[base] = true
        ordered[#ordered + 1] = base
      end
    end
  end

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
