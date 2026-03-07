local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local backend = require('autofill.backend')
  local claude = require('autofill.backend.claude')
  local config = require('autofill.config')
  local blablador = require('autofill.backend.blablador')
  local gemini = require('autofill.backend.gemini')
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
    if env_var == 'ANTHROPIC_API_KEY' then
      return 'sk-claude'
    end
    if env_var == 'GEMINI_API_KEY' then
      return 'sk-gemini'
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
  local prose_ctx = {
    filename = '/tmp/example.md',
    filetype = 'markdown',
    before_cursor = 'Draft: ',
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
    local request_data = prompt.build_request(ctx)
    assert(opts.url == 'https://api.openai.com/v1/responses', 'OpenAI backend should target the Responses API')
    assert(opts.headers['authorization'] == 'Bearer sk-openai', 'OpenAI backend should send a bearer token')
    assert(opts.body.model == 'gpt-5-mini', 'OpenAI backend should use the configured model')
    assert(opts.body.instructions == request_data.system_prompt, 'OpenAI backend should pass the resolved system prompt via instructions')
    assert(opts.body.input == request_data.user_message, 'OpenAI backend should send the built user prompt as input')
    assert(opts.body.max_output_tokens == 99, 'OpenAI backend should respect max_tokens')
    assert(opts.body.stream == true, 'OpenAI backend should stream when streaming_display is enabled')
    assert(opts.body.text.format.type == 'text', 'OpenAI backend should request plain text output')
    assert(opts.body.temperature == 0.1, 'OpenAI backend should send the resolved code temperature when configured')
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
    model = 'gpt-5',
    streaming_display = false,
    max_tokens = 64,
    openai = {
      api_key_env = 'OPENAI_API_KEY',
      model = 'gpt-5-mini',
      timeout_ms = 1111,
    },
  })

  local overridden_model_result = nil
  request.send = function(opts, callback)
    assert(opts.body.model == 'gpt-5', 'top-level model should override the active backend model')
    callback({
      body = vim.json.encode({
        output_text = 'baz',
      }),
    })
  end

  openai.complete(ctx, {
    on_complete = function(text)
      overridden_model_result = text
    end,
    on_error = function(err)
      error('unexpected OpenAI top-level model override error: ' .. tostring(err))
    end,
  })

  assert(overridden_model_result == 'baz', 'OpenAI should still complete successfully when top-level model override is used')

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
    backend = 'openai',
    streaming_display = false,
    max_tokens = 32,
    openai = {
      api_key_env = 'OPENAI_API_KEY',
      model = 'gpt-5-mini',
      timeout_ms = 1111,
    },
  })

  local openai_prose = nil
  request.send = function(opts, callback)
    local request_data = prompt.build_request(prose_ctx)
    assert(opts.body.instructions == request_data.system_prompt, 'OpenAI backend should resolve the prose system prompt')
    assert(opts.body.input == request_data.user_message, 'OpenAI backend should send the prose prompt body')
    assert(opts.body.temperature == nil, 'OpenAI backend should omit temperature for prose mode by default')
    callback({
      body = vim.json.encode({
        output_text = 'more text',
      }),
    })
  end

  openai.complete(prose_ctx, {
    on_complete = function(text)
      openai_prose = text
    end,
    on_error = function(err)
      error('unexpected OpenAI prose-mode error: ' .. tostring(err))
    end,
  })

  assert(openai_prose == 'more text', 'OpenAI should still complete successfully when prose mode omits temperature')

  config.setup({
    backend = 'claude',
    streaming_display = false,
    max_tokens = 40,
    claude = {
      api_key_env = 'ANTHROPIC_API_KEY',
      model = 'claude-haiku-4-5-20251001',
      timeout_ms = 2222,
    },
  })

  local claude_code = nil
  request.send = function(opts, callback)
    local request_data = prompt.build_request(ctx)
    assert(opts.url == 'https://api.anthropic.com/v1/messages', 'Claude backend should target the Messages API')
    assert(opts.headers['x-api-key'] == 'sk-claude', 'Claude backend should send the configured API key')
    assert(opts.body.model == 'claude-haiku-4-5-20251001', 'Claude backend should use the configured model')
    assert(opts.body.system == request_data.system_prompt, 'Claude backend should send the resolved system prompt')
    assert(opts.body.messages[1].content == request_data.user_message, 'Claude backend should send the built user prompt')
    assert(opts.body.temperature == 0.1, 'Claude backend should send the resolved code temperature when configured')
    callback({
      body = vim.json.encode({
        content = {
          { text = 'return 99' },
        },
      }),
    })
  end

  claude.complete(ctx, {
    on_complete = function(text)
      claude_code = text
    end,
    on_error = function(err)
      error('unexpected Claude code-mode error: ' .. tostring(err))
    end,
  })

  assert(claude_code == 'return 99', 'Claude should concatenate text blocks from non-streaming responses')

  local claude_prose = nil
  request.send = function(opts, callback)
    local request_data = prompt.build_request(prose_ctx)
    assert(opts.body.system == request_data.system_prompt, 'Claude backend should resolve the prose system prompt')
    assert(opts.body.messages[1].content == request_data.user_message, 'Claude backend should send the prose prompt body')
    assert(opts.body.temperature == nil, 'Claude backend should omit temperature for prose mode by default')
    callback({
      body = vim.json.encode({
        content = {
          { text = 'more prose' },
        },
      }),
    })
  end

  claude.complete(prose_ctx, {
    on_complete = function(text)
      claude_prose = text
    end,
    on_error = function(err)
      error('unexpected Claude prose-mode error: ' .. tostring(err))
    end,
  })

  assert(claude_prose == 'more prose', 'Claude should complete successfully when prose mode omits temperature')

  config.setup({
    backend = 'gemini',
    streaming_display = false,
    max_tokens = 41,
    gemini = {
      api_key_env = 'GEMINI_API_KEY',
      model = 'gemini-2.5-flash',
      timeout_ms = 3333,
    },
  })

  local gemini_code = nil
  request.send = function(opts, callback)
    local request_data = prompt.build_request(ctx)
    assert(opts.headers['x-goog-api-key'] == 'sk-gemini', 'Gemini backend should send the configured API key')
    assert(opts.body.systemInstruction.parts[1].text == request_data.system_prompt, 'Gemini backend should send the resolved system prompt')
    assert(opts.body.contents[1].parts[1].text == request_data.user_message, 'Gemini backend should send the built user prompt')
    assert(opts.body.generationConfig.maxOutputTokens == 41, 'Gemini backend should respect max_tokens')
    assert(opts.body.generationConfig.temperature == 0.1, 'Gemini backend should send the resolved code temperature when configured')
    callback({
      body = vim.json.encode({
        candidates = {
          {
            content = {
              parts = {
                { text = 'return 123' },
              },
            },
          },
        },
      }),
    })
  end

  gemini.complete(ctx, {
    on_complete = function(text)
      gemini_code = text
    end,
    on_error = function(err)
      error('unexpected Gemini code-mode error: ' .. tostring(err))
    end,
  })

  assert(gemini_code == 'return 123', 'Gemini should concatenate response parts in non-streaming mode')

  local gemini_prose = nil
  request.send = function(opts, callback)
    local request_data = prompt.build_request(prose_ctx)
    assert(opts.body.systemInstruction.parts[1].text == request_data.system_prompt, 'Gemini backend should resolve the prose system prompt')
    assert(opts.body.contents[1].parts[1].text == request_data.user_message, 'Gemini backend should send the prose prompt body')
    assert(opts.body.generationConfig.temperature == nil, 'Gemini backend should omit temperature for prose mode by default')
    callback({
      body = vim.json.encode({
        candidates = {
          {
            content = {
              parts = {
                { text = 'more prose' },
              },
            },
          },
        },
      }),
    })
  end

  gemini.complete(prose_ctx, {
    on_complete = function(text)
      gemini_prose = text
    end,
    on_error = function(err)
      error('unexpected Gemini prose-mode error: ' .. tostring(err))
    end,
  })

  assert(gemini_prose == 'more prose', 'Gemini should complete successfully when prose mode omits temperature')

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
    local request_data = prompt.build_request(ctx)
    assert(opts.url == 'https://example.blablador.test/v1/chat/completions', 'Blablador backend should normalize the configured base URL')
    assert(opts.headers['authorization'] == 'Bearer sk-blablador', 'Blablador backend should send a bearer token')
    assert(opts.body.model == 'alias-code', 'Blablador backend should use the configured model alias')
    assert(opts.body.messages[1].role == 'system', 'Blablador backend should send the system message first')
    assert(opts.body.messages[1].content == request_data.system_prompt, 'Blablador backend should use the resolved system prompt')
    assert(opts.body.messages[2].role == 'user', 'Blablador backend should send the user message second')
    assert(opts.body.messages[2].content == request_data.user_message, 'Blablador backend should send the built user prompt')
    assert(opts.body.max_tokens == 77, 'Blablador backend should respect max_tokens')
    assert(opts.body.stream == true, 'Blablador backend should stream when streaming_display is enabled')
    assert(opts.body.temperature == 0.1, 'Blablador backend should send the resolved code temperature when configured')
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

  local blablador_prose = nil
  request.send = function(opts, callback)
    local request_data = prompt.build_request(prose_ctx)
    assert(opts.body.messages[1].content == request_data.system_prompt, 'Blablador backend should resolve the prose system prompt')
    assert(opts.body.messages[2].content == request_data.user_message, 'Blablador backend should send the prose prompt body')
    assert(opts.body.temperature == nil, 'Blablador backend should omit temperature for prose mode by default')
    callback({
      body = vim.json.encode({
        choices = {
          {
            message = {
              content = 'more prose',
            },
          },
        },
      }),
    })
  end

  blablador.complete(prose_ctx, {
    on_complete = function(text)
      blablador_prose = text
    end,
    on_error = function(err)
      error('unexpected Blablador prose-mode error: ' .. tostring(err))
    end,
  })

  assert(blablador_prose == 'more prose', 'Blablador should complete successfully when prose mode omits temperature')

  request.send = original_request_send
  util.get_api_key = original_get_api_key
  helpers.reset_runtime()
end
