local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local config = require('autofill.config')

  config.setup({ enabled = false })
  assert(config.get().treesitter.enabled == true, 'Treesitter context should be enabled by default')
  assert(config.get().lsp.enabled == false, 'LSP context should be disabled by default')

  config.setup({
    enabled = false,
    treesitter = {
      enabled = false,
    },
  })
  assert(config.get().treesitter.enabled == false, 'config should accept explicitly disabling Treesitter context')

  config.setup({
    enabled = false,
    lsp = {
      enabled = true,
    },
  })
  assert(config.get().lsp.enabled == true, 'config should accept explicitly enabling LSP context')

  local ok, err = pcall(config.setup, {
    enabled = false,
    lsp = {
      enabled = 'yes',
    },
  })
  assert(not ok, 'config should reject non-boolean lsp.enabled values')
  assert(tostring(err):find('lsp.enabled must be a boolean', 1, true), 'config should explain invalid lsp.enabled values')

  ok, err = pcall(config.setup, {
    enabled = false,
    treesitter = {
      enabled = 'no',
    },
  })
  assert(not ok, 'config should reject non-boolean treesitter.enabled values')
  assert(tostring(err):find('treesitter.enabled must be a boolean', 1, true), 'config should explain invalid treesitter.enabled values')

  helpers.reset_runtime()
end
