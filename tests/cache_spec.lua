local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local cache = require('autofill.cache')
  local config = require('autofill.config')

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

  cache.clear()
end
