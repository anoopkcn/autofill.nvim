local buffer = require('autofill.context.buffer')
local treesitter = require('autofill.context.treesitter')
local lsp = require('autofill.context.lsp')
local neighbors = require('autofill.context.neighbors')
local util = require('autofill.util')

local M = {}

local builtin_providers = {
  {
    name = 'buffer',
    collect = function(bufnr, cursor, opts)
      local buf_ctx = opts.buffer or buffer.get_text(bufnr, cursor)
      return {
        before = buf_ctx.before,
        after = buf_ctx.after,
        is_truncated_before = buf_ctx.is_truncated_before,
        is_truncated_after = buf_ctx.is_truncated_after,
      }
    end,
  },
  {
    name = 'treesitter',
    collect = function(bufnr, cursor)
      return treesitter.get_context(bufnr, cursor)
    end,
  },
  {
    name = 'lsp',
    collect = function(bufnr, cursor)
      local lsp_ctx = lsp.get_context(bufnr, cursor)
      local symbols = lsp.get_symbols(bufnr)
      if symbols and #symbols > 0 then
        lsp_ctx = lsp_ctx or {}
        lsp_ctx.symbols = symbols
      end
      return lsp_ctx
    end,
    revision = function(bufnr)
      return lsp.get_revision(bufnr)
    end,
  },
  {
    name = 'neighbors',
    collect = function(bufnr)
      return neighbors.get_context(bufnr)
    end,
    revision = function(bufnr)
      return neighbors.get_revision(bufnr)
    end,
  },
}

local function provider_error(provider, kind, err)
  util.log('debug', 'Context provider ' .. provider.name .. ' ' .. kind .. ' failed: ' .. tostring(err))
end

local function safe_collect(provider, bufnr, cursor, opts)
  if type(provider.collect) ~= 'function' then
    return nil
  end

  local ok, result = pcall(provider.collect, bufnr, cursor, opts or {})
  if not ok then
    provider_error(provider, 'collect', result)
    return nil
  end

  return result
end

local function safe_revision(provider, bufnr, cursor, opts)
  if type(provider.revision) ~= 'function' then
    return ''
  end

  local ok, result = pcall(provider.revision, bufnr, cursor, opts or {})
  if not ok then
    provider_error(provider, 'revision', result)
    return ''
  end

  return tostring(result or '')
end

function M.builtin_order()
  local names = {}
  for _, provider in ipairs(builtin_providers) do
    names[#names + 1] = provider.name
  end
  return names
end

function M.normalize_result(name, result, revision)
  return {
    name = name,
    value = result,
    revision = tostring(revision or ''),
  }
end

function M.collect(bufnr, cursor, opts)
  opts = opts or {}

  local providers = {}
  local revisions = {}
  local order = M.builtin_order()

  for _, provider in ipairs(builtin_providers) do
    local normalized = M.normalize_result(
      provider.name,
      safe_collect(provider, bufnr, cursor, opts),
      safe_revision(provider, bufnr, cursor, opts)
    )

    if normalized.value ~= nil then
      providers[normalized.name] = normalized.value
    end
    revisions[normalized.name] = normalized.revision
  end

  return {
    providers = providers,
    revisions = revisions,
    provider_order = order,
  }
end

function M.collect_revisions(bufnr, cursor, opts)
  opts = opts or {}

  local revisions = {}
  local order = M.builtin_order()

  for _, provider in ipairs(builtin_providers) do
    revisions[provider.name] = safe_revision(provider, bufnr, cursor, opts)
  end

  return {
    revisions = revisions,
    provider_order = order,
  }
end

function M.compose_revision(revisions, order)
  local parts = {}

  for _, name in ipairs(order or M.builtin_order()) do
    local revision = revisions and revisions[name] or ''
    if revision ~= '' then
      parts[#parts + 1] = name .. '=' .. revision
    end
  end

  return table.concat(parts, '\0')
end

return M
