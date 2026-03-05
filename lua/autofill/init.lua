local M = {}

function M.setup(opts)
  local config = require('autofill.config')
  config.setup(opts)

  -- Define highlight group
  vim.api.nvim_set_hl(0, 'AutofillGhost', { link = 'Comment', default = true })

  -- Setup keymaps
  require('autofill.display.ghost').setup_keymaps()

  -- Start the trigger system if enabled
  if config.get().enabled then
    require('autofill.trigger').start()
  end
end

function M.enable()
  local config = require('autofill.config').get()
  config.enabled = true
  require('autofill.trigger').start()
  require('autofill.util').log('info', 'Enabled')
end

function M.disable()
  local config = require('autofill.config').get()
  config.enabled = false
  require('autofill.trigger').stop()
  require('autofill.util').log('info', 'Disabled')
end

function M.toggle()
  local config = require('autofill.config').get()
  if config.enabled then
    M.disable()
  else
    M.enable()
  end
end

return M
