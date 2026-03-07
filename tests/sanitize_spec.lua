local helpers = require('tests.helpers')

return function()
  helpers.reset_runtime()

  local backend = require('autofill.backend')
  local config = require('autofill.config')
  local sanitize = require('autofill.sanitize')

  local ctx = {
    filename = '/tmp/example.lua',
    filetype = 'lua',
    before_cursor = 'local value = ',
    after_cursor = ')',
  }

  assert(
    sanitize.suggestion(ctx, '```lua\nlocal value = 42)\n```') == '42',
    'sanitize.suggestion() should strip code fences and overlapping before/after text'
  )
  assert(
    sanitize.suggestion(ctx, '```lua') == '',
    'sanitize.suggestion() should suppress incomplete opening code fences'
  )
  assert(
    sanitize.suggestion(ctx, 'local value = )') == '',
    'sanitize.suggestion() should drop suggestions that are entirely overlap'
  )

  local original_resolve = backend.resolve
  config.setup({
    backend = 'openai',
  })

  backend.resolve = function(name)
    assert(name == 'openai', 'backend.complete() should resolve the configured backend')
    return {
      complete = function(_, opts)
        opts.on_partial('```lua\nlocal value = 41')
        opts.on_complete('```lua\nlocal value = 41)\n```')
      end,
    }
  end

  local partials = {}
  local final = nil
  backend.complete(ctx, {
    on_partial = function(text)
      partials[#partials + 1] = text
    end,
    on_complete = function(text)
      final = text
    end,
  })

  assert(#partials == 1 and partials[1] == '```lua\nlocal value = 41', 'backend.complete() should pass through non-empty partial output without sanitizing')
  assert(final == '41', 'backend.complete() should sanitize completed output before forwarding it')

  final = false
  backend.resolve = function()
    return {
      complete = function(_, opts)
        opts.on_complete('local value = )')
      end,
    }
  end

  backend.complete(ctx, {
    on_complete = function(text)
      final = text
    end,
  })

  assert(final == nil, 'backend.complete() should collapse fully overlapping output to nil')

  backend.resolve = original_resolve
  helpers.reset_runtime()
end
