local M = {}

local TEST_KEYS = { '<F19>', '<F20>', '<F21>' }

local function clear_mapping(lhs)
  pcall(vim.keymap.del, 'i', lhs)
end

function M.reset_runtime()
  local ok_trigger, trigger = pcall(require, 'autofill.trigger')
  if ok_trigger then
    pcall(trigger.stop)
  end

  local ok_request, request = pcall(require, 'autofill.transport.request')
  if ok_request then
    pcall(request.cancel)
  end

  local ok_ghost, ghost = pcall(require, 'autofill.display.ghost')
  if ok_ghost then
    pcall(ghost.clear_all)
    pcall(ghost.teardown_keymaps, { direct = true, plug = true })
  end

  local ok_cache, cache = pcall(require, 'autofill.cache')
  if ok_cache then
    pcall(cache.clear)
  end

  local ok_lsp, lsp = pcall(require, 'autofill.context.lsp')
  if ok_lsp then
    pcall(lsp.stop)
  end

  local ok_neighbors, neighbors = pcall(require, 'autofill.context.neighbors')

  for _, buf in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
    if ok_lsp then
      pcall(lsp.clear, buf.bufnr)
    end
    if ok_neighbors then
      pcall(neighbors.clear, buf.bufnr)
    end
  end

  for _, lhs in ipairs(TEST_KEYS) do
    clear_mapping(lhs)
  end
end

function M.new_buffer(lines, opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_create_buf(opts.listed ~= false, true)
  vim.api.nvim_set_current_buf(bufnr)

  if opts.name then
    vim.api.nvim_buf_set_name(bufnr, opts.name)
  end

  vim.bo[bufnr].filetype = opts.filetype or ''
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { '' })

  local row = opts.row or 1
  local col = opts.col or 0
  vim.api.nvim_win_set_cursor(0, { row, col })

  return bufnr
end

function M.wait(ms, predicate, message)
  local ok = vim.wait(ms, predicate)
  if not ok then
    error(message or ('timed out after ' .. tostring(ms) .. 'ms'))
  end
end

function M.feedkeys(keys)
  local encoded = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(encoded, 'xt', false)
end

function M.test_keys()
  return TEST_KEYS
end

return M
