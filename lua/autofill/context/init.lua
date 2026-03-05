local buffer = require('autofill.context.buffer')
local treesitter = require('autofill.context.treesitter')
local lsp = require('autofill.context.lsp')
local neighbors = require('autofill.context.neighbors')

local M = {}

function M.gather(bufnr, cursor, opts)
  opts = opts or {}

  local buf_ctx = opts.buffer or buffer.get_text(bufnr, cursor)
  local ts_ctx = treesitter.get_context(bufnr, cursor)
  local lsp_ctx = lsp.get_context(bufnr, cursor)

  -- Attach cached symbols to lsp context
  local symbols = lsp.get_symbols(bufnr)
  if symbols and #symbols > 0 then
    if not lsp_ctx then
      lsp_ctx = {}
    end
    lsp_ctx.symbols = symbols
  end

  local nb_ctx = neighbors.get_context(bufnr)

  return {
    filetype = vim.bo[bufnr].filetype,
    filename = vim.api.nvim_buf_get_name(bufnr),
    before_cursor = buf_ctx.before,
    after_cursor = buf_ctx.after,
    treesitter = ts_ctx,
    lsp = lsp_ctx,
    neighbors = nb_ctx,
  }
end

return M
