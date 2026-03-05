local utf8 = require('autofill.utf8')

local M = {}

local function estimate_avg_line_len(bufnr, row, total_lines)
  local sample_start = math.max(0, row - 11)
  local sample_end = math.min(total_lines, row + 10)
  local lines = vim.api.nvim_buf_get_lines(bufnr, sample_start, sample_end, false)
  if #lines == 0 then return 80 end

  local total_chars = 0
  for _, line in ipairs(lines) do
    total_chars = total_chars + #line + 1 -- +1 for newline
  end
  local avg = total_chars / #lines
  return math.max(20, avg)
end

function M.get_text(bufnr, cursor)
  local config = require('autofill.config').get()
  local total_budget = config.context_window
  local ratio = config.context_ratio
  local before_budget = math.floor(total_budget * ratio)
  local after_budget = total_budget - before_budget

  local row, col = cursor[1], cursor[2]
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  -- Sample nearby lines for adaptive average, with 1.5x safety margin
  local avg_line_len = estimate_avg_line_len(bufnr, row, total_lines)
  local before_lines_needed = math.ceil(before_budget / avg_line_len * 1.5) + 1
  local after_lines_needed = math.ceil(after_budget / avg_line_len * 1.5) + 1

  local before_start = math.max(0, row - 1 - before_lines_needed)
  local after_end = math.min(total_lines, row + after_lines_needed)

  local lines = vim.api.nvim_buf_get_lines(bufnr, before_start, after_end, false)

  -- Offset: row is 1-indexed, before_start is 0-indexed
  local cursor_idx = row - before_start  -- 1-indexed position of cursor row in `lines`

  local before_parts = {}
  for i = 1, cursor_idx - 1 do
    table.insert(before_parts, lines[i])
  end
  local current_line = lines[cursor_idx] or ''
  table.insert(before_parts, current_line:sub(1, col))

  local before = table.concat(before_parts, '\n')

  local after_parts = { current_line:sub(col + 1) }
  for i = cursor_idx + 1, #lines do
    table.insert(after_parts, lines[i])
  end
  local after = table.concat(after_parts, '\n')

  local is_truncated_before = false
  local is_truncated_after = false

  if #before > before_budget then
    before = utf8.safe_sub_right(before, before_budget)
    is_truncated_before = true
  elseif before_start > 0 then
    is_truncated_before = true
  end

  if #after > after_budget then
    after = utf8.safe_sub_left(after, after_budget)
    is_truncated_after = true
  elseif after_end < total_lines then
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
