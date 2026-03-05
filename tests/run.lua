local M = {}

local TESTS = {
  { name = 'util', module = 'tests.util_spec' },
  { name = 'keymaps', module = 'tests.keymaps_spec' },
  { name = 'cache', module = 'tests.cache_spec' },
  { name = 'backend', module = 'tests.backend_spec' },
  { name = 'request', module = 'tests.request_spec' },
  { name = 'context', module = 'tests.context_spec' },
  { name = 'trigger', module = 'tests.trigger_spec' },
  { name = 'transport', module = 'tests.transport_spec' },
}

local function run_test(test)
  package.loaded[test.module] = nil
  local ok, runner = pcall(require, test.module)
  if not ok then
    error('failed to load ' .. test.module .. ':\n' .. tostring(runner))
  end

  local ok_run, err = xpcall(runner, debug.traceback)
  if not ok_run then
    error(test.name .. ' failed:\n' .. err)
  end
end

function M.run()
  local passed = 0

  for _, test in ipairs(TESTS) do
    io.stdout:write('Running ' .. test.name .. '...\n')
    run_test(test)
    passed = passed + 1
  end

  io.stdout:write('Passed ' .. tostring(passed) .. ' tests.\n')
end

return M
