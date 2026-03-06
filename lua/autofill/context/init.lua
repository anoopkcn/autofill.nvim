local registry = require('autofill.context.registry')

local M = {}

local function buffer_provider_data(ctx)
  local provider = ctx.providers.buffer or {}
  return {
    before_cursor = provider.before or '',
    after_cursor = provider.after or '',
    is_truncated_before = provider.is_truncated_before,
    is_truncated_after = provider.is_truncated_after,
  }
end

function M.gather(bufnr, cursor, opts)
  opts = opts or {}

  local collected = registry.collect(bufnr, cursor, opts)
  local buf_ctx = buffer_provider_data(collected)

  return {
    filetype = vim.bo[bufnr].filetype,
    filename = vim.api.nvim_buf_get_name(bufnr),
    providers = collected.providers,
    provider_order = collected.provider_order,
    revisions = collected.revisions,
    before_cursor = buf_ctx.before_cursor,
    after_cursor = buf_ctx.after_cursor,
    is_truncated_before = buf_ctx.is_truncated_before,
    is_truncated_after = buf_ctx.is_truncated_after,
    treesitter = collected.providers.treesitter,
    lsp = collected.providers.lsp,
    neighbors = collected.providers.neighbors,
  }
end

function M.get_revisions(bufnr, cursor, opts)
  local collected = registry.collect_revisions(bufnr, cursor, opts)
  return collected.revisions, collected.provider_order
end

function M.get_revision(bufnr, cursor, opts)
  local revisions, provider_order = M.get_revisions(bufnr, cursor, opts)
  return registry.compose_revision(revisions, provider_order)
end

return M
