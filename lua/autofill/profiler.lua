local util = require('autofill.util')

local M = {}

local MARK_ORDER = {
  'input',
  'timer_fire',
  'quick_cache_hit',
  'context_ready',
  'request_sent',
  'first_partial',
  'final_render',
}

local function is_enabled()
  return require('autofill.config').get().profiling
end

function M.start(label)
  if not is_enabled() then return nil end

  return {
    label = label or 'completion',
    started_at = vim.uv.now(),
    marks = {
      input = 0,
    },
  }
end

function M.mark(session, name)
  if not session or session.done or session.marks[name] ~= nil then
    return
  end

  session.marks[name] = vim.uv.now() - session.started_at
end

function M.summary(session)
  if not session then return nil end

  local parts = {}
  for _, name in ipairs(MARK_ORDER) do
    local value = session.marks[name]
    if value ~= nil then
      parts[#parts + 1] = name .. '=' .. value .. 'ms'
    end
  end

  return (session.label or 'completion') .. ' profile: ' .. table.concat(parts, ', ')
end

function M.finish(session)
  if not session then return nil end
  if session.done then
    return session.cached_summary
  end

  session.done = true
  session.cached_summary = M.summary(session)
  util.profile(session.cached_summary)
  return session.cached_summary
end

return M
