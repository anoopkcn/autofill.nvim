local ghost = require('autofill.display.ghost')
local context = require('autofill.context')
local buffer_context = require('autofill.context.buffer')
local lsp_context = require('autofill.context.lsp')
local neighbors_context = require('autofill.context.neighbors')
local backend = require('autofill.backend')
local request = require('autofill.transport.request')
local cache = require('autofill.cache')
local profiler = require('autofill.profiler')
local util = require('autofill.util')

local M = {}

local timer = nil
local last_request_time = 0
local last_input_time = 0
local augroup = nil
local change_seq = 0
local pending_snapshot = nil
local active_request_seq = 0

local PARTIAL_IDLE_MS = 75

local function clone_cursor(cursor)
  return { cursor[1], cursor[2] }
end

local function same_cursor(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2]
end

local function make_snapshot(bufnr, cursor, seq, profile)
  return {
    bufnr = bufnr,
    cursor = clone_cursor(cursor),
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    seq = seq,
    profile = profile,
  }
end

local function snapshot_is_current(snapshot)
  if not snapshot or not augroup then return false end
  if vim.fn.mode() ~= 'i' then return false end
  if snapshot.seq ~= change_seq then return false end
  if not vim.api.nvim_buf_is_valid(snapshot.bufnr) then return false end
  if vim.api.nvim_get_current_buf() ~= snapshot.bufnr then return false end
  if vim.api.nvim_buf_get_changedtick(snapshot.bufnr) ~= snapshot.changedtick then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  return same_cursor(cursor, snapshot.cursor)
end

local function finalize_profile(snapshot)
  profiler.mark(snapshot.profile, 'final_render')
  profiler.finish(snapshot.profile)
end

local function show_suggestion(snapshot, suggestion, is_partial)
  if not snapshot_is_current(snapshot) then return false end

  local new_cursor = vim.api.nvim_win_get_cursor(0)
  ghost.show(snapshot.bufnr, new_cursor[1], new_cursor[2], suggestion, is_partial)

  if not is_partial then
    finalize_profile(snapshot)
  end

  return true
end

local function do_complete(snapshot)
  local config = require('autofill.config').get()
  if not snapshot_is_current(snapshot) then return end

  profiler.mark(snapshot.profile, 'timer_fire')

  local bufnr = snapshot.bufnr
  local cursor = snapshot.cursor
  local filetype = vim.bo[bufnr].filetype
  local buf_ctx = buffer_context.get_text(bufnr, cursor)
  local cache_scope = cache.scope(config)
  local quick_key = cache.quick_key({
    scope = cache_scope,
    bufnr = bufnr,
    row = cursor[1],
    filetype = filetype,
    context_revision = table.concat({
      lsp_context.get_revision(bufnr),
      neighbors_context.get_revision(bufnr),
    }, ':'),
    before_cursor = buf_ctx.before,
    after_cursor = buf_ctx.after,
  })

  local quick_cached = cache.get_quick(quick_key)
  if quick_cached then
    profiler.mark(snapshot.profile, 'quick_cache_hit')
    show_suggestion(snapshot, quick_cached, false)
    return
  end

  local ctx = context.gather(bufnr, cursor, { buffer = buf_ctx })
  profiler.mark(snapshot.profile, 'context_ready')

  local cache_key = cache.key(ctx, cache_scope)
  local cached = cache.get(cache_key)
  if cached then
    cache.set_quick(quick_key, cached, { bufnr = bufnr })
    show_suggestion(snapshot, cached, false)
    return
  end

  last_request_time = vim.uv.now()
  active_request_seq = snapshot.seq
  profiler.mark(snapshot.profile, 'request_sent')

  local opts = {
    on_complete = function(suggestion)
      if active_request_seq == snapshot.seq then
        active_request_seq = 0
      end
      if not snapshot_is_current(snapshot) then return end
      cache.set(cache_key, suggestion)
      cache.set_quick(quick_key, suggestion, { bufnr = bufnr })
      show_suggestion(snapshot, suggestion, false)
    end,
  }

  if config.streaming_display then
    opts.on_partial = function(text_so_far)
      if not snapshot_is_current(snapshot) then return end
      if vim.uv.now() - last_input_time < PARTIAL_IDLE_MS then return end

      profiler.mark(snapshot.profile, 'first_partial')
      vim.schedule(function()
        show_suggestion(snapshot, text_so_far, true)
      end)
    end
  end

  backend.complete(ctx, opts)
