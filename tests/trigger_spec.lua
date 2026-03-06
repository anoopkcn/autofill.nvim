local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local autofill = require('autofill')
  local backend = require('autofill.backend')
  local ghost = require('autofill.display.ghost')
  local lsp_context = require('autofill.context.lsp')
  local original_mode = vim.fn.mode
  local original_virtualedit = vim.o.virtualedit

  local original_complete = backend.complete
  local original_refresh_symbols = lsp_context.refresh_symbols
  local original_mark_symbols_dirty = lsp_context.mark_symbols_dirty
  local calls = 0
  local symbol_refreshes = {}
  local dirty_marks = 0

  lsp_context.refresh_symbols = function(bufnr, opts)
    symbol_refreshes[#symbol_refreshes + 1] = {
      bufnr = bufnr,
      opts = opts or {},
    }
  end

  lsp_context.mark_symbols_dirty = function(_)
    dirty_marks = dirty_marks + 1
  end

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

  local initial_symbol_refreshes = #symbol_refreshes
  ghost.show(bufnr, 1, 0, 'abc')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  assert(calls == 0, 'typing through visible ghost text should not request a new completion')
  assert(#symbol_refreshes == initial_symbol_refreshes, 'insert-mode edits should not refresh LSP symbols immediately')
  assert(dirty_marks == 1, 'insert-mode edits should mark document symbols dirty')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ghost.show(bufnr, 1, 0, 'xyz')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a' })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  helpers.wait(200, function()
    return calls == 1
  end, 'non-matching typed text should request a new completion')
  assert(#symbol_refreshes == initial_symbol_refreshes, 'non-matching insert edits should still avoid immediate LSP symbol refreshes')
  assert(dirty_marks == 2, 'each insert edit should keep marking symbols dirty')

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
  assert(#symbol_refreshes == initial_symbol_refreshes, 'typing through multiline ghost text should not refresh LSP symbols mid-insert')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo', '' })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  state = ghost.get_state(bufnr)
  assert(calls == 0, 'typing through the newline of a multiline ghost text should not request a new completion')
  assert(state and state.text == 'bar', 'typing through the newline should move the remainder to the next line')
  assert(state.line == 2 and state.col == 0, 'multiline ghost text should re-anchor at the next line after typing a newline')
  assert(#symbol_refreshes == initial_symbol_refreshes, 'newline typing should still defer LSP symbol refreshes until insert exit')

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo', 'bar' })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
  vim.wait(100)
  assert(calls == 0, 'typing through the final line of a multiline ghost text should not request a new completion')
  assert(not ghost.is_visible(bufnr), 'typing through the entire multiline ghost text should dismiss it')
  assert(#symbol_refreshes == initial_symbol_refreshes, 'consuming multiline ghost text should not refresh LSP symbols while insert mode is active')

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
  assert(#symbol_refreshes == initial_symbol_refreshes + 1, 'InsertLeave should trigger a single deferred LSP symbol refresh after dirty insert edits')
  assert(symbol_refreshes[#symbol_refreshes].bufnr == bufnr, 'InsertLeave should refresh symbols for the active buffer')
  assert(symbol_refreshes[#symbol_refreshes].opts.immediate and symbol_refreshes[#symbol_refreshes].opts.if_dirty, 'InsertLeave should request an immediate refresh only when symbols were dirtied in insert mode')

  vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
  assert(#symbol_refreshes == initial_symbol_refreshes + 2, 'normal-mode text changes should still refresh LSP symbols')

  vim.o.virtualedit = original_virtualedit
  vim.fn.mode = original_mode
  backend.complete = original_complete
  lsp_context.refresh_symbols = original_refresh_symbols
  lsp_context.mark_symbols_dirty = original_mark_symbols_dirty
  helpers.reset_runtime()
end
