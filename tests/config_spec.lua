local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local config = require('autofill.config')

  config.setup({ enabled = false })
  assert(config.get().lsp.enabled == false, 'LSP context should be disabled by default')

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

  helpers.reset_runtime()
end
