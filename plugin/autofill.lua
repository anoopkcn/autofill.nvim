if vim.g.loaded_autofill then
  return
end
vim.g.loaded_autofill = true

vim.api.nvim_create_user_command('Autofill', function(cmd)
  local arg = cmd.args:lower()
  if arg == 'enable' then
    require('autofill').enable()
  elseif arg == 'disable' then
    require('autofill').disable()
  elseif arg == 'toggle' then
    require('autofill').toggle()
  elseif arg == 'test' then
    local backend = require('autofill.backend')
    local config = require('autofill.config').get()
    local util = require('autofill.util')
    local runtime_report = backend.inspect_runtime(config)
    if #runtime_report.errors > 0 then
      vim.notify('[autofill] Test failed:\n- ' .. table.concat(runtime_report.errors, '\n- '), vim.log.levels.ERROR)
      return
    end

    local profiler = require('autofill.profiler')
    local profile = profiler.start('test')
    local ctx = require('autofill.context').gather(
      vim.api.nvim_get_current_buf(),
      vim.api.nvim_win_get_cursor(0)
    )
    profiler.mark(profile, 'context_ready')
    vim.notify('[autofill] Sending test request to ' .. config.backend .. '...')
    profiler.mark(profile, 'request_sent')
    backend.complete(ctx, {
      on_partial = function()
        profiler.mark(profile, 'first_partial')
      end,
      on_error = function(err)
        local summary = profiler.finish(profile)
        local msg = '[autofill] Test failed: ' .. tostring(err)
        if summary then
          msg = msg .. '\n\n' .. summary
        end
        vim.notify(msg, vim.log.levels.ERROR)
      end,
      on_complete = function(suggestion)
        if not suggestion then
          local summary = profiler.finish(profile)
          local msg = '[autofill] Backend returned nil'
          if summary then
            msg = msg .. '\n\n' .. summary
          end
          vim.notify(msg, vim.log.levels.WARN)
          return
        end

        profiler.mark(profile, 'final_render')
        local summary = profiler.finish(profile)
        local prefix = '[autofill] Got suggestion (' .. #suggestion .. ' chars)'
        local preview = util.preview_text(suggestion, {
          single_line = true,
        })
        local msg = prefix
        if preview ~= '' then
          msg = util.preview_text(prefix .. ': ' .. preview, {
            single_line = true,
          })
        end
        if summary then
          msg = msg .. '\n\n' .. summary
        end
        vim.notify(msg)
      end,
    })
  else
    vim.notify('[autofill] Unknown subcommand: ' .. cmd.args .. '. Use enable|disable|toggle|test', vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  complete = function()
    return { 'enable', 'disable', 'toggle', 'test' }
  end,
  desc = 'Autofill: enable, disable, toggle, or test AI completions',
})
