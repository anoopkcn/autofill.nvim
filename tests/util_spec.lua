local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local util = require('autofill.util')
  local original_columns = vim.o.columns

  vim.o.columns = 12

  local preview = util.preview_text('abcdefghijklmnop', { max_width = 11 })
  assert(preview == 'abcdefgh...', 'preview_text should clamp long single-line text')
  assert(vim.fn.strdisplaywidth(preview) <= 11, 'preview_text should fit inside the requested width')

  local collapsed = util.preview_text('alpha\nbeta\tgamma', {
    single_line = true,
    max_width = 11,
  })
  assert(collapsed == 'alpha be...', 'preview_text should collapse whitespace before truncating')

  local wide = util.preview_text('界界界界界界', { max_width = 7 })
  assert(vim.fn.strdisplaywidth(wide) <= 7, 'preview_text should use display width, not byte length')
  assert(wide == '界界...', 'preview_text should truncate wide characters safely')

  vim.o.columns = original_columns
  helpers.reset_runtime()
end
