local ghost = require('autofill.display.ghost')
local context = require('autofill.context')
local buffer_context = require('autofill.context.buffer')
local lsp_context = require('autofill.context.lsp')
local neighbors_context = require('autofill.context.neighbors')
local treesitter_context = require('autofill.context.treesitter')
local backend = require('autofill.backend')
local request = require('autofill.transport.request')
local cache = require('autofill.cache')
local profiler = require('autofill.profiler')
local util = require('autofill.util')

local M = {}

local augroup = nil
local sessions = {}

local PARTIAL_IDLE_MS = 75

local function lsp_enabled()
  local lsp_config = require('autofill.config').get().lsp or {}
  return lsp_config.enabled == true
end

local function ensure_session(bufnr)
  local session = sessions[bufnr]
  if session then
    return session
  end

  session = {
    timer = nil,
    last_request_time = 0,
    last_input_time = 0,
    change_seq = 0,
    pending_snapshot = nil,
    active_request_seq = 0,
  }
  sessions[bufnr] = session
  return session
end

local function get_session(bufnr)
  return sessions[bufnr]
end

local function close_session_timer(session)
  if not session or not session.timer then return end
  session.timer:stop()
  session.timer:close()
  session.timer = nil
end

local function clone_cursor(cursor)
  return { cursor[1], cursor[2] }
end

local function same_cursor(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2]
end

local function make_snapshot(bufnr, session, cursor, seq, profile)
  return {
    bufnr = bufnr,
    session = session,
    cursor = clone_cursor(cursor),
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    seq = seq,
    profile = profile,
  }
end

