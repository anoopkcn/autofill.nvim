local http = require('autofill.transport.http')
local util = require('autofill.util')

local M = {}

local DEFAULT_SESSION_KEY = '__global__'
local sessions = {}
local next_request_token = 0

local function normalize_session_key(session_key)
  if session_key == nil then
    return DEFAULT_SESSION_KEY
  end
  return session_key
end

local function ensure_session(session_key)
  session_key = normalize_session_key(session_key)
  local session = sessions[session_key]
  if not session then
    session = {
      request_token = 0,
      active_obj = nil,
    }
    sessions[session_key] = session
  end
  return session, session_key
end

local function release_session(session_key)
  sessions[session_key] = nil
end

function M.send(opts, callback)
  local session_key = opts.session_key
  M.cancel(session_key)

  local session
  session, session_key = ensure_session(session_key)

  next_request_token = next_request_token + 1
  local my_token = next_request_token
  session.request_token = my_token

  local function is_stale()
    local current = sessions[session_key]
    return not current or current.request_token ~= my_token
  end

  session.active_obj = http.request({
    url = opts.url,
    headers = opts.headers,
    body = opts.body,
    timeout_ms = opts.timeout_ms,
    stream = opts.stream,
    on_data = function(...)
      if is_stale() then return end
      if opts.on_data then
        opts.on_data(...)
      end
    end,
    on_done = function(stdout)
      if is_stale() then return end
      session.active_obj = nil
      release_session(session_key)
      if opts.on_status and stdout and stdout.status then
        opts.on_status(stdout.status, stdout)
      end
      if callback then callback(stdout) end
    end,
    on_error = function(err)
      if is_stale() then return end
      session.active_obj = nil
      release_session(session_key)
      if opts.on_status and err and err.status then
        opts.on_status(err.status, err)
      end
      if opts.on_error then
        opts.on_error(err)
      else
        util.log('warn', 'Completion failed: ' .. tostring(err))
      end
    end,
  })

  return my_id
end

function M.cancel(session_key)
  if session_key == nil then
    local keys = vim.tbl_keys(sessions)
    for _, key in ipairs(keys) do
      M.cancel(key)
    end
    return
  end

  session_key = normalize_session_key(session_key)
  local session = sessions[session_key]
  if not session then
    return
  end

  next_request_token = next_request_token + 1
  session.request_token = next_request_token
  if session.active_obj then
    local obj = session.active_obj
    session.active_obj = nil
    pcall(function() obj:kill(9) end)
    util.log('debug', 'Cancelled in-flight request')
  end
  release_session(session_key)
end

function M.is_active(session_key)
  if session_key == nil then
    for _, session in pairs(sessions) do
      if session.active_obj ~= nil then
        return true
      end
    end
    return false
  end

  session_key = normalize_session_key(session_key)
  local session = sessions[session_key]
  return session ~= nil and session.active_obj ~= nil
end

return M
