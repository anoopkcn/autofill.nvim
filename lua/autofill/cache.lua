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
  local parts = {
    ctx.filetype or '',
    ':',
    (ctx.before_cursor or ''):sub(-200),
    ':',
    (ctx.after_cursor or ''):sub(1, 100),
  }

  -- Include treesitter scope chain signature
  if ctx.treesitter and ctx.treesitter.scopes then
    for _, scope in ipairs(ctx.treesitter.scopes) do
      parts[#parts + 1] = ':ts:'
      parts[#parts + 1] = scope.type
      parts[#parts + 1] = ':'
      parts[#parts + 1] = tostring(scope.line)
    end
  end

  -- Include diagnostic signature
  if ctx.lsp and ctx.lsp.diagnostics then
    parts[#parts + 1] = ':diag:'
    parts[#parts + 1] = tostring(#ctx.lsp.diagnostics)
    if ctx.lsp.diagnostics[1] then
      parts[#parts + 1] = ':'
      parts[#parts + 1] = ctx.lsp.diagnostics[1].message:sub(1, 50)
    end
  end

  -- Include neighbor filenames
  if ctx.neighbors then
    for _, nb in ipairs(ctx.neighbors) do
      parts[#parts + 1] = ':nb:'
      parts[#parts + 1] = nb.filename or ''
    end
  end

  return hash(table.concat(parts))
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

  -- Remove existing key to avoid duplicates in order list
  for i = #order, 1, -1 do
    if order[i] == key then
      table.remove(order, i)
      break
    end
  end
  table.insert(order, key)

  -- Evict oldest if over limit
  while #order > max_entries do
    local oldest = table.remove(order, 1)
    if cache[oldest] then
      cache[oldest] = nil
    end
  end
end

function M.clear()
  cache = {}
  order = {}
end

return M
