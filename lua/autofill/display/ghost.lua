local util = require('autofill.util')

local M = {}

local ns = vim.api.nvim_create_namespace('autofill_ghost')
local states = {}
local THROTTLE_MS = 75
local plug_keymaps_installed = false
local direct_keymaps = {}

local PLUG_MAPPINGS = {
  accept = '<Plug>(AutofillAccept)',
  accept_word = '<Plug>(AutofillAcceptWord)',
  dismiss = '<Plug>(AutofillDismiss)',
}

local FALLBACK_MAPPINGS = {
  accept = '<Plug>(AutofillFallbackAccept)',
  accept_word = '<Plug>(AutofillFallbackAcceptWord)',
  dismiss = '<Plug>(AutofillFallbackDismiss)',
}

local KEYMAP_ORDER = { 'accept', 'accept_word', 'dismiss' }

local KEYMAP_SPECS = {
  accept = {
    desc = 'Autofill: accept suggestion',
    plug = PLUG_MAPPINGS.accept,
    invoke = function()
      vim.schedule(M.accept)
    end,
  },
  accept_word = {
    desc = 'Autofill: accept word',
    plug = PLUG_MAPPINGS.accept_word,
    invoke = function()
      vim.schedule(M.accept_word)
    end,
  },
  dismiss = {
    desc = 'Autofill: dismiss suggestion',
    plug = PLUG_MAPPINGS.dismiss,
    invoke = function()
      M.clear()
    end,
  },
}

local function resolve_bufnr(bufnr)
  if bufnr ~= nil then
    return bufnr
  end
  return vim.api.nvim_get_current_buf()
end

local function get_buffer_state(bufnr, create)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  if not state and create then
    state = {
      bufnr = bufnr,
      line = nil,
      col = nil,
      text = nil,
      extmark_id = nil,
      last_render_time = 0,
    }
    states[bufnr] = state
  end
  if state then
    state.bufnr = bufnr
  end
  return state, bufnr
end

local function reset_state(state)
  if not state then return end
  state.line = nil
  state.col = nil
  state.text = nil
  state.extmark_id = nil
end

local function render_state(state)
  if not state or not state.text or not state.bufnr then return end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    M.clear(state.bufnr)
    return
  end

  local lines = vim.split(state.text, '\n', { plain = true })
  if #lines == 0 then return end

  local opts = {
    virt_text = { { lines[1], 'AutofillGhost' } },
    virt_text_pos = 'inline',
    hl_mode = 'combine',
  }

  if state.extmark_id then
    opts.id = state.extmark_id
  end

  if #lines > 1 then
    local virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { lines[i], 'AutofillGhost' } })
    end
    opts.virt_lines = virt_lines
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(
    state.bufnr,
    ns,
    state.line - 1,
    state.col,
    opts
  )
end

local function position_at_or_before(row_a, col_a, row_b, col_b)
  return row_a < row_b or (row_a == row_b and col_a <= col_b)
end

local function text_between(bufnr, start_row, start_col, end_row, end_col)
  local lines = vim.api.nvim_buf_get_text(
    bufnr,
    start_row - 1,
    start_col,
    end_row - 1,
    end_col,
    {}
  )
  return table.concat(lines, '\n')
end

local function delete_insert_mapping(lhs)
  if lhs then
    pcall(vim.keymap.del, 'i', lhs)
  end
end

local function get_insert_mapping(lhs)
  local mapping = vim.fn.maparg(lhs, 'i', false, true)
  if type(mapping) == 'table' and not vim.tbl_isempty(mapping) then
    return mapping
  end
  return nil
end

local function clone_insert_mapping(mapping)
  if not mapping then
    return nil
  end

  return {
    lhs = mapping.lhs,
    rhs = mapping.rhs,
    callback = mapping.callback,
    expr = mapping.expr,
    noremap = mapping.noremap,
    nowait = mapping.nowait,
    replace_keycodes = mapping.replace_keycodes,
    silent = mapping.silent,
    desc = mapping.desc,
    buffer = mapping.buffer,
  }
end

local function mapping_set_opts(mapping)
  return {
    expr = mapping.expr == 1,
    noremap = mapping.noremap == 1,
    nowait = mapping.nowait == 1,
    replace_keycodes = mapping.replace_keycodes == 1,
    silent = mapping.silent == 1,
    desc = mapping.desc,
  }
end

local function restore_insert_mapping(lhs, mapping)
  if not lhs or not mapping then
    return
  end

  local opts = mapping_set_opts(mapping)
  if mapping.callback then
    vim.keymap.set('i', lhs, mapping.callback, opts)
  elseif mapping.rhs and mapping.rhs ~= '' then
    vim.keymap.set('i', lhs, mapping.rhs, opts)
  end
end

local function ensure_plug_keymaps()
  if plug_keymaps_installed then return end

  for _, name in ipairs(KEYMAP_ORDER) do
    local spec = KEYMAP_SPECS[name]
    vim.keymap.set('i', spec.plug, function()
      if M.is_visible() then
        spec.invoke()
      end
    end, { silent = true, desc = spec.desc })
  end

  plug_keymaps_installed = true
end

local function install_fallback_keymap(name, mapping)
  local plug = FALLBACK_MAPPINGS[name]
  if not plug or not mapping then
    return nil
  end

  if mapping.buffer == 1 then
    util.log('warn', 'Skipping keymap wrap for buffer-local mapping ' .. mapping.lhs .. '. Use ' .. KEYMAP_SPECS[name].plug .. ' instead.')
    return nil
  end

  delete_insert_mapping(plug)

  local opts = mapping_set_opts(mapping)

  if mapping.callback then
    vim.keymap.set('i', plug, mapping.callback, opts)
  elseif mapping.rhs and mapping.rhs ~= '' then
    vim.keymap.set('i', plug, mapping.rhs, opts)
  else
    return nil
  end

  return plug
