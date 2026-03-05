local M = {}

local level_map = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

function M.log(level, msg)
  local config = require('autofill.config').get()
  local config_level = level_map[config.log_level] or vim.log.levels.WARN
  local msg_level = level_map[level] or vim.log.levels.INFO
  if msg_level < config_level then return end

  local first_line = msg:match('^[^\n]*')
  local text = '[autofill] ' .. first_line

  vim.schedule(function()
    if msg_level >= vim.log.levels.WARN then
      -- Errors/warnings: always visible — brief echo in insert mode, notify otherwise
      if vim.fn.mode() == 'i' then
        vim.api.nvim_echo({ { text, msg_level == vim.log.levels.ERROR and 'ErrorMsg' or 'WarningMsg' } }, true, {})
      else
        vim.notify(text, msg_level)
      end
    else
      -- Debug/info: silent, only in :messages
      vim.api.nvim_echo({ { text, 'Comment' } }, true, {})
    end
  end)
end

function M.get_api_key(env_var)
  local key = os.getenv(env_var)
  if not key or key == '' then
    M.log('warn', 'API key not found in environment variable: ' .. env_var)
    return nil
  end
  return key
end

return M
