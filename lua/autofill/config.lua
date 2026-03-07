local M = {}

local VALID_LOG_LEVELS = {
  debug = true,
  info = true,
  warn = true,
  error = true,
}

local VALID_PROMPT_MODES = {
  auto = true,
  code = true,
  prose = true,
}

local SUPPORTED_BACKEND_DEFAULTS = {
  blablador = {
    api_key_env = 'BLABLADOR_API_KEY',
    model = 'alias-code',
    base_url = 'https://api.helmholtz-blablador.fz-juelich.de/v1',
    timeout_ms = 10000,
  },
  claude = {
    api_key_env = 'ANTHROPIC_API_KEY',
    model = 'claude-haiku-4-5-20251001',
    timeout_ms = 10000,
  },
  gemini = {
    api_key_env = 'GEMINI_API_KEY',
    model = 'gemini-2.5-flash',
    timeout_ms = 10000,
  },
  openai = {
    api_key_env = 'OPENAI_API_KEY',
    model = 'gpt-5-mini',
    timeout_ms = 10000,
  },
}

local REMOVED_BACKEND_CONFIGS = {
  ollama = true,
}

M.defaults = {
  enabled = true,
  backend = 'claude',
  model = nil,
  debounce_ms = 200,
  throttle_ms = 400,
  context_window = 8000,
  context_ratio = 0.75,
  max_tokens = 256,
  log_level = 'warn',
  profiling = false,
  streaming_display = true,
  neighbors = {
    enabled = true,
    budget = 2000,
    max_files = 2,
    include_disk_files = true,
    disk_scan_limit = 32,
  },
  treesitter = {
    enabled = true,
  },
  lsp = {
    enabled = false,
  },
  prompt = {
    max_chars = 12000,
    max_neighbors_chars = 2500,
    max_neighbor_file_chars = 900,
    max_outline_chars = 1200,
    max_scope_chars = 900,
    max_diagnostics_chars = 600,
    max_symbol_count = 15,
    max_scope_count = 8,
    max_diagnostic_count = 5,
    mode = 'auto',
    prose_filetypes = { 'markdown', 'text', 'gitcommit', 'rst', 'asciidoc' },
  },
  temperature = {
    code = 0.1,
    prose = nil,
  },
  filetypes_exclude = {},
  keymaps = {
    accept = nil,
    accept_word = nil,
    dismiss = nil,
  },
}

for backend_name, backend_defaults in pairs(SUPPORTED_BACKEND_DEFAULTS) do
  M.defaults[backend_name] = vim.deepcopy(backend_defaults)
end

M.options = vim.tbl_deep_extend('force', {}, M.defaults)

local function is_positive_integer(value)
  return type(value) == 'number' and value > 0 and math.floor(value) == value
end

local function is_non_negative_integer(value)
  return type(value) == 'number' and value >= 0 and math.floor(value) == value
end

