local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local config = require('autofill.config')

  config.setup({ enabled = false })
  assert(config.get().treesitter.enabled == true, 'Treesitter context should be enabled by default')
  assert(config.get().lsp.enabled == false, 'LSP context should be disabled by default')
  assert(config.get().prompt.mode == 'auto', 'prompt mode should default to auto')
  assert(vim.deep_equal(config.get().prompt.prose_filetypes, { 'markdown', 'text', 'gitcommit', 'rst', 'asciidoc' }),
    'prompt prose filetypes should default to the built-in prose-oriented set')
  assert(config.get().temperature.code == 0.1, 'code temperature should default to 0.1')
  assert(config.get().temperature.prose == nil, 'prose temperature should default to provider defaults')

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

  ok, err = pcall(config.setup, {
    enabled = false,
    prompt = {
      mode = 'writer',
    },
  })
  assert(not ok, 'config should reject unsupported prompt modes')
  assert(tostring(err):find('prompt.mode must be one of: auto, code, prose', 1, true),
    'config should explain unsupported prompt modes')

  ok, err = pcall(config.setup, {
    enabled = false,
    prompt = {
      prose_filetypes = { 'markdown', '' },
    },
  })
  assert(not ok, 'config should reject invalid prose filetype entries')
  assert(tostring(err):find('prompt.prose_filetypes%[2%] must be a non%-empty string'),
    'config should explain invalid prompt prose filetype entries')

  ok, err = pcall(config.setup, {
    enabled = false,
    temperature = {
      code = -0.1,
    },
  })
  assert(not ok, 'config should reject negative temperature values')
  assert(tostring(err):find('temperature.code must be a number between 0 and 1 or nil', 1, true),
    'config should explain invalid code temperature values')

  ok, err = pcall(config.setup, {
    enabled = false,
    temperature = {
      prose = 'warm',
    },
  })
  assert(not ok, 'config should reject non-numeric prose temperatures')
  assert(tostring(err):find('temperature.prose must be a number between 0 and 1 or nil', 1, true),
    'config should explain invalid prose temperature values')

  helpers.reset_runtime()
end
