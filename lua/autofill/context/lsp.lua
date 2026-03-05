local util = require('autofill.util')

local M = {}

-- Symbol cache keyed by bufnr
local symbol_cache = {}

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

function M.refresh_symbols(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
  if #clients == 0 then return end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  vim.lsp.buf_request(bufnr, 'textDocument/documentSymbol', params, function(err, result)
    if err or not result then return end
    symbol_cache[bufnr] = flatten_symbols(result)
  end)
end

function M.get_symbols(bufnr)
  return symbol_cache[bufnr]
end

function M.clear_symbols(bufnr)
  symbol_cache[bufnr] = nil
end

function M.get_context(bufnr, cursor)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil
  end

  local row = cursor[1] - 1
  local diagnostics = vim.diagnostic.get(bufnr)

  -- Filter to +-10 lines of cursor, sort by proximity
  local nearby = {}
  for _, d in ipairs(diagnostics) do
    local dist = math.abs(d.lnum - row)
    if dist <= 10 then
      table.insert(nearby, {
        line = d.lnum + 1,
        message = d.message,
        severity = d.severity,
        distance = dist,
      })
    end
  end

  table.sort(nearby, function(a, b) return a.distance < b.distance end)

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

return M
