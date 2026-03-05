local M = {}

function M.get_text(bufnr, cursor)
  local config = require('autofill.config').get()
  local total_budget = config.context_window
  local ratio = config.context_ratio
  local before_budget = math.floor(total_budget * ratio)
  local after_budget = total_budget - before_budget

  local row, col = cursor[1], cursor[2]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local before_lines = {}
  for i = 1, row - 1 do
    table.insert(before_lines, lines[i])
  end
  local current_line = lines[row] or ''
  table.insert(before_lines, current_line:sub(1, col))

  local before = table.concat(before_lines, '\n')

  local after_lines = { current_line:sub(col + 1) }
  for i = row + 1, #lines do
    table.insert(after_lines, lines[i])
  end
  local after = table.concat(after_lines, '\n')

  local is_truncated_before = false
  local is_truncated_after = false

  if #before > before_budget then
    before = before:sub(-before_budget)
    is_truncated_before = true
  end

  if #after > after_budget then
    after = after:sub(1, after_budget)
    is_truncated_after = true
  end

  return {
    before = before,
    after = after,
    is_truncated_before = is_truncated_before,
    is_truncated_after = is_truncated_after,
  }
end

return M
