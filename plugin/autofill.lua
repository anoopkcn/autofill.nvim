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
    local ctx = require('autofill.context').gather(
      vim.api.nvim_get_current_buf(),
      vim.api.nvim_win_get_cursor(0)
    )
    vim.notify('[autofill] Sending test request to ' .. require('autofill.config').get().backend .. '...')
    require('autofill.backend').complete(ctx, function(suggestion)
      if not suggestion then
        vim.notify('[autofill] Backend returned nil', vim.log.levels.WARN)
        return
      end
      vim.notify('[autofill] Got suggestion (' .. #suggestion .. ' chars):\n' .. suggestion)
    end)
  else
    vim.notify('[autofill] Unknown subcommand: ' .. cmd.args .. '. Use enable|disable|toggle|test', vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  complete = function()
    return { 'enable', 'disable', 'toggle', 'test' }
  end,
  desc = 'Autofill: enable, disable, or toggle AI completions',
})
