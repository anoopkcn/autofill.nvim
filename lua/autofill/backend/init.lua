local util = require('autofill.util')
local sanitize = require('autofill.sanitize')

local M = {}

local SUPPORTED_BACKENDS = {
  claude = true,
  gemini = true,
  openai = true,
}

local function supported_names()
  local names = vim.tbl_keys(SUPPORTED_BACKENDS)
  table.sort(names)
  return names
end

function M.supported_backends()
  return supported_names()
end

function M.is_supported(name)
  return type(name) == 'string' and SUPPORTED_BACKENDS[name] == true
end

function M.resolve(name)
  if not M.is_supported(name) then
    return nil, 'Unsupported backend: ' .. tostring(name) .. '. Supported backends: ' .. table.concat(supported_names(), ', ')
  end

  local ok, backend = pcall(require, 'autofill.backend.' .. name)
  if not ok then
    return nil, 'Failed to load backend "' .. name .. '": ' .. tostring(backend)
  end

  return backend
end

function M.inspect_runtime(config)
  config = config or require('autofill.config').get()

  local errors = {}
  local warnings = {}
  local backend_name = config.backend

  if vim.fn.executable('curl') ~= 1 then
    errors[#errors + 1] = 'curl executable not found'
  end

  if not M.is_supported(backend_name) then
    errors[#errors + 1] = 'Configured backend "' .. tostring(backend_name) .. '" is not supported'
    return { errors = errors, warnings = warnings }
  end

  local backend_opts = config[backend_name] or {}
  if backend_opts.api_key_env then
    local api_key = os.getenv(backend_opts.api_key_env)
    if not api_key or api_key == '' then
      errors[#errors + 1] = 'Environment variable ' .. backend_opts.api_key_env .. ' is not set'
    end
  end

  if backend_name == 'gemini' and not tostring(backend_opts.model or ''):find('gemini', 1, true) then
    warnings[#warnings + 1] = 'Configured Gemini model name does not contain "gemini"'
  end

  return {
    errors = errors,
    warnings = warnings,
  }
end

function M.complete(ctx, opts)
  opts = opts or {}
  local config = require('autofill.config').get()
  local backend_name = config.backend

  local backend, err = M.resolve(backend_name)
  if not backend then
    if opts.on_error then
      opts.on_error(err)
    else
      util.log('error', err)
    end
    return
  end

  local wrapped_opts = vim.tbl_extend('force', {}, opts)

  if opts.on_partial then
    wrapped_opts.on_partial = function(text)
      local suggestion = sanitize.suggestion(ctx, text)
      if suggestion ~= '' then
        opts.on_partial(suggestion)
      end
    end
  end

  if opts.on_complete then
    wrapped_opts.on_complete = function(text)
      local suggestion = sanitize.suggestion(ctx, text)
      if suggestion ~= '' then
        opts.on_complete(suggestion)
      else
        opts.on_complete(nil)
      end
    end
  end

  backend.complete(ctx, wrapped_opts)
end

return M
