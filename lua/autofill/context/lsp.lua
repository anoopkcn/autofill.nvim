local M = {}

-- Symbol cache keyed by bufnr
local symbol_cache = {}
local diagnostic_cache = {}
local symbol_revision = {}
local diagnostic_revision = {}
local symbol_refresh_timers = {}
local symbol_request_generation = {}

local SYMBOL_REFRESH_DEBOUNCE_MS = 200

local symbol_kind_names = {
  [1] = 'File', [2] = 'Module', [3] = 'Namespace', [4] = 'Package',
  [5] = 'Class', [6] = 'Method', [7] = 'Property', [8] = 'Field',
  [9] = 'Constructor', [10] = 'Enum', [11] = 'Interface', [12] = 'Function',
  [13] = 'Variable', [14] = 'Constant', [15] = 'String', [16] = 'Number',
  [17] = 'Boolean', [18] = 'Array', [19] = 'Object', [20] = 'Key',
  [21] = 'Null', [22] = 'EnumMember', [23] = 'Struct', [24] = 'Event',
  [25] = 'Operator', [26] = 'TypeParameter',
}

local function flatten_symbols(symbols, container, result)
  result = result or {}
  for _, sym in ipairs(symbols) do
    local kind_name = symbol_kind_names[sym.kind] or 'Unknown'
    local line = sym.range and (sym.range.start.line + 1) or
                 sym.location and (sym.location.range.start.line + 1) or 0
    table.insert(result, {
      name = sym.name,
      kind = kind_name,
      line = line,
      container = container or '',
    })
    if sym.children then
      flatten_symbols(sym.children, sym.name, result)
    end
  end
  return result
end

local function bump_revision(revisions, bufnr)
  revisions[bufnr] = (revisions[bufnr] or 0) + 1
end

local function bump_symbol_request_generation(bufnr)
  symbol_request_generation[bufnr] = (symbol_request_generation[bufnr] or 0) + 1
  return symbol_request_generation[bufnr]
end

local function close_symbol_timer(bufnr)
  local timer = symbol_refresh_timers[bufnr]
  if not timer then return end

  timer:stop()
  timer:close()
  symbol_refresh_timers[bufnr] = nil
end

local function ensure_symbol_timer(bufnr)
  local timer = symbol_refresh_timers[bufnr]
  if timer then
    return timer
  end

  timer = vim.uv.new_timer()
  if not timer then
    return nil
  end

  symbol_refresh_timers[bufnr] = timer
  return timer
end

local function flatten_symbol_results(results)
  local merged = {}
  local seen = {}

  for _, response in pairs(results or {}) do
    local result = response and response.result
    if result then
      for _, symbol in ipairs(flatten_symbols(result)) do
        local key = table.concat({
          symbol.name or '',
          symbol.kind or '',
          tostring(symbol.line or 0),
          symbol.container or '',
        }, '\0')
        if not seen[key] then
          seen[key] = true
          merged[#merged + 1] = symbol
        end
      end
    end
  end

  return merged
end

local function request_symbols(bufnr)
  if not bufnr or bufnr == 0 then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    close_symbol_timer(bufnr)
    return
  end

  local request_generation = bump_symbol_request_generation(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
  if #clients == 0 then
    symbol_cache[bufnr] = nil
    bump_revision(symbol_revision, bufnr)
    return
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  vim.lsp.buf_request_all(bufnr, 'textDocument/documentSymbol', params, function(results)
    if request_generation ~= symbol_request_generation[bufnr] then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local flattened = flatten_symbol_results(results)
    symbol_cache[bufnr] = #flattened > 0 and flattened or nil
    bump_revision(symbol_revision, bufnr)
  end)
end

function M.refresh_symbols(bufnr, opts)
  opts = opts or {}
  if not bufnr or bufnr == 0 then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    close_symbol_timer(bufnr)
    return
  end

  local timer = ensure_symbol_timer(bufnr)
  if not timer then
    request_symbols(bufnr)
    return
  end

  timer:stop()
  local delay = opts.immediate and 0 or (opts.delay_ms or SYMBOL_REFRESH_DEBOUNCE_MS)
  timer:start(delay, 0, vim.schedule_wrap(function()
    request_symbols(bufnr)
  end))
end

function M.get_symbols(bufnr)
  return symbol_cache[bufnr]
end

function M.refresh_diagnostics(bufnr)
  if not bufnr or bufnr == 0 then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local diagnostics = vim.diagnostic.get(bufnr)
  local normalized = {}
  for _, d in ipairs(diagnostics) do
    normalized[#normalized + 1] = {
      line = d.lnum + 1,
      lnum = d.lnum,
      message = d.message,
      severity = d.severity,
    }
  end

  diagnostic_cache[bufnr] = normalized
  diagnostic_revision[bufnr] = (diagnostic_revision[bufnr] or 0) + 1
end

function M.get_context(bufnr, cursor)
  local row = cursor[1] - 1
  local diagnostics = diagnostic_cache[bufnr]
  if diagnostics == nil then
    M.refresh_diagnostics(bufnr)
    diagnostics = diagnostic_cache[bufnr]
  end
  if not diagnostics or #diagnostics == 0 then
    return nil
  end

  -- Filter to +-10 lines of cursor, sort by proximity
  local nearby = {}
  for _, d in ipairs(diagnostics) do
    local dist = math.abs(d.lnum - row)
    if dist <= 10 then
      table.insert(nearby, {
        line = d.line,
        message = d.message,
        severity = d.severity,
        distance = dist,
      })
    end
  end

  table.sort(nearby, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.line < b.line
  end)

  -- Keep top 5
  local top_diags = {}
  for i = 1, math.min(5, #nearby) do
    top_diags[i] = nearby[i]
  end

  if #top_diags == 0 then
    return nil
  end

  return {
    diagnostics = top_diags,
  }
end

function M.clear(bufnr)
  close_symbol_timer(bufnr)
  symbol_cache[bufnr] = nil
  diagnostic_cache[bufnr] = nil
  bump_symbol_request_generation(bufnr)
  bump_revision(symbol_revision, bufnr)
  bump_revision(diagnostic_revision, bufnr)
end

function M.stop()
  for bufnr in pairs(symbol_refresh_timers) do
    close_symbol_timer(bufnr)
  end
  for bufnr in pairs(symbol_request_generation) do
    bump_symbol_request_generation(bufnr)
  end
end

function M.get_revision(bufnr)
  return table.concat({
    'sym=',
    tostring(symbol_revision[bufnr] or 0),
    ':diag=',
    tostring(diagnostic_revision[bufnr] or 0),
  })
end

return M
