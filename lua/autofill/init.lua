local M = {}

local _enabled = nil -- nil = use config default

local function sync_runtime_state()
  local ghost = require('autofill.display.ghost')
  local trigger = require('autofill.trigger')

  ghost.setup_keymaps({ enable_direct = M.is_enabled() })

  if M.is_enabled() then
    trigger.start()
  else
    trigger.stop()
  end
end

function M.setup(opts)
  local config = require('autofill.config')
  config.setup(opts)
  _enabled = nil -- reset to config default on setup

  -- Define highlight group
  vim.api.nvim_set_hl(0, 'AutofillGhost', { link = 'Comment', default = true })

  sync_runtime_state()
end

function M.is_enabled()
  if _enabled ~= nil then
    return _enabled
  end
  return require('autofill.config').get().enabled
end

function M.enable()
  local was_enabled = M.is_enabled()
  _enabled = true
  sync_runtime_state()
  if not was_enabled then
    require('autofill.util').log('info', 'Enabled')
  end
end

function M.disable()
  local was_enabled = M.is_enabled()
  _enabled = false
  sync_runtime_state()
  if was_enabled then
    require('autofill.util').log('info', 'Disabled')
  end
end

function M.toggle()
  if M.is_enabled() then
    M.disable()
  else
    M.enable()
  end
end

return M