end

local function feed_keys(lhs, remap)
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, remap and 'im' or 'in', false)
end

local function run_direct_fallback(name, lhs)
  local mapping = direct_keymaps[name]
  if mapping and mapping.fallback then
    feed_keys(mapping.fallback, true)
    return
  end

  feed_keys(lhs, false)
end

local function install_direct_keymap(name, lhs)
  local spec = KEYMAP_SPECS[name]
  if not spec or not lhs then return end

  local existing = get_insert_mapping(lhs)
  if existing and existing.buffer == 1 then
    util.log('warn', 'Skipping keymap ' .. lhs .. '; existing buffer-local mapping cannot be wrapped safely. Use ' .. spec.plug .. ' instead.')
    return
  end

  local fallback = install_fallback_keymap(name, existing)

  vim.keymap.set('i', lhs, function()
    if M.is_visible() then
      spec.invoke()
      return
    end
    run_direct_fallback(name, lhs)
  end, { noremap = true, silent = true, desc = spec.desc })

  direct_keymaps[name] = {
    lhs = lhs,
    fallback = fallback,
    original = clone_insert_mapping(existing),
  }
end

function M.is_visible(bufnr)
  local state = get_buffer_state(bufnr, false)
  return state ~= nil and state.text ~= nil
end

function M.get_state(bufnr)
  return get_buffer_state(bufnr, false)
end

function M.show(bufnr, line, col, text, is_partial)
  if not text or text == '' then return end
  local state = get_buffer_state(bufnr, true)
  if state.line == line and state.col == col and state.text == text then
    return
  end

  -- Throttle partial (streaming) renders to avoid flicker, but let the first one through
  if is_partial and state.text ~= nil then
    local now = vim.uv.now()
    if now - state.last_render_time < THROTTLE_MS then
      return
    end
  end

  state.line = line
  state.col = col
  state.text = text

  render_state(state)
  state.last_render_time = vim.uv.now()
end

function M._render(bufnr)
  local state = get_buffer_state(bufnr, false)
  render_state(state)
end

function M.clear(bufnr)
  local state, target = get_buffer_state(bufnr, false)
  target = target or resolve_bufnr(bufnr)
  if target and vim.api.nvim_buf_is_valid(target) then
    vim.api.nvim_buf_clear_namespace(target, ns, 0, -1)
  end
  reset_state(state)
end

function M.clear_all()
  for bufnr, state in pairs(states) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
    reset_state(state)
  end
end

function M.accept(bufnr)
  local state = get_buffer_state(bufnr, false)
  if not state or not state.text then return false end

  local text = state.text
  M.clear(state.bufnr)

  -- Insert the text at the cursor
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_put(lines, 'c', false, true)

  return true
end

function M.accept_word(bufnr)
  local state = get_buffer_state(bufnr, false)
  if not state or not state.text then return false end

  -- Extract the next word
  local word = state.text:match('^(%S+)')
  if not word then
    -- Next "word" is whitespace up to next non-whitespace
    word = state.text:match('^(%s+)')
  end
  if not word then return false end

  local remainder = state.text:sub(#word + 1)
  M.clear(state.bufnr)

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
  local state = get_buffer_state(bufnr, false)
  if not state or not state.text or state.bufnr ~= bufnr then return false end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  if position_at_or_before(row, col, state.line, state.col) then return false end

  local typed = text_between(bufnr, state.line, state.col, row, col)
  local suggestion_prefix = state.text:sub(1, #typed)

  if typed == suggestion_prefix then
    -- Typed chars match the suggestion prefix — trim and re-render
    local remainder = state.text:sub(#typed + 1)
    if remainder == '' then
      M.clear()
      return true
    end
    -- Update state in-place and re-render
    state.line = row
    state.col = col
    state.text = remainder
    render_state(state)
    state.last_render_time = vim.uv.now()
    return true
  end

  -- Typed chars don't match — dismiss
  M.clear()
  return false
end

function M.get_plug_mappings()
  return vim.deepcopy(PLUG_MAPPINGS)
end

function M.setup_keymaps(opts)
  opts = opts or {}

  local config = require('autofill.config').get()
  local keymaps = config.keymaps or {}
  local enable_direct = opts.enable_direct ~= false

  M.teardown_keymaps({ direct = true })
  ensure_plug_keymaps()

  if not enable_direct then
    return
  end

  for _, name in ipairs(KEYMAP_ORDER) do
    local lhs = keymaps[name]
    if lhs then
      install_direct_keymap(name, lhs)
    end
  end
end

function M.teardown_keymaps(opts)
  opts = opts or {}

  if opts.direct ~= false then
    for _, name in ipairs(KEYMAP_ORDER) do
      local mapping = direct_keymaps[name]
      if mapping then
        delete_insert_mapping(mapping.lhs)
        delete_insert_mapping(mapping.fallback)
        restore_insert_mapping(mapping.lhs, mapping.original)
      end
      direct_keymaps[name] = nil
    end
  end

  if opts.plug then
    for _, name in ipairs(KEYMAP_ORDER) do
      delete_insert_mapping(PLUG_MAPPINGS[name])
    end
    plug_keymaps_installed = false
  end
end

return M
