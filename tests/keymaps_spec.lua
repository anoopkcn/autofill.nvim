local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local autofill = require('autofill')
  local accept_key = helpers.test_keys()[1]
  local restore_key = helpers.test_keys()[2]
  local callback_key = helpers.test_keys()[3]

  autofill.setup({
    enabled = false,
    keymaps = {
      accept = accept_key,
    },
  })

  assert(vim.fn.maparg(accept_key, 'i') == '', 'setup(enabled=false) should not install direct keymaps')

  autofill.enable()
  assert(vim.fn.maparg(accept_key, 'i') ~= '', 'enable() should install configured direct keymaps')

  autofill.disable()
  assert(vim.fn.maparg(accept_key, 'i') == '', 'disable() should remove configured direct keymaps')

  autofill.enable()
  assert(vim.fn.maparg(accept_key, 'i') ~= '', 'enable() should restore configured direct keymaps')

  vim.keymap.set('i', restore_key, 'orig-rhs', { noremap = true, silent = true })
  autofill.setup({
    enabled = true,
    keymaps = {
      accept = restore_key,
    },
  })
  assert(vim.fn.maparg(restore_key, 'i') ~= 'orig-rhs', 'plugin should wrap an existing global mapping while enabled')

  autofill.disable()
  local restored = vim.fn.maparg(restore_key, 'i', false, true)
  assert(type(restored) == 'table' and restored.rhs == 'orig-rhs', 'disable() should restore the original rhs mapping')
  assert(restored.noremap == 1 and restored.silent == 1, 'disable() should preserve rhs mapping options')

  local callback = function()
    return 'orig-callback'
  end
  vim.keymap.set('i', callback_key, callback, {
    expr = true,
    noremap = true,
    replace_keycodes = true,
    silent = true,
  })
  autofill.setup({
    enabled = true,
    keymaps = {
      accept = callback_key,
    },
  })

  autofill.disable()
  local restored_callback = vim.fn.maparg(callback_key, 'i', false, true)
  assert(type(restored_callback) == 'table' and restored_callback.callback ~= nil, 'disable() should restore callback mappings')
  assert(restored_callback.expr == 1 and restored_callback.replace_keycodes == 1, 'disable() should preserve callback mapping options')
  assert(restored_callback.callback() == 'orig-callback', 'disable() should restore the original callback implementation')

  helpers.reset_runtime()
end
