local util = require('autofill.util')

local M = {}

local scope_patterns = { 'function', 'method', 'class', 'module', 'struct', 'impl', 'interface' }

local function is_scope_node(node_type)
  for _, pattern in ipairs(scope_patterns) do
    if node_type:find(pattern) then
      return true
    end
  end
  return false
end

local function get_node_header(node, source, max_chars)
  max_chars = max_chars or 500
  local sr, sc, er, ec = node:range()
  local lines = vim.api.nvim_buf_get_lines(source, sr, er + 1, false)
  if #lines == 0 then return nil end
  -- Take just the first line (the signature/declaration)
  local header = lines[1]
  if #header > max_chars then
    header = header:sub(1, max_chars) .. '...'
  end
  return header, sr + 1
end

function M.get_context(bufnr, cursor)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    util.log('debug', 'Treesitter parser not available')
    return nil
  end

  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then
    return nil
  end

  local root = trees[1]:root()
  local row, col = cursor[1] - 1, cursor[2]

  local node = root:named_descendant_for_range(row, col, row, col)
  if not node then return nil end

  local scopes = {}
  local current = node
  while current do
    local ntype = current:type()
    if is_scope_node(ntype) then
      local header, line = get_node_header(current, bufnr)
      if header then
        table.insert(scopes, 1, {
          type = ntype,
          header = header,
          line = line,
        })
      end
    end
    current = current:parent()
  end

  local node_type = node:type()

  -- Check captures at cursor for semantic context
  local in_comment = false
  local in_string = false
  local ok3, captures = pcall(vim.treesitter.get_captures_at_pos, bufnr, row, col)
  if ok3 and captures then
    for _, cap in ipairs(captures) do
      if cap.capture == 'comment' then in_comment = true end
      if cap.capture == 'string' then in_string = true end
    end
  end

  return {
    scopes = scopes,
    node_type = node_type,
    in_comment = in_comment,
    in_string = in_string,
  }
end

return M
