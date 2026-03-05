local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local autofill = require('autofill')
  local accept_key = helpers.test_keys()[1]

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

  helpers.reset_runtime()
end
