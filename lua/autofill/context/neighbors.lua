local utf8 = require('autofill.utf8')

local M = {}

local function get_import_names(bufnr)
  local names = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 30, false)
  for _, line in ipairs(lines) do
    -- Match quoted strings in import/require statements
    for name in line:gmatch('["\']([^"\']+)["\']') do
      -- Extract basename (last path component, without extension)
      local base = name:match('([^/\\]+)$') or name
      base = base:gsub('%.[^.]+$', '')
      names[base] = true
    end
  end
  return names
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

function M.get_context(bufnr)
  local config = require('autofill.config').get()
  local nb_config = config.neighbors
  if not nb_config or not nb_config.enabled then return nil end

  local current_name = vim.api.nvim_buf_get_name(bufnr)
  local current_dir = vim.fn.fnamemodify(current_name, ':h')
  local current_ft = vim.bo[bufnr].filetype
  local import_names = get_import_names(bufnr)

  local bufs = vim.fn.getbufinfo({ buflisted = 1, bufloaded = 1 })

  -- Score and sort candidates
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

  local max_files = nb_config.max_files or 3
  local total_budget = nb_config.budget or 4000
  local per_file_budget = math.floor(total_budget / max_files)

  local neighbors = {}
  for i = 1, math.min(max_files, #candidates) do
    local buf = candidates[i].buf
    local lines = vim.api.nvim_buf_get_lines(buf.bufnr, 0, 40, false)
    local content = table.concat(lines, '\n')

    if #content > per_file_budget then
      content = utf8.safe_sub_left(content, per_file_budget)
    end

    local rel_name = vim.fn.fnamemodify(buf.name, ':t')
    table.insert(neighbors, {
      filename = rel_name,
      content = content,
    })
  end

  if #neighbors == 0 then return nil end
  return neighbors
end

return M
