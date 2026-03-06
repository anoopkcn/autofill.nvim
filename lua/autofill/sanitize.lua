local M = {}

local MAX_OVERLAP_CHARS = 512

local function trim_code_fence(text)
  text = tostring(text or ''):gsub('\r\n', '\n')

  if text:sub(1, 3) == '```' then
    local newline = text:find('\n', 1, true)
    if not newline then
      return ''
    end
    text = text:sub(newline + 1)
  end

  text = text:gsub('\n```%s*$', '')
  return text
end

local function overlap_suffix_prefix(left, right)
  if left == '' or right == '' then
    return 0
  end

  local left_len = #left
  local limit = math.min(left_len, #right, MAX_OVERLAP_CHARS)
  local first_byte = right:byte(1)
  for len = limit, 1, -1 do
    if first_byte == left:byte(left_len - len + 1) and left:sub(-len) == right:sub(1, len) then
      return len
    end
  end

  return 0
end

local function overlap_prefix_suffix(left, right)
  if left == '' or right == '' then
    return 0
  end

  local left_len = #left
  local right_len = #right
  local limit = math.min(left_len, right_len, MAX_OVERLAP_CHARS)
  local first_byte = left:byte(1)
  for len = limit, 1, -1 do
    if first_byte == right:byte(right_len - len + 1) and left:sub(1, len) == right:sub(-len) then
      return len
    end
  end

  return 0
end

function M.suggestion(ctx, text)
  ctx = ctx or {}
  text = trim_code_fence(text)
  if text == '' then
    return ''
  end

  local before_cursor = tostring(ctx.before_cursor or '')
  local after_cursor = tostring(ctx.after_cursor or '')

  if #before_cursor > MAX_OVERLAP_CHARS then
    before_cursor = before_cursor:sub(-MAX_OVERLAP_CHARS)
  end
  if #after_cursor > MAX_OVERLAP_CHARS then
    after_cursor = after_cursor:sub(1, MAX_OVERLAP_CHARS)
  end

  local prefix_overlap = overlap_suffix_prefix(before_cursor, text)
  if prefix_overlap > 0 then
    text = text:sub(prefix_overlap + 1)
  end

  if text == '' then
    return ''
  end

  local suffix_overlap = overlap_suffix_prefix(text, after_cursor)
  if suffix_overlap > 0 then
    text = text:sub(1, #text - suffix_overlap)
  end

  return text
end

return M
