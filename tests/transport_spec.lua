local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local http = require('autofill.transport.http')
  local request = require('autofill.transport.request')

  local original_system = vim.system
  vim.system = function(_, opts, callback)
    assert(opts.stdout, 'expected streaming stdout callback')
    opts.stdout(nil, 'event: delta\r\ndata: first line\r\n')
    opts.stdout(nil, 'data: second line\r\n\r\n')
    opts.stdout(nil, ': keepalive\r\n')
    opts.stdout(nil, 'data: [DONE]\r\n\r\n__AUTOFILL_HTTP_STATUS__:200\n')
    callback({ code = 0, stdout = '', stderr = '' })
    return {
      kill = function() end,
    }
  end

  local payloads = {}
  local response = nil
  http.request({
    url = 'https://example.test',
    stream = true,
    on_data = function(payload)
      payloads[#payloads + 1] = payload
    end,
    on_done = function(resp)
      response = resp
    end,
    on_error = function(err)
      error('unexpected SSE parser error: ' .. tostring(err))
    end,
  })

  helpers.wait(100, function()
    return response ~= nil and #payloads == 1
  end, 'SSE parser did not produce the expected event stream')

  assert(payloads[1] == 'first line\nsecond line', 'SSE parser should join multiline data payloads')
  assert(response.status == 200, 'SSE parser should preserve HTTP status')

  vim.system = original_system

  local original_http_request = http.request
  http.request = function(opts)
    opts.on_error(setmetatable({
      kind = 'http',
      status = 429,
      body = '{}',
      message = 'HTTP 429: rate limit',
    }, {
      __tostring = function(err)
        return err.message
      end,
    }))

    return {
      kill = function() end,
    }
  end

  local forwarded_error = nil
  local forwarded_status = nil
  request.send({
    url = 'https://example.test',
    on_status = function(status)
      forwarded_status = status
    end,
    on_error = function(err)
      forwarded_error = err
    end,
  }, function()
    error('request callback should not run for transport errors')
  end)

  assert(forwarded_error and forwarded_error.status == 429, 'request layer should forward structured transport errors')
  assert(forwarded_status == 429, 'request layer should forward HTTP status codes')

  http.request = original_http_request
  helpers.reset_runtime()
end