local function validate_string_list(value, key, errors)
  if type(value) ~= 'table' then
    errors[#errors + 1] = key .. ' must be a list of strings'
    return
  end

  for i, item in ipairs(value) do
    if type(item) ~= 'string' or item == '' then
      errors[#errors + 1] = key .. '[' .. i .. '] must be a non-empty string'
    end
  end
end

local function validate_optional_string(value, key, errors)
  if value ~= nil and (type(value) ~= 'string' or value == '') then
    errors[#errors + 1] = key .. ' must be a non-empty string or nil'
  end
end

local function validate_optional_temperature(value, key, errors)
  if value == nil then
    return
  end

  if type(value) ~= 'number' or value < 0 or value > 1 then
    errors[#errors + 1] = key .. ' must be a number between 0 and 1 or nil'
  end
end

local function normalize_model_override(options)
  local backend = require('autofill.backend')
  local model = options.model

  if type(model) ~= 'string' or model == '' then
    return
  end

  if not backend.is_supported(options.backend) then
    return
  end

  local backend_opts = options[options.backend]
  if type(backend_opts) ~= 'table' then
    return
  end

  backend_opts.model = model
end

function M.inspect(options)
  local backend = require('autofill.backend')
  local errors = {}
  local warnings = {}

  if type(options) ~= 'table' then
    errors[#errors + 1] = 'options must be a table'
    return { errors = errors, warnings = warnings }
  end

  if type(options.enabled) ~= 'boolean' then
    errors[#errors + 1] = 'enabled must be a boolean'
  end

  if type(options.backend) ~= 'string' or options.backend == '' then
    errors[#errors + 1] = 'backend must be a non-empty string'
  elseif not backend.is_supported(options.backend) then
    errors[#errors + 1] = 'backend "' .. options.backend .. '" is not supported'
  end

  validate_optional_string(options.model, 'model', errors)

  for backend_name in pairs(REMOVED_BACKEND_CONFIGS) do
    if options[backend_name] ~= nil then
      errors[#errors + 1] = backend_name .. ' config is no longer supported'
    end
  end

  if not is_non_negative_integer(options.debounce_ms) then
    errors[#errors + 1] = 'debounce_ms must be a non-negative integer'
  end

  if not is_non_negative_integer(options.throttle_ms) then
    errors[#errors + 1] = 'throttle_ms must be a non-negative integer'
  end

  if not is_positive_integer(options.context_window) then
    errors[#errors + 1] = 'context_window must be a positive integer'
  end

  if type(options.context_ratio) ~= 'number' or options.context_ratio <= 0 or options.context_ratio >= 1 then
    errors[#errors + 1] = 'context_ratio must be a number between 0 and 1'
  end

  if not is_positive_integer(options.max_tokens) then
    errors[#errors + 1] = 'max_tokens must be a positive integer'
  end

  if not VALID_LOG_LEVELS[options.log_level] then
    errors[#errors + 1] = 'log_level must be one of: debug, info, warn, error'
  end

  if type(options.profiling) ~= 'boolean' then
    errors[#errors + 1] = 'profiling must be a boolean'
  end

  if type(options.streaming_display) ~= 'boolean' then
    errors[#errors + 1] = 'streaming_display must be a boolean'
  end

  validate_string_list(options.filetypes_exclude, 'filetypes_exclude', errors)

  if type(options.keymaps) ~= 'table' then
    errors[#errors + 1] = 'keymaps must be a table'
  else
    validate_optional_string(options.keymaps.accept, 'keymaps.accept', errors)
    validate_optional_string(options.keymaps.accept_word, 'keymaps.accept_word', errors)
    validate_optional_string(options.keymaps.dismiss, 'keymaps.dismiss', errors)

    local seen = {}
    for action, lhs in pairs(options.keymaps) do
      if lhs then
        if seen[lhs] then
          errors[#errors + 1] = 'keymaps.' .. action .. ' conflicts with keymaps.' .. seen[lhs]
        else
          seen[lhs] = action
        end
      end
    end
  end

  if type(options.neighbors) ~= 'table' then
    errors[#errors + 1] = 'neighbors must be a table'
  else
    if type(options.neighbors.enabled) ~= 'boolean' then
      errors[#errors + 1] = 'neighbors.enabled must be a boolean'
    end
    if not is_positive_integer(options.neighbors.budget) then
      errors[#errors + 1] = 'neighbors.budget must be a positive integer'
    end
    if not is_positive_integer(options.neighbors.max_files) then
      errors[#errors + 1] = 'neighbors.max_files must be a positive integer'
    end
    if type(options.neighbors.include_disk_files) ~= 'boolean' then
      errors[#errors + 1] = 'neighbors.include_disk_files must be a boolean'
    end
    if not is_positive_integer(options.neighbors.disk_scan_limit) then
      errors[#errors + 1] = 'neighbors.disk_scan_limit must be a positive integer'
    end
  end

  if type(options.treesitter) ~= 'table' then
    errors[#errors + 1] = 'treesitter must be a table'
  else
    if type(options.treesitter.enabled) ~= 'boolean' then
      errors[#errors + 1] = 'treesitter.enabled must be a boolean'
    end
  end

  if type(options.lsp) ~= 'table' then
    errors[#errors + 1] = 'lsp must be a table'
  else
    if type(options.lsp.enabled) ~= 'boolean' then
      errors[#errors + 1] = 'lsp.enabled must be a boolean'
    end
  end

  if type(options.prompt) ~= 'table' then
    errors[#errors + 1] = 'prompt must be a table'
  else
    if not is_positive_integer(options.prompt.max_chars) then
      errors[#errors + 1] = 'prompt.max_chars must be a positive integer'
    elseif options.prompt.max_chars <= options.context_window + 128 then
      errors[#errors + 1] = 'prompt.max_chars must leave room beyond context_window for prompt metadata'
    end

    if not is_non_negative_integer(options.prompt.max_neighbors_chars) then
      errors[#errors + 1] = 'prompt.max_neighbors_chars must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_neighbor_file_chars) then
      errors[#errors + 1] = 'prompt.max_neighbor_file_chars must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_outline_chars) then
      errors[#errors + 1] = 'prompt.max_outline_chars must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_scope_chars) then
      errors[#errors + 1] = 'prompt.max_scope_chars must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_diagnostics_chars) then
      errors[#errors + 1] = 'prompt.max_diagnostics_chars must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_symbol_count) then
      errors[#errors + 1] = 'prompt.max_symbol_count must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_scope_count) then
      errors[#errors + 1] = 'prompt.max_scope_count must be a non-negative integer'
    end
    if not is_non_negative_integer(options.prompt.max_diagnostic_count) then
      errors[#errors + 1] = 'prompt.max_diagnostic_count must be a non-negative integer'
    end

    if not VALID_PROMPT_MODES[options.prompt.mode] then
      errors[#errors + 1] = 'prompt.mode must be one of: auto, code, prose'
    end

    validate_string_list(options.prompt.prose_filetypes, 'prompt.prose_filetypes', errors)
  end

  if type(options.temperature) ~= 'table' then
    errors[#errors + 1] = 'temperature must be a table'
  else
    validate_optional_temperature(options.temperature.code, 'temperature.code', errors)
    validate_optional_temperature(options.temperature.prose, 'temperature.prose', errors)
  end

  for _, backend_name in ipairs(backend.supported_backends()) do
    local backend_opts = options[backend_name]
    if type(backend_opts) ~= 'table' then
      errors[#errors + 1] = backend_name .. ' must be a table'
    else
      validate_optional_string(backend_opts.api_key_env, backend_name .. '.api_key_env', errors)
      validate_optional_string(backend_opts.model, backend_name .. '.model', errors)
      if backend_name == 'blablador' then
        validate_optional_string(backend_opts.base_url, backend_name .. '.base_url', errors)
      end
      if not is_positive_integer(backend_opts.timeout_ms) then
        errors[#errors + 1] = backend_name .. '.timeout_ms must be a positive integer'
      end
    end
  end

  return {
    errors = errors,
    warnings = warnings,
  }
end

function M.validate(options)
  local report = M.inspect(options)
  if #report.errors > 0 then
    error('[autofill] Invalid configuration:\n- ' .. table.concat(report.errors, '\n- '), 0)
  end
  return report
end

function M.setup(opts)
  local merged = vim.tbl_deep_extend('force', {}, M.defaults, opts or {})
  normalize_model_override(merged)
  M.validate(merged)
  M.options = merged
end

function M.get()
  return M.options
end

return M
