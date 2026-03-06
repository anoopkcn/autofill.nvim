local helpers = require('tests.helpers')

local function run_health_check(stubs)
  local original_health = vim.health
  local original_modules = {
    health = package.loaded['autofill.health'],
    config = package.loaded['autofill.config'],
    backend = package.loaded['autofill.backend'],
    ghost = package.loaded['autofill.display.ghost'],
  }
  local messages = {}

  vim.health = {
    start = function(message)
      messages[#messages + 1] = { level = 'start', message = message }
    end,
    ok = function(message)
      messages[#messages + 1] = { level = 'ok', message = message }
    end,
    warn = function(message)
      messages[#messages + 1] = { level = 'warn', message = message }
    end,
    error = function(message)
      messages[#messages + 1] = { level = 'error', message = message }
    end,
    info = function(message)
      messages[#messages + 1] = { level = 'info', message = message }
    end,
  }

  package.loaded['autofill.config'] = stubs.config
  package.loaded['autofill.backend'] = stubs.backend
  package.loaded['autofill.display.ghost'] = stubs.ghost
  package.loaded['autofill.health'] = nil

  local ok_run, err
  local health = require('autofill.health')
  ok_run, err = pcall(health.check)

  package.loaded['autofill.health'] = original_modules.health
  package.loaded['autofill.config'] = original_modules.config
  package.loaded['autofill.backend'] = original_modules.backend
  package.loaded['autofill.display.ghost'] = original_modules.ghost
  vim.health = original_health

  return ok_run, err, messages
end

local function find_message(messages, level, text)
  for _, entry in ipairs(messages) do
    if entry.level == level and entry.message == text then
      return true
    end
  end
  return false
end

return function()
  helpers.reset_runtime()

  local ok_run, err, messages = run_health_check({
    config = {
      get = function()
        return {
          backend = 'openai',
          openai = {
            model = 'gpt-5-mini',
          },
          claude = {
            model = 'claude-haiku-4-5-20251001',
          },
          prompt = {
            max_chars = 12000,
          },
          keymaps = {
            accept = '<Tab>',
          },
        }
      end,
      inspect = function()
        return {
          errors = {},
          warnings = {},
        }
      end,
    },
    backend = {
      inspect_runtime = function()
        return {
          errors = {},
          warnings = {},
        }
      end,
      supported_backends = function()
        return { 'claude', 'openai' }
      end,
    },
    ghost = {
      get_plug_mappings = function()
        return {}
      end,
    },
  })

  assert(ok_run, 'health check should succeed for a valid configuration: ' .. tostring(err))
  assert(find_message(messages, 'info', 'Configured backend: openai'), 'health check should report the configured backend')
  assert(find_message(messages, 'info', 'Configured model: gpt-5-mini'), 'health check should report the active backend model')
  assert(not find_message(messages, 'info', 'Configured model: claude-haiku-4-5-20251001'),
    'health check should not report the model from an inactive backend')

  ok_run, err, messages = run_health_check({
    config = {
      get = function()
        return {
          backend = 'openai',
          prompt = {},
          keymaps = {},
        }
      end,
      inspect = function()
        return {
          errors = { 'openai must be a table' },
          warnings = {},
        }
      end,
    },
    backend = {
      inspect_runtime = function()
        return {
          errors = {},
          warnings = {},
        }
      end,
      supported_backends = function()
        return { 'openai' }
      end,
    },
    ghost = {
      get_plug_mappings = function()
        return {}
      end,
    },
  })

  assert(ok_run, 'health check should not crash when the active backend config is malformed: ' .. tostring(err))
  assert(find_message(messages, 'error', 'Configuration is invalid:\n- openai must be a table'),
    'health check should continue reporting validation failures')
  assert(find_message(messages, 'info', 'Configured model: unavailable'),
    'health check should report an unavailable model when the backend config is malformed')

  helpers.reset_runtime()
end
