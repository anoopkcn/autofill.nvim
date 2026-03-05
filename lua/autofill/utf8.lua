local M = {}

--- After sub(-n), the first byte might be a UTF-8 continuation byte (0x80-0xBF).
--- Trim leading continuation bytes to avoid splitting a multi-byte character.
function M.safe_sub_right(s, n)
  if n >= #s then return s end
  local result = s:sub(-n)
  local i = 1
  while i <= #result do
    local b = result:byte(i)
    if b >= 0x80 and b <= 0xBF then
      i = i + 1
    else
      break
    end
  end
  if i > 1 then
    result = result:sub(i)
  end
  return result
end

--- After sub(1, n), the last bytes might be an incomplete multi-byte sequence.
--- Trim any trailing incomplete UTF-8 sequence.
function M.safe_sub_left(s, n)
  if n >= #s then return s end
  local result = s:sub(1, n)
  -- Walk backwards from end to find if we have an incomplete sequence
  local len = #result
  if len == 0 then return result end

  local last = result:byte(len)
  -- If last byte is ASCII (< 0x80), it's complete
  if last < 0x80 then return result end

  -- Walk back over continuation bytes (0x80-0xBF)
  local trim = 0
  local pos = len
  while pos > 0 do
    local b = result:byte(pos)
    if b >= 0x80 and b <= 0xBF then
      trim = trim + 1
      pos = pos - 1
    else
      -- Found a leading byte, check if the sequence is complete
      local expected
      if b >= 0xF0 then expected = 4
      elseif b >= 0xE0 then expected = 3
      elseif b >= 0xC0 then expected = 2
      else expected = 1 end

      local actual = trim + 1
      if actual < expected then
        -- Incomplete sequence: remove it
        result = result:sub(1, pos - 1)
      end
      break
    end
  end

  return result
end

return M
