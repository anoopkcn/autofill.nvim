local helpers = require('tests.helpers')

local function make_error(kind, status, message)
  return setmetatable({
    kind = kind,
    status = status,
    message = message,
  }, {
    __tostring = function(err)
      return err.message
    end,
  })
end

return function()
  helpers.reset_runtime()

  local http = require('autofill.transport.http')
  local request = require('autofill.transport.request')
  local original_http_request = http.request

  local pending = {}
  http.request = function(opts)
    local entry = {
      opts = opts,
      killed = 0,
    }
    pending[#pending + 1] = entry
    return {
      kill = function()
        entry.killed = entry.killed + 1
      end,
    }
  end

  local data_events = {}
  local completions = {}
  local errors = {}
  local statuses = {}

  local function make_callbacks(label)
    return {
      on_data = function(payload)
        data_events[#data_events + 1] = { label, payload }
      end,
      on_error = function(err)
        errors[#errors + 1] = { label, err.kind, err.status }
      end,
      on_status = function(status)
        statuses[#statuses + 1] = { label, status }
      end,
      on_complete = function(response)
        completions[#completions + 1] = { label, response.status }
      end,
    }
  end

  local first = make_callbacks('first')
  local token1 = request.send({
    session_key = 'buf:1',
    url = 'https://example.test/one',
    on_data = first.on_data,
    on_error = first.on_error,
    on_status = first.on_status,
  }, first.on_complete)
  assert(type(token1) == 'number', 'send() should return a request token')
  assert(request.is_active('buf:1'), 'request should be active after send()')

  local second = make_callbacks('second')
  local token2 = request.send({
    session_key = 'buf:1',
    url = 'https://example.test/two',
    on_data = second.on_data,
    on_error = second.on_error,
    on_status = second.on_status,
  }, second.on_complete)
  assert(type(token2) == 'number' and token2 > token1, 'newer requests should get newer tokens')
  assert(pending[1].killed == 1, 'starting a new request for the same session should cancel the old request')

  pending[1].opts.on_data('stale-data')
  pending[1].opts.on_done({ status = 200, body = 'stale' })
  pending[1].opts.on_error(make_error('http', 500, 'stale error'))
  assert(#data_events == 0 and #completions == 0 and #errors == 0 and #statuses == 0, 'stale callbacks should be ignored')

  pending[2].opts.on_data('fresh-data')
  pending[2].opts.on_done({ status = 204, body = 'fresh' })
  assert(#data_events == 1 and data_events[1][1] == 'second', 'current request data should be forwarded')
  assert(#completions == 1 and completions[1][1] == 'second' and completions[1][2] == 204, 'current request completion should be forwarded')
  assert(#statuses == 1 and statuses[1][1] == 'second' and statuses[1][2] == 204, 'current request status should be forwarded')
  assert(not request.is_active('buf:1'), 'request should be inactive after completion')

  local third = make_callbacks('third')
  request.send({
    session_key = 'buf:2',
    url = 'https://example.test/three',
    on_data = third.on_data,
    on_error = third.on_error,
    on_status = third.on_status,
  }, third.on_complete)
  assert(request.is_active('buf:2'), 'second session should be active before cancel()')

  request.cancel('buf:2')
  assert(pending[3].killed == 1, 'cancel(session_key) should kill the active request')
  assert(not request.is_active('buf:2'), 'cancel(session_key) should clear session activity')

  pending[3].opts.on_done({ status = 200, body = 'ignored' })
  pending[3].opts.on_error(make_error('http', 429, 'ignored'))
  assert(#completions == 1 and #errors == 0, 'callbacks after cancel(session_key) should be ignored')

  local fourth = make_callbacks('fourth')
  local fifth = make_callbacks('fifth')
  request.send({
    session_key = 'buf:3',
    url = 'https://example.test/four',
    on_data = fourth.on_data,
    on_error = fourth.on_error,
    on_status = fourth.on_status,
  }, fourth.on_complete)
  request.send({
    session_key = 'buf:4',
    url = 'https://example.test/five',
    on_data = fifth.on_data,
    on_error = fifth.on_error,
    on_status = fifth.on_status,
  }, fifth.on_complete)
  assert(request.is_active(), 'global is_active() should report true while any request is active')

  request.cancel()
  assert(pending[4].killed == 1 and pending[5].killed == 1, 'cancel() should kill all active requests')
  assert(not request.is_active(), 'cancel() should clear global activity')

  http.request = original_http_request
  helpers.reset_runtime()
end
