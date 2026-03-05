local M = {}

local VALID_LOG_LEVELS = {
  debug = true,
  info = true,
  warn = true,
  error = true,
}

local SUPPORTED_BACKEND_DEFAULTS = {
  claude = {
    api_key_env = 'ANTHROPIC_API_KEY',
    model = 'claude-sonnet-4-20250514',
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
  end

  for _, backend_name in ipairs(backend.supported_backends()) do
    local backend_opts = options[backend_name]
    if type(backend_opts) ~= 'table' then
      errors[#errors + 1] = backend_name .. ' must be a table'
    else
      validate_optional_string(backend_opts.api_key_env, backend_name .. '.api_key_env', errors)
      validate_optional_string(backend_opts.model, backend_name .. '.model', errors)
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
  M.validate(merged)
  M.options = merged
end

function M.get()
  return M.options
end

return M
