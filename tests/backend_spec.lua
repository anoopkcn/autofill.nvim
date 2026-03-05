local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local backend = require('autofill.backend')
  local config = require('autofill.config')
  local openai = require('autofill.backend.openai')
  local prompt = require('autofill.backend.prompt')
  local request = require('autofill.transport.request')
  local util = require('autofill.util')

  local supported = backend.supported_backends()
  assert(vim.tbl_contains(supported, 'openai'), 'supported backends should include openai')

  local inspected = config.inspect(vim.deepcopy(config.defaults))
  assert(#inspected.errors == 0, 'default config should remain valid after registering openai')

  local original_request_send = request.send
  local original_get_api_key = util.get_api_key

  util.get_api_key = function(env_var)
    assert(env_var == 'OPENAI_API_KEY', 'OpenAI backend should use the configured API key env var')
    return 'sk-test'
  end

  local ctx = {
    filename = '/tmp/example.lua',
    filetype = 'lua',
    before_cursor = 'local value = ',
    after_cursor = '',
  }

  config.setup({
    backend = 'openai',
    streaming_display = true,
    max_tokens = 99,
    openai = {
      api_key_env = 'OPENAI_API_KEY',
      model = 'gpt-5-mini',
      timeout_ms = 4321,
    },
  })

  local partials = {}
  local streamed = nil
  request.send = function(opts, callback)
    assert(opts.url == 'https://api.openai.com/v1/responses', 'OpenAI backend should target the Responses API')
    assert(opts.headers['authorization'] == 'Bearer sk-test', 'OpenAI backend should send a bearer token')
    assert(opts.body.model == 'gpt-5-mini', 'OpenAI backend should use the configured model')
    assert(opts.body.instructions == prompt.SYSTEM_PROMPT, 'OpenAI backend should pass the system prompt via instructions')
    assert(opts.body.input == prompt.build_user_message(ctx), 'OpenAI backend should send the built user prompt as input')
    assert(opts.body.max_output_tokens == 99, 'OpenAI backend should respect max_tokens')
    assert(opts.body.stream == true, 'OpenAI backend should stream when streaming_display is enabled')
    assert(opts.body.text.format.type == 'text', 'OpenAI backend should request plain text output')
    assert(opts.timeout_ms == 4321, 'OpenAI backend should pass the configured timeout')
    assert(opts.session_key == 'stream-session', 'OpenAI backend should forward the session key')

    opts.on_data(vim.json.encode({
      type = 'response.output_text.delta',
      delta = 'ret',
    }))
    opts.on_data(vim.json.encode({
      type = 'response.output_text.delta',
      delta = 'urn 42',
    }))

    callback({
      body = vim.json.encode({ output = {} }),
    })
  end

  openai.complete(ctx, {
    request_session_key = 'stream-session',
    on_partial = function(text)
      partials[#partials + 1] = text
    end,
    on_complete = function(text)
      streamed = text
    end,
    on_error = function(err)
      error('unexpected OpenAI streaming error: ' .. tostring(err))
    end,
  })

  assert(#partials == 2, 'OpenAI streaming should forward partial deltas')
  assert(partials[1] == 'ret', 'OpenAI streaming should emit the first delta as partial text')
  assert(partials[2] == 'return 42', 'OpenAI streaming should accumulate partial text')
  assert(streamed == 'return 42', 'OpenAI streaming should return the aggregated completion')

  config.setup({
    backend = 'openai',
    streaming_display = false,
    max_tokens = 64,
    openai = {
      api_key_env = 'OPENAI_API_KEY',
      model = 'gpt-5-mini',
      timeout_ms = 1111,
    },
  })

  local non_streamed = nil
  request.send = function(opts, callback)
    assert(opts.body.stream == false, 'OpenAI backend should disable streaming when configured')
    callback({
      body = vim.json.encode({
        output = {
          {
            type = 'reasoning',
            content = {
              { type = 'summary_text', text = 'thinking' },
            },
          },
          {
            type = 'message',
            content = {
              { type = 'output_text', text = 'foo' },
              { type = 'refusal', refusal = 'ignored' },
              { type = 'output_text', text = 'bar' },
            },
          },
        },
      }),
    })
  end

  openai.complete(ctx, {
    on_complete = function(text)
      non_streamed = text
    end,
    on_error = function(err)
      error('unexpected OpenAI non-streaming error: ' .. tostring(err))
    end,
  })

  assert(non_streamed == 'foobar', 'OpenAI non-streaming should concatenate output_text content parts')

  request.send = original_request_send
  util.get_api_key = original_get_api_key
  helpers.reset_runtime()
end
