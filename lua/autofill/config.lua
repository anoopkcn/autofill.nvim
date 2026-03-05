local M = {}

M.defaults = {
  enabled = true,
  backend = 'claude',
  debounce_ms = 400,
  throttle_ms = 1000,
  context_window = 12000,
  context_ratio = 0.75,
  max_tokens = 256,
  log_level = 'warn',
  filetypes_exclude = {},
  keymaps = {
    accept = '<Tab>',
    accept_word = '<C-f>',
    dismiss = '<C-]>',
  },
  claude = {
    api_key_env = 'ANTHROPIC_API_KEY',
    model = 'claude-sonnet-4-20250514',
    timeout_ms = 10000,
  },
  openai = {
    api_key_env = 'OPENAI_API_KEY',
    model = 'gpt-4o-mini',
    timeout_ms = 10000,
  },
  gemini = {
    api_key_env = 'GEMINI_API_KEY',
    model = 'gemini-2.5-flash',
    timeout_ms = 10000,
  },
  ollama = {
    model = 'codellama',
    url = 'http://localhost:11434',
    timeout_ms = 30000,
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', {}, M.defaults, opts or {})
end

function M.get()
  return M.options
end

return M
