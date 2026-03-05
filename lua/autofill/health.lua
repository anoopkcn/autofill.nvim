local M = {}

local function health_fn(name, legacy)
  local health = vim.health or {}
  if health[name] then
    return health[name]
  end
  return health['report_' .. legacy]
end

local start = health_fn('start', 'start')
local ok = health_fn('ok', 'ok')
local warn = health_fn('warn', 'warn')
local error_report = health_fn('error', 'error')
local info = health_fn('info', 'info')

local function join_lines(items)
  return table.concat(items, '\n- ')
end

function M.check()
  local config = require('autofill.config')
  local backend = require('autofill.backend')
  local ghost = require('autofill.display.ghost')
  local options = config.get()

  start('autofill.nvim')

  local validation = config.inspect(options)
  if #validation.errors > 0 then
    error_report('Configuration is invalid:\n- ' .. join_lines(validation.errors))
  else
    ok('Configuration is valid')
  end

  for _, message in ipairs(validation.warnings) do
    warn(message)
  end

  local runtime = backend.inspect_runtime(options)
  if #runtime.errors > 0 then
    error_report('Runtime prerequisites missing:\n- ' .. join_lines(runtime.errors))
  else
    ok('Runtime prerequisites satisfied')
  end

  for _, message in ipairs(runtime.warnings) do
    warn(message)
  end

  info('Configured backend: ' .. options.backend)
  info('Direct keymaps: ' .. vim.inspect(options.keymaps))
  info('Plug mappings: ' .. vim.inspect(ghost.get_plug_mappings()))
end

return M
