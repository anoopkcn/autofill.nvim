local M = {}

local _enabled = nil -- nil = use config default

function M.setup(opts)
  local config = require('autofill.config')
  config.setup(opts)
  _enabled = nil -- reset to config default on setup

  -- Define highlight group
  vim.api.nvim_set_hl(0, 'AutofillGhost', { link = 'Comment', default = true })

  -- Setup keymaps
  require('autofill.display.ghost').setup_keymaps()

  -- Start the trigger system if enabled
  if M.is_enabled() then
    require('autofill.trigger').start()
  end
end

function M.is_enabled()
  if _enabled ~= nil then
    return _enabled
  end
  return require('autofill.config').get().enabled
end

function M.enable()
  _enabled = true
  require('autofill.trigger').start()
  require('autofill.util').log('info', 'Enabled')
end

function M.disable()
  _enabled = false
  require('autofill.trigger').stop()
  require('autofill.display.ghost').teardown_keymaps()
  require('autofill.util').log('info', 'Disabled')
end

function M.toggle()
  if M.is_enabled() then
    M.disable()
  else
    M.enable()
  end
end

return M
