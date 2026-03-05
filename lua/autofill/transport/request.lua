local http = require('autofill.transport.http')
local util = require('autofill.util')

local M = {}

local active_obj = nil
local request_id = 0

function M.send(opts, callback)
  M.cancel()

  request_id = request_id + 1
  local my_id = request_id

  local function is_stale()
    return my_id ~= request_id
  end

  active_obj = http.request({
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
      active_obj = nil
      if opts.on_status and stdout and stdout.status then
        opts.on_status(stdout.status, stdout)
      end
      if callback then callback(stdout) end
    end,
    on_error = function(err)
      if is_stale() then return end
      active_obj = nil
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

function M.cancel()
  request_id = request_id + 1
  if active_obj then
    local obj = active_obj
    active_obj = nil
    pcall(function() obj:kill(9) end)
    util.log('debug', 'Cancelled in-flight request')
  end
end

function M.is_active()
  return active_obj ~= nil
end

return M
