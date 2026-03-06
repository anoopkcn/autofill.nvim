local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local config = require('autofill.config')
  local registry = require('autofill.context.registry')
  local context = require('autofill.context')
  local treesitter_context = require('autofill.context.treesitter')
  local lsp_context = require('autofill.context.lsp')
  local neighbors_context = require('autofill.context.neighbors')

  config.setup({ enabled = false })

  assert(vim.deep_equal(registry.builtin_order(), {
    'buffer',
    'treesitter',
    'lsp',
    'neighbors',
  }), 'provider registry should expose a stable builtin provider order')

  local composed = registry.compose_revision({
    neighbors = 'imports=foo',
    lsp = 'sym=3:diag=4',
  }, registry.builtin_order())
  assert(composed == 'lsp=sym=3:diag=4\0neighbors=imports=foo', 'provider revision composition should be deterministic')

  local original_ts_get_context = treesitter_context.get_context
  local original_lsp_get_context = lsp_context.get_context
  local original_lsp_get_symbols = lsp_context.get_symbols
  local original_lsp_get_revision = lsp_context.get_revision
  local original_neighbors_get_context = neighbors_context.get_context
  local original_neighbors_get_revision = neighbors_context.get_revision

  treesitter_context.get_context = function()
    return {
      scopes = {
        { type = 'function_declaration', line = 1, header = 'local function demo()' },
      },
      in_comment = false,
      in_string = false,
    }
  end
  lsp_context.get_context = function()
    return {
      diagnostics = {
        { line = 1, severity = vim.diagnostic.severity.WARN, message = 'unused value' },
      },
    }
  end
  lsp_context.get_symbols = function()
    return {
      { kind = 'Function', name = 'demo', line = 1, container = '' },
    }
  end
  lsp_context.get_revision = function()
    return 'sym=3:diag=4'
  end
  neighbors_context.get_context = function()
    return nil
  end
  neighbors_context.get_revision = function()
    return 'imports=foo'
  end

  local bufnr = helpers.new_buffer({
    'local value = 1',
  }, {
    name = '/tmp/autofill-providers/example.lua',
    filetype = 'lua',
    row = 1,
    col = 6,
  })

  local gathered = context.gather(bufnr, { 1, 6 })
  assert(vim.deep_equal(gathered.provider_order, registry.builtin_order()), 'gather should preserve builtin provider order')
  assert(gathered.providers.buffer.before == 'local ', 'gather should expose buffer provider output')
  assert(gathered.before_cursor == 'local ', 'gather should preserve legacy top-level buffer fields')
  assert(gathered.lsp and gathered.lsp.symbols and gathered.lsp.symbols[1].name == 'demo', 'gather should preserve legacy top-level LSP fields')
  assert(gathered.neighbors == nil, 'gather should skip empty provider results')
  assert(gathered.revisions.lsp == 'sym=3:diag=4', 'gather should expose provider revisions')
  assert(context.get_revision(bufnr, { 1, 6 }) == composed, 'context should compose provider revisions without trigger-side provider knowledge')

  treesitter_context.get_context = function()
    error('boom')
  end

  local degraded = context.gather(bufnr, { 1, 6 })
  assert(degraded.before_cursor == 'local ', 'provider failures should not break buffer context gathering')
  assert(degraded.treesitter == nil, 'provider failures should drop only the failing provider result')
  assert(degraded.lsp ~= nil, 'provider failures should not affect healthy providers')

  treesitter_context.get_context = original_ts_get_context
  lsp_context.get_context = original_lsp_get_context
  lsp_context.get_symbols = original_lsp_get_symbols
  lsp_context.get_revision = original_lsp_get_revision
  neighbors_context.get_context = original_neighbors_get_context
  neighbors_context.get_revision = original_neighbors_get_revision

  helpers.reset_runtime()
end