local function snapshot_is_current(snapshot)
  if not snapshot or not augroup then return false end
  local session = get_session(snapshot.bufnr)
  if session ~= snapshot.session then return false end
  if vim.fn.mode() ~= 'i' then return false end
  if snapshot.seq ~= session.change_seq then return false end
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
  local session = snapshot.session
  local cursor = snapshot.cursor
  local filetype = vim.bo[bufnr].filetype
  local buf_ctx = buffer_context.get_text(bufnr, cursor)
  local cache_scope = cache.scope(config)
  local quick_key = cache.quick_key({
    scope = cache_scope,
    bufnr = bufnr,
    row = cursor[1],
    filetype = filetype,
    context_revision = context.get_quick_revision(bufnr, cursor, { buffer = buf_ctx }),
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

  session.last_request_time = vim.uv.now()
  session.active_request_seq = snapshot.seq
  profiler.mark(snapshot.profile, 'request_sent')

  local opts = {
    request_session_key = bufnr,
    on_complete = function(suggestion)
      if get_session(bufnr) ~= session then return end
      if session.active_request_seq == snapshot.seq then
        session.active_request_seq = 0
      end
      if not snapshot_is_current(snapshot) then return end
      cache.set(cache_key, suggestion)
      cache.set_quick(quick_key, suggestion, { bufnr = bufnr })
      show_suggestion(snapshot, suggestion, false)
    end,
  }

  if config.streaming_display then
    local first_partial = true
    opts.on_partial = function(text_so_far)
      if get_session(bufnr) ~= session then return end
      if not snapshot_is_current(snapshot) then return end
      if not first_partial and vim.uv.now() - session.last_input_time < PARTIAL_IDLE_MS then return end

      first_partial = false
      profiler.mark(snapshot.profile, 'first_partial')
      vim.schedule(function()
        show_suggestion(snapshot, text_so_far, true)
      end)
    end
  end

  backend.complete(ctx, opts)
end

local function schedule_complete(bufnr, session)
  if not session or not session.pending_snapshot then return end

  local config = require('autofill.config').get()
  local now = vim.uv.now()
  local elapsed = now - session.last_request_time
  local delay = config.debounce_ms

  -- Apply throttle: if we recently sent a request, add extra delay
  if elapsed < config.throttle_ms then
    local throttle_delay = config.throttle_ms - elapsed
    if throttle_delay > delay then
      delay = throttle_delay
    end
  end

  if session.timer then
    session.timer:stop()
  else
    session.timer = vim.uv.new_timer()
    if not session.timer then return end
  end

  session.timer:start(delay, 0, vim.schedule_wrap(function()
    if not augroup then return end
    if get_session(bufnr) ~= session then return end
    local snapshot = session.pending_snapshot
    session.pending_snapshot = nil
    if snapshot and vim.fn.mode() == 'i' then
      do_complete(snapshot)
    end
  end))
end

local function clear_pending_completion(session)
  if not session then return end
  session.pending_snapshot = nil
  if session.timer then
    session.timer:stop()
  end
end

local function stop_buffer_session(bufnr, opts)
  opts = opts or {}

  local session = get_session(bufnr)
  if session then
    clear_pending_completion(session)
    session.active_request_seq = 0
    close_session_timer(session)
    sessions[bufnr] = nil
  end

  if opts.clear_cache then
    cache.clear_quick_for_buffer(bufnr)
  end

  request.cancel(bufnr)
  ghost.clear(bufnr)
end

local function on_text_changed()
  if not require('autofill').is_enabled() then return end

  local config = require('autofill.config').get()
  local bufnr = vim.api.nvim_get_current_buf()
  local session = ensure_session(bufnr)
  local ft = vim.bo[bufnr].filetype

  -- Check filetype exclusion
  for _, excluded in ipairs(config.filetypes_exclude) do
    if ft == excluded then return end
  end

  session.last_input_time = vim.uv.now()
  session.change_seq = session.change_seq + 1

  -- Try to advance existing ghost text
  if ghost.is_visible(bufnr) and ghost.advance(bufnr) then
    clear_pending_completion(session)
    return
  end

  session.pending_snapshot = make_snapshot(
    bufnr,
    session,
    vim.api.nvim_win_get_cursor(0),
    session.change_seq,
    profiler.start('completion')
  )

  -- Schedule a new completion
  schedule_complete(bufnr, session)
end

local function on_insert_leave(bufnr)
  if lsp_enabled() then
    lsp_context.refresh_symbols(bufnr, { immediate = true, if_dirty = true })
  end
  stop_buffer_session(bufnr)
end

local function on_buf_leave(bufnr)
  stop_buffer_session(bufnr, { clear_cache = true })
end

function M.start()
  if augroup then return end

  augroup = vim.api.nvim_create_augroup('autofill_trigger', { clear = true })

  vim.api.nvim_create_autocmd('TextChangedI', {
    group = augroup,
    callback = function(ev)
      if lsp_enabled() then
        lsp_context.mark_symbols_dirty(ev.buf)
      end
      on_text_changed()
    end,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group = augroup,
    callback = function(ev)
      on_insert_leave(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd('BufLeave', {
    group = augroup,
    callback = function(ev)
      on_buf_leave(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'LspAttach' }, {
    group = augroup,
    callback = function(ev)
      if lsp_enabled() then
        lsp_context.refresh_symbols(ev.buf, { immediate = true })
      end
    end,
  })

  vim.api.nvim_create_autocmd('TextChanged', {
    group = augroup,
    callback = function(ev)
      if lsp_enabled() then
        lsp_context.refresh_symbols(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'DiagnosticChanged' }, {
    group = augroup,
    callback = function(ev)
      if lsp_enabled() then
        lsp_context.refresh_diagnostics(ev.buf)
      end
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
      stop_buffer_session(ev.buf, { clear_cache = true })
      if lsp_enabled() then
        lsp_context.clear(ev.buf)
      end
      neighbors_context.clear(ev.buf)
      treesitter_context.clear(ev.buf)
    end,
  })

  util.log('debug', 'Trigger system started')
end

function M.stop()
  if augroup then
    vim.api.nvim_del_augroup_by_id(augroup)
    augroup = nil
  end
  for bufnr, session in pairs(sessions) do
    clear_pending_completion(session)
    close_session_timer(session)
    if vim.api.nvim_buf_is_valid(bufnr) then
      cache.clear_quick_for_buffer(bufnr)
    end
  end
  sessions = {}
  lsp_context.stop()
  request.cancel()
  ghost.clear_all()
  util.log('debug', 'Trigger system stopped')
end

return M
