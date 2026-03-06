local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local backend = require('autofill.backend')
  local config = require('autofill.config')
  local blablador = require('autofill.backend.blablador')
  local openai = require('autofill.backend.openai')
  local prompt = require('autofill.backend.prompt')
  local request = require('autofill.transport.request')
  local util = require('autofill.util')

  local supported = backend.supported_backends()
  assert(vim.tbl_contains(supported, 'blablador'), 'supported backends should include blablador')
  assert(vim.tbl_contains(supported, 'openai'), 'supported backends should include openai')

  local inspected = config.inspect(vim.deepcopy(config.defaults))
  assert(#inspected.errors == 0, 'default config should remain valid after registering supported backends')

  local original_request_send = request.send
  local original_get_api_key = util.get_api_key

  util.get_api_key = function(env_var)
    if env_var == 'OPENAI_API_KEY' then
      return 'sk-openai'
    end
    if env_var == 'BLABLADOR_API_KEY' then
      return 'sk-blablador'
    end
    error('unexpected API key env var: ' .. tostring(env_var))
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
    assert(opts.headers['authorization'] == 'Bearer sk-openai', 'OpenAI backend should send a bearer token')
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

  config.setup({
    backend = 'blablador',
    streaming_display = true,
    max_tokens = 77,
    blablador = {
      api_key_env = 'BLABLADOR_API_KEY',
      model = 'alias-code',
      base_url = 'https://example.blablador.test/v1/',
      timeout_ms = 2468,
    },
  })

  local blablador_partials = {}
  local blablador_streamed = nil
  request.send = function(opts, callback)
    assert(opts.url == 'https://example.blablador.test/v1/chat/completions', 'Blablador backend should normalize the configured base URL')
    assert(opts.headers['authorization'] == 'Bearer sk-blablador', 'Blablador backend should send a bearer token')
    assert(opts.body.model == 'alias-code', 'Blablador backend should use the configured model alias')
    assert(opts.body.messages[1].role == 'system', 'Blablador backend should send the system message first')
    assert(opts.body.messages[1].content == prompt.SYSTEM_PROMPT, 'Blablador backend should use the shared system prompt')
    assert(opts.body.messages[2].role == 'user', 'Blablador backend should send the user message second')
    assert(opts.body.messages[2].content == prompt.build_user_message(ctx), 'Blablador backend should send the built user prompt')
    assert(opts.body.max_tokens == 77, 'Blablador backend should respect max_tokens')
    assert(opts.body.stream == true, 'Blablador backend should stream when streaming_display is enabled')
    assert(opts.timeout_ms == 2468, 'Blablador backend should pass the configured timeout')
    assert(opts.session_key == 'blablador-stream-session', 'Blablador backend should forward the session key')

    opts.on_data(vim.json.encode({
      choices = {
        {
          delta = {
            content = 'ret',
          },
        },
      },
    }))
    opts.on_data(vim.json.encode({
      choices = {
        {
          delta = {
            content = {
              { type = 'text', text = 'urn 7' },
            },
          },
        },
      },
    }))

    callback({
      body = vim.json.encode({ choices = {} }),
    })
  end

  blablador.complete(ctx, {
    request_session_key = 'blablador-stream-session',
    on_partial = function(text)
      blablador_partials[#blablador_partials + 1] = text
    end,
    on_complete = function(text)
      blablador_streamed = text
    end,
    on_error = function(err)
      error('unexpected Blablador streaming error: ' .. tostring(err))
    end,
  })

  assert(#blablador_partials == 2, 'Blablador streaming should forward partial deltas')
  assert(blablador_partials[1] == 'ret', 'Blablador streaming should emit the first delta as partial text')
  assert(blablador_partials[2] == 'return 7', 'Blablador streaming should accumulate partial text')
  assert(blablador_streamed == 'return 7', 'Blablador streaming should return the aggregated completion')

  config.setup({
    backend = 'blablador',
    streaming_display = false,
    max_tokens = 55,
    blablador = {
      api_key_env = 'BLABLADOR_API_KEY',
      model = 'alias-code',
      base_url = 'https://example.blablador.test/v1',
      timeout_ms = 8642,
    },
  })

  local blablador_non_streamed = nil
  request.send = function(opts, callback)
    assert(opts.body.stream == false, 'Blablador backend should disable streaming when configured')
    callback({
      body = vim.json.encode({
        choices = {
          {
            message = {
              content = {
                { type = 'text', text = 'foo' },
                { type = 'text', text = 'bar' },
              },
            },
          },
        },
      }),
    })
  end

  blablador.complete(ctx, {
    on_complete = function(text)
      blablador_non_streamed = text
    end,
    on_error = function(err)
      error('unexpected Blablador non-streaming error: ' .. tostring(err))
    end,
  })

  assert(blablador_non_streamed == 'foobar', 'Blablador non-streaming should concatenate text content parts')

  request.send = original_request_send
  util.get_api_key = original_get_api_key
  helpers.reset_runtime()
end
