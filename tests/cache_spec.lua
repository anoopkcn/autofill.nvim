return function()
  require('tests.helpers').reset_runtime()

  local cache = require('autofill.cache')
  local config = require('autofill.config')
  local context = require('autofill.context')
  local helpers = require('tests.helpers')

  cache.clear()
  config.setup({ enabled = false })

  local scope = cache.scope(config.get())
  local base_ctx = {
    filename = '/tmp/example.lua',
    filetype = 'lua',
    before_cursor = 'local value = ',
    after_cursor = '',
  }

  local ctx1 = vim.tbl_deep_extend('force', {}, base_ctx, {
    neighbors = {
      { filename = 'neighbor.lua', content = 'return one' },
    },
  })
  local ctx2 = vim.tbl_deep_extend('force', {}, base_ctx, {
    neighbors = {
      { filename = 'neighbor.lua', content = 'return two' },
    },
  })

  assert(cache.key(ctx1, scope) ~= cache.key(ctx2, scope), 'cache key should change when prompt-relevant neighbor content changes')

  local quick1 = cache.quick_key({
    scope = scope,
    bufnr = 1,
    row = 1,
    filetype = 'lua',
    context_revision = 'sym=1:diag=1:imports=foo',
    before_cursor = 'abc',
    after_cursor = '',
  })
  local quick2 = cache.quick_key({
    scope = scope,
    bufnr = 2,
    row = 1,
    filetype = 'lua',
    context_revision = 'sym=1:diag=1:imports=foo',
    before_cursor = 'abc',
    after_cursor = '',
  })

  cache.set_quick(quick1, 'one', { bufnr = 1 })
  cache.set_quick(quick2, 'two', { bufnr = 2 })
  cache.clear_quick_for_buffer(1)

  assert(cache.get_quick(quick1) == nil, 'buffer-scoped quick cache clear should drop entries for that buffer')
  assert(cache.get_quick(quick2) == 'two', 'buffer-scoped quick cache clear should not drop other buffers')

  config.setup({
    enabled = false,
    prompt = {
      max_chars = 13000,
      max_neighbors_chars = 2500,
      max_neighbor_file_chars = 900,
      max_outline_chars = 1200,
      max_scope_chars = 900,
      max_diagnostics_chars = 600,
      max_symbol_count = 15,
      max_scope_count = 8,
      max_diagnostic_count = 5,
    },
    neighbors = {
      enabled = true,
      budget = 2000,
      max_files = 2,
      include_disk_files = false,
      disk_scan_limit = 32,
    },
  })
  local prompt_scope = cache.scope(config.get())
  assert(scope ~= prompt_scope, 'cache scope should change when prompt-shaping settings change')

  config.setup({
    enabled = false,
    neighbors = {
      enabled = true,
      budget = 2000,
      max_files = 2,
      include_disk_files = false,
      disk_scan_limit = 32,
    },
  })
  local disk_scope = cache.scope(config.get())
  assert(scope ~= disk_scope, 'cache scope should change when neighbor disk-source settings change')

  config.setup({
    enabled = false,
  })
  local lsp_disabled_scope = cache.scope(config.get())

  config.setup({
    enabled = false,
    lsp = {
      enabled = true,
    },
  })
  local lsp_enabled_scope = cache.scope(config.get())
  assert(lsp_disabled_scope ~= lsp_enabled_scope, 'cache scope should change when LSP context is toggled')

  config.setup({
    enabled = false,
    backend = 'blablador',
    blablador = {
      api_key_env = 'BLABLADOR_API_KEY',
      model = 'alias-code',
      base_url = 'https://example.one/v1',
      timeout_ms = 10000,
    },
  })
  local blablador_scope_one = cache.scope(config.get())

  config.setup({
    enabled = false,
    backend = 'blablador',
    blablador = {
      api_key_env = 'BLABLADOR_API_KEY',
      model = 'alias-code',
      base_url = 'https://example.two/v1',
      timeout_ms = 10000,
    },
  })
  local blablador_scope_two = cache.scope(config.get())
  assert(blablador_scope_one ~= blablador_scope_two, 'cache scope should change when backend base_url changes')

  local lsp_context = require('autofill.context.lsp')
  local neighbors_context = require('autofill.context.neighbors')
  local original_lsp_get_revision = lsp_context.get_revision
  local original_neighbors_get_revision = neighbors_context.get_revision
  local revision_bufnr = helpers.new_buffer({
    'local cache = true',
  }, {
    name = '/tmp/autofill-cache/example.lua',
    filetype = 'lua',
    row = 1,
    col = 6,
  })

  lsp_context.get_revision = function()
    return 'sym=1:diag=1'
  end
  neighbors_context.get_revision = function()
    return 'imports=foo'
  end

  config.setup({
    enabled = false,
  })

  local context_revision_one = context.get_revision(revision_bufnr, { 1, 6 })
  local context_revision_two = context.get_revision(revision_bufnr, { 1, 6 })
  local quick_revision_one = cache.quick_key({
    scope = lsp_disabled_scope,
    bufnr = revision_bufnr,
    row = 1,
    filetype = 'lua',
    context_revision = context_revision_one,
    before_cursor = 'local ',
    after_cursor = 'cache = true',
  })
  local quick_revision_two = cache.quick_key({
    scope = lsp_disabled_scope,
    bufnr = revision_bufnr,
    row = 1,
    filetype = 'lua',
    context_revision = context_revision_two,
    before_cursor = 'local ',
    after_cursor = 'cache = true',
  })
  assert(context_revision_one == context_revision_two, 'context revision composition should be stable when provider revisions are unchanged')
  assert(quick_revision_one == quick_revision_two, 'quick cache keys should stay stable for unchanged provider revisions')

  config.setup({
    enabled = false,
    lsp = {
      enabled = true,
    },
  })

  local context_revision_lsp_enabled = context.get_revision(revision_bufnr, { 1, 6 })
  local quick_revision_lsp_enabled = cache.quick_key({
    scope = lsp_enabled_scope,
    bufnr = revision_bufnr,
    row = 1,
    filetype = 'lua',
    context_revision = context_revision_lsp_enabled,
    before_cursor = 'local ',
    after_cursor = 'cache = true',
  })
  assert(context_revision_one ~= context_revision_lsp_enabled, 'context revision composition should change when LSP context is toggled')
  assert(quick_revision_one ~= quick_revision_lsp_enabled, 'quick cache keys should change when LSP context is toggled')

  neighbors_context.get_revision = function()
    return 'imports=bar'
  end

  local context_revision_three = context.get_revision(revision_bufnr, { 1, 6 })
  local quick_revision_three = cache.quick_key({
    scope = lsp_enabled_scope,
    bufnr = revision_bufnr,
    row = 1,
    filetype = 'lua',
    context_revision = context_revision_three,
    before_cursor = 'local ',
    after_cursor = 'cache = true',
  })
  assert(context_revision_lsp_enabled ~= context_revision_three, 'context revision composition should change when a provider revision changes')
  assert(quick_revision_lsp_enabled ~= quick_revision_three, 'quick cache keys should change when provider revisions change')

  lsp_context.get_revision = original_lsp_get_revision
  neighbors_context.get_revision = original_neighbors_get_revision

  cache.clear()
end
