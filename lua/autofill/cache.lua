local prompt = require('autofill.backend.prompt')

local M = {}

local full_cache = {}
local full_order = {}
local quick_cache = {}
local quick_order = {}
local max_entries = 50
local ttl_ms = 30000
local cached_scope = nil
local cached_scope_config = nil

local function hash(str)
  if #str > 256 then
    return vim.fn.sha256(str)
  end
  -- Simple djb2 hash for short strings
  local h = 5381
  for i = 1, #str do
    h = ((h * 33) + str:byte(i)) % 2147483647
  end
  return tostring(h)
end

local function remove_from_order(order, key)
  for i = #order, 1, -1 do
    if order[i] == key then
      table.remove(order, i)
      return
    end
  end
end

local function get_entry(store, order, key)
  local entry = store[key]
  if not entry then return nil end

  local now = vim.uv.now()
  if now - entry.time > ttl_ms then
    store[key] = nil
    remove_from_order(order, key)
    return nil
  end

  return entry.value
end

local function set_entry(store, order, key, value, meta)
  local now = vim.uv.now()
  store[key] = { value = value, time = now, meta = meta }

  remove_from_order(order, key)
  table.insert(order, key)

  while #order > max_entries do
    local oldest = table.remove(order, 1)
    if store[oldest] then
      store[oldest] = nil
    end
  end
end

local function build_quick_key(opts)
  local parts = {
    opts.scope or '',
    ':',
    tostring(opts.bufnr or ''),
    ':',
    tostring(opts.row or ''),
    ':',
    opts.filetype or '',
    ':',
    opts.context_revision or '',
    ':',
    (opts.before_cursor or ''):sub(-200),
    ':',
    (opts.after_cursor or ''):sub(1, 100),
  }

  return hash(table.concat(parts))
end

function M.scope(config)
  if config == cached_scope_config then
    return cached_scope
  end

  local backend_name = config.backend or ''
  local backend_opts = config[backend_name] or {}
  local neighbors = config.neighbors or {}
  local prompt_config = config.prompt or {}

  local parts = {
    backend_name,
    ':',
    backend_opts.model or '',
    ':',
    backend_opts.base_url or '',
    ':',
    tostring(config.max_tokens or ''),
    ':',
    tostring(config.context_window or ''),
    ':',
    tostring(config.context_ratio or ''),
    ':',
    tostring(neighbors.enabled),
    ':',
    tostring(neighbors.budget or ''),
    ':',
    tostring(neighbors.max_files or ''),
    ':',
    tostring(neighbors.include_disk_files),
    ':',
    tostring(neighbors.disk_scan_limit or ''),
    ':',
    tostring(prompt_config.max_chars or ''),
    ':',
    tostring(prompt_config.max_neighbors_chars or ''),
    ':',
    tostring(prompt_config.max_neighbor_file_chars or ''),
    ':',
    tostring(prompt_config.max_outline_chars or ''),
    ':',
    tostring(prompt_config.max_scope_chars or ''),
    ':',
    tostring(prompt_config.max_diagnostics_chars or ''),
    ':',
    tostring(prompt_config.max_symbol_count or ''),
    ':',
    tostring(prompt_config.max_scope_count or ''),
    ':',
    tostring(prompt_config.max_diagnostic_count or ''),
  }

  local result = hash(table.concat(parts))
  cached_scope_config = config
  cached_scope = result
  return result
end

function M.key(ctx, scope)
  local message = prompt.build_user_message(ctx)
  return hash((scope or '') .. ':' .. prompt.SYSTEM_PROMPT .. '\0' .. message)
end

function M.quick_key(opts)
  return build_quick_key(opts)
end

function M.get(key)
  return get_entry(full_cache, full_order, key)
end

function M.get_quick(key)
  return get_entry(quick_cache, quick_order, key)
end

function M.set(key, value)
  set_entry(full_cache, full_order, key, value)
end

function M.set_quick(key, value, meta)
  set_entry(quick_cache, quick_order, key, value, meta)
end

function M.clear_quick_for_buffer(bufnr)
  for i = #quick_order, 1, -1 do
    local key = quick_order[i]
    local entry = quick_cache[key]
    if entry and entry.meta and entry.meta.bufnr == bufnr then
      quick_cache[key] = nil
      table.remove(quick_order, i)
    end
  end
end

function M.clear()
  full_cache = {}
  full_order = {}
  quick_cache = {}
  quick_order = {}
  cached_scope = nil
  cached_scope_config = nil
end

return M
