local ghost = require('autofill.display.ghost')
local context = require('autofill.context')
local backend = require('autofill.backend')
local request = require('autofill.transport.request')
local cache = require('autofill.cache')
local util = require('autofill.util')

local M = {}

local timer = nil
local last_request_time = 0
local augroup = nil

local function show_suggestion(bufnr, suggestion, is_partial)
  if vim.fn.mode() ~= 'i' then return end
  if vim.api.nvim_get_current_buf() ~= bufnr then return end

  local new_cursor = vim.api.nvim_win_get_cursor(0)
  ghost.show(bufnr, new_cursor[1], new_cursor[2], suggestion, is_partial)
end

local function do_complete()
  local config = require('autofill.config').get()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)

  local ctx = context.gather(bufnr, cursor)
  local cache_key = cache.key(ctx)

  -- Check cache first
  local cached = cache.get(cache_key)
  if cached then
    show_suggestion(bufnr, cached)
    return
  end

  last_request_time = vim.uv.now()

  local opts = {
    on_complete = function(suggestion)
      cache.set(cache_key, suggestion)
      show_suggestion(bufnr, suggestion)
    end,
  }

  if config.streaming_display then
    opts.on_partial = function(text_so_far)
      vim.schedule(function()
        show_suggestion(bufnr, text_so_far, true)
      end)
    end
  end

  backend.complete(ctx, opts)
end

local function schedule_complete()
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
    if vim.fn.mode() == 'i' then
      do_complete()
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

  -- Try to advance existing ghost text
  if ghost.is_visible() and ghost.advance(bufnr) then
    return
  end

  -- Cancel any in-flight request
  request.cancel()

  -- Schedule a new completion
  schedule_complete()
end

local function on_insert_leave()
  if timer then
    timer:stop()
  end
  request.cancel()
  ghost.clear()
end

local function on_buf_leave()
  if timer then
    timer:stop()
  end
  request.cancel()
  ghost.clear()
end

function M.start()
  if augroup then return end

  local lsp_mod = require('autofill.context.lsp')

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
      lsp_mod.refresh_symbols(ev.buf)
    end,
  })

  -- Clean up symbol cache on buffer delete
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = augroup,
    callback = function(ev)
      lsp_mod.clear_symbols(ev.buf)
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
  request.cancel()
  ghost.clear()
  util.log('debug', 'Trigger system stopped')
end

return M
