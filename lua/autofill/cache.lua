local M = {}

local cache = {}
local order = {}
local max_entries = 50
local ttl_ms = 30000

local function hash(str)
  -- Simple djb2 hash
  local h = 5381
  for i = 1, #str do
    h = ((h * 33) + str:byte(i)) % 2147483647
  end
  return tostring(h)
end

function M.key(ctx)
  -- Hash the content around cursor
  local raw = (ctx.filetype or '') .. ':' .. (ctx.before_cursor or ''):sub(-200) .. ':' .. (ctx.after_cursor or ''):sub(1, 100)
  return hash(raw)
end

function M.get(key)
  local entry = cache[key]
  if not entry then return nil end

  local now = vim.uv.now()
  if now - entry.time > ttl_ms then
    cache[key] = nil
    return nil
  end

  return entry.value
end

function M.set(key, value)
  local now = vim.uv.now()
  cache[key] = { value = value, time = now }
  -- Track insertion order for eviction
  table.insert(order, key)

  -- Evict oldest if over limit
  while #order > max_entries do
    local oldest = table.remove(order, 1)
    cache[oldest] = nil
  end
end

function M.clear()
  cache = {}
  order = {}
end

return M
