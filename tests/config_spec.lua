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

  config.setup({
    enabled = false,
    backend = 'openai',
    model = 'gpt-5',
    openai = {
      model = 'gpt-5-mini',
    },
  })
  assert(config.get().openai.model == 'gpt-5', 'top-level model should override the active backend model')
  assert(config.get().claude.model == config.defaults.claude.model, 'top-level model should not change inactive backend models')

  config.setup({
    enabled = false,
    backend = 'openai',
    openai = {
      model = 'gpt-5-nano',
    },
  })
  assert(config.get().openai.model == 'gpt-5-nano', 'backend-specific model config should still work when top-level model is absent')

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

  ok, err = pcall(config.setup, {
    enabled = false,
    model = true,
  })
  assert(not ok, 'config should reject non-string top-level model values')
  assert(tostring(err):find('model must be a non-empty string or nil', 1, true), 'config should explain invalid top-level model types')

  ok, err = pcall(config.setup, {
    enabled = false,
    model = '',
  })
  assert(not ok, 'config should reject empty top-level model values')
  assert(tostring(err):find('model must be a non-empty string or nil', 1, true), 'config should explain empty top-level model values')

  helpers.reset_runtime()
end
