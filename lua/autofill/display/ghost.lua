local M = {}

local ns = vim.api.nvim_create_namespace('autofill_ghost')
local state = {
  bufnr = nil,
  line = nil,
  col = nil,
  text = nil,
  extmark_id = nil,
}

function M.is_visible()
  return state.text ~= nil
end

function M.get_state()
  return state
end

function M.show(bufnr, line, col, text)
  M.clear()

  if not text or text == '' then return end

  state.bufnr = bufnr
  state.line = line
  state.col = col
  state.text = text

  M._render()
end

function M._render()
  if not state.text or not state.bufnr then return end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    M.clear()
    return
  end

  local lines = vim.split(state.text, '\n', { plain = true })
  if #lines == 0 then return end

  local opts = {
    virt_text = { { lines[1], 'AutofillGhost' } },
    virt_text_pos = 'inline',
    hl_mode = 'combine',
  }

  if #lines > 1 then
    local virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { lines[i], 'AutofillGhost' } })
    end
    opts.virt_lines = virt_lines
  end

  -- Place extmark at current cursor line (0-indexed)
  state.extmark_id = vim.api.nvim_buf_set_extmark(
    state.bufnr,
    ns,
    state.line - 1,
    state.col,
    opts
  )
end

function M.clear(bufnr)
  local target = bufnr or state.bufnr
  if target and vim.api.nvim_buf_is_valid(target) then
    vim.api.nvim_buf_clear_namespace(target, ns, 0, -1)
  end
  state.bufnr = nil
  state.line = nil
  state.col = nil
  state.text = nil
  state.extmark_id = nil
end

function M.accept()
  if not state.text then return false end

  local text = state.text
  M.clear()

  -- Insert the text at the cursor
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_put(lines, 'c', false, true)

  return true
end

function M.accept_word()
  if not state.text then return false end

  -- Extract the next word
  local word = state.text:match('^(%S+)')
  if not word then
    -- Next "word" is whitespace up to next non-whitespace
    word = state.text:match('^(%s+)')
  end
  if not word then return false end

  local remainder = state.text:sub(#word + 1)
  M.clear()

  -- Insert the word
  local word_lines = vim.split(word, '\n', { plain = true })
  vim.api.nvim_put(word_lines, 'c', false, true)

  -- Re-render the rest if there is any
  if remainder and remainder ~= '' then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local bufnr = vim.api.nvim_get_current_buf()
    M.show(bufnr, cursor[1], cursor[2], remainder)
  end

  return true
end

function M.advance(bufnr)
  if not state.text or state.bufnr ~= bufnr then return false end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''

  -- The text typed since the suggestion was shown
  if row ~= state.line then
    M.clear()
    return false
  end

  if col <= state.col then return false end

  -- Get the typed characters since the suggestion was placed
  local typed = current_line:sub(state.col + 1, col)
  local suggestion_prefix = state.text:sub(1, #typed)

  if typed == suggestion_prefix then
    -- Typed chars match the suggestion prefix — trim and re-render
    local remainder = state.text:sub(#typed + 1)
    if remainder == '' then
      M.clear()
      return true
    end
    -- Update state in-place and re-render
    state.col = col
    state.text = remainder
    -- Clear old extmark and render new one
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    M._render()
    return true
  end

  -- Typed chars don't match — dismiss
  M.clear()
  return false
end

function M.setup_keymaps()
  local config = require('autofill.config').get()
  local keymaps = config.keymaps

  if keymaps.accept then
    vim.keymap.set('i', keymaps.accept, function()
      if M.is_visible() then
        vim.schedule(M.accept)
        return ''
      end
      return vim.api.nvim_replace_termcodes(keymaps.accept, true, false, true)
    end, { expr = true, noremap = true, desc = 'Autofill: accept suggestion' })
  end

  if keymaps.accept_word then
    vim.keymap.set('i', keymaps.accept_word, function()
      if M.is_visible() then
        vim.schedule(M.accept_word)
        return ''
      end
      return vim.api.nvim_replace_termcodes(keymaps.accept_word, true, false, true)
    end, { expr = true, noremap = true, desc = 'Autofill: accept word' })
  end

  if keymaps.dismiss then
    vim.keymap.set('i', keymaps.dismiss, function()
      if M.is_visible() then
        M.clear()
        return ''
      end
      return vim.api.nvim_replace_termcodes(keymaps.dismiss, true, false, true)
    end, { expr = true, noremap = true, desc = 'Autofill: dismiss suggestion' })
  end
end

return M
