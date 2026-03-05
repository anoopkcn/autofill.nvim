local buffer = require('autofill.context.buffer')
local treesitter = require('autofill.context.treesitter')
local lsp = require('autofill.context.lsp')

local M = {}

function M.gather(bufnr, cursor)
  local buf_ctx = buffer.get_text(bufnr, cursor)
  local ts_ctx = treesitter.get_context(bufnr, cursor)
  local lsp_ctx = lsp.get_context(bufnr, cursor)

  return {
    filetype = vim.bo[bufnr].filetype,
    filename = vim.api.nvim_buf_get_name(bufnr),
    before_cursor = buf_ctx.before,
    after_cursor = buf_ctx.after,
    treesitter = ts_ctx,
    lsp = lsp_ctx,
  }
end

return M