end

local function schedule_complete()
  if not pending_snapshot then return end

  local config = require('autofill.config').get()
  local now = vim.uv.now()
  local elapsed = now - last_request_time
  local delay = config.debounce_ms

  -- Apply throttle: if we recently sent a request, add extra delay
  if elapsed < config.throttle_ms then
    local throttle_delay = config.throttle_ms - elapsed
    if throttle_delay > delay then
      delay = throttle_delay
    end
  end

  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
    if not timer then return end
  end

  timer:start(delay, 0, vim.schedule_wrap(function()
    if not augroup then return end
    local snapshot = pending_snapshot
    pending_snapshot = nil
    if snapshot and vim.fn.mode() == 'i' then
      do_complete(snapshot)
    end
  end))
end

local function on_text_changed()
  if not require('autofill').is_enabled() then return end

  local config = require('autofill.config').get()
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype

  -- Check filetype exclusion
  for _, excluded in ipairs(config.filetypes_exclude) do
    if ft == excluded then return end
  end

  last_input_time = vim.uv.now()
  change_seq = change_seq + 1

  -- Try to advance existing ghost text
  if ghost.is_visible() then
    ghost.advance(bufnr)
  end

  pending_snapshot = make_snapshot(
    bufnr,
    vim.api.nvim_win_get_cursor(0),
    change_seq,
    profiler.start('completion')
  )

  -- Schedule a new completion
  schedule_complete()
end

local function on_insert_leave()
  if timer then
    timer:stop()
  end
  pending_snapshot = nil
  active_request_seq = 0
  request.cancel()
  ghost.clear()
end

local function on_buf_leave()
  local bufnr = vim.api.nvim_get_current_buf()
  if timer then
    timer:stop()
  end
  pending_snapshot = nil
  active_request_seq = 0
  cache.clear_quick_for_buffer(bufnr)
  request.cancel()
  ghost.clear()
end

function M.start()
  if augroup then return end

  augroup = vim.api.nvim_create_augroup('autofill_trigger', { clear = true })

  vim.api.nvim_create_autocmd('TextChangedI', {
    group = augroup,
    callback = on_text_changed,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group = augroup,
    callback = on_insert_leave,
  })

  vim.api.nvim_create_autocmd('BufLeave', {
    group = augroup,
    callback = on_buf_leave,
  })

  -- LSP symbol refresh
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'LspAttach' }, {
    group = augroup,
    callback = function(ev)
      lsp_context.refresh_symbols(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'DiagnosticChanged' }, {
    group = augroup,
    callback = function(ev)
      lsp_context.refresh_diagnostics(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufAdd', 'BufDelete', 'BufEnter', 'BufFilePost', 'BufWipeout', 'FileType' }, {
    group = augroup,
    callback = function()
      neighbors_context.mark_candidates_dirty()
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = augroup,
    callback = function(ev)
      lsp_context.clear(ev.buf)
      neighbors_context.clear(ev.buf)
      cache.clear_quick_for_buffer(ev.buf)
    end,
  })

  util.log('debug', 'Trigger system started')
end

function M.stop()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  pending_snapshot = nil
  active_request_seq = 0
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    cache.clear_quick_for_buffer(bufnr)
  end
  request.cancel()
  ghost.clear()
  util.log('debug', 'Trigger system stopped')
end

return M
