local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local autofill = require('autofill')
  local backend = require('autofill.backend')
  local ghost = require('autofill.display.ghost')
  local original_mode = vim.fn.mode
  local original_virtualedit = vim.o.virtualedit

  local original_complete = backend.complete
  local calls = 0

  backend.complete = function()
    calls = calls + 1
  end

  autofill.setup({
    enabled = true,
    debounce_ms = 0,
    throttle_ms = 0,
  })

  local bufnr = helpers.new_buffer({ '' }, {
    filetype = 'lua',
    row = 1,
    col = 0,
  })

  vim.o.virtualedit = 'onemore'
  vim.fn.mode = function()
    return 'i'
  end

  ghost.show(bufnr, 1, 0, 'abc')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  assert(calls == 0, 'typing through visible ghost text should not request a new completion')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ghost.show(bufnr, 1, 0, 'xyz')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  helpers.wait(200, function()
    return calls == 1
  end, 'non-matching typed text should request a new completion')

  calls = 0
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ghost.show(bufnr, 1, 0, 'foo\nbar')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo' })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  local state = ghost.get_state(bufnr)
  assert(calls == 0, 'typing through the first line of a multiline ghost text should not request a new completion')
  assert(state and state.text == '\nbar', 'typing through a multiline suggestion should preserve the newline remainder')
  assert(state.line == 1 and state.col == 3, 'multiline ghost text should re-anchor at the updated cursor position on the same line')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo', '' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  state = ghost.get_state(bufnr)
  assert(calls == 0, 'typing through the newline of a multiline ghost text should not request a new completion')
  assert(state and state.text == 'bar', 'typing through the newline should move the remainder to the next line')
  assert(state.line == 2 and state.col == 0, 'multiline ghost text should re-anchor at the next line after typing a newline')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo', 'bar' })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  assert(calls == 0, 'typing through the final line of a multiline ghost text should not request a new completion')
  assert(not ghost.is_visible(bufnr), 'typing through the entire multiline ghost text should dismiss it')

  local requests = {}
  backend.complete = function(_, opts)
    requests[#requests + 1] = opts
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  helpers.wait(200, function()
    return #requests == 1
  end, 'first completion request was not scheduled')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'ab' })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  helpers.wait(200, function()
    return #requests == 2
  end, 'second completion request was not scheduled')

  vim.wait(100)
  requests[1].on_partial('old partial')
  requests[1].on_complete('old completion')
  vim.wait(20)
  assert(not ghost.is_visible(bufnr), 'stale request callbacks should not render ghost text')

  requests[2].on_partial('new partial')
  helpers.wait(200, function()
    local state = ghost.get_state(bufnr)
    return state and state.text == 'new partial'
  end, 'current request partial should render ghost text')

  requests[2].on_complete('new completion')
  helpers.wait(200, function()
    local state = ghost.get_state(bufnr)
    return state and state.text == 'new completion'
  end, 'current request completion should replace the partial ghost text')

  requests = {}
  backend.complete = function(_, opts)
    requests[#requests + 1] = opts
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'abc' })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  helpers.wait(200, function()
    return #requests == 1
  end, 'insert-leave request was not scheduled')

  vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr })
  requests[1].on_complete('ignored after leave')
  vim.wait(20)
  assert(not ghost.is_visible(bufnr), 'responses after InsertLeave should be ignored')

  vim.o.virtualedit = original_virtualedit
  vim.fn.mode = original_mode
  backend.complete = original_complete
  helpers.reset_runtime()
end
