local util = require('autofill.util')

local M = {}

function M.get_context(bufnr, cursor)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil
  end

  local row = cursor[1] - 1
  local diagnostics = vim.diagnostic.get(bufnr)

  -- Filter to +-10 lines of cursor, sort by proximity
  local nearby = {}
  for _, d in ipairs(diagnostics) do
    local dist = math.abs(d.lnum - row)
    if dist <= 10 then
      table.insert(nearby, {
        line = d.lnum + 1,
        message = d.message,
        severity = d.severity,
        distance = dist,
      })
    end
  end

  table.sort(nearby, function(a, b) return a.distance < b.distance end)

  -- Keep top 5
  local top_diags = {}
  for i = 1, math.min(5, #nearby) do
    top_diags[i] = nearby[i]
  end

  if #top_diags == 0 then
    return nil
  end

  return {
    diagnostics = top_diags,
  }
end

return M
