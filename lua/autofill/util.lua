local M = {}

local level_map = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local function cmdline_width()
  return math.max(vim.o.columns - 1, 1)
end

local function truncate_display(text, max_width)
  text = tostring(text or '')
  max_width = math.max(max_width or cmdline_width(), 1)

  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end

  if max_width <= 3 then
    return string.rep('.', max_width)
  end

  local limit = max_width - 3
  local chars = vim.fn.strchars(text)
  local low = 0
  local high = chars

  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    local slice = vim.fn.strcharpart(text, 0, mid)
    if vim.fn.strdisplaywidth(slice) <= limit then
      low = mid
    else
      high = mid - 1
    end
  end

  return vim.fn.strcharpart(text, 0, low) .. '...'
end

function M.preview_text(text, opts)
  opts = opts or {}
  text = tostring(text or '')

  if opts.single_line then
    text = text:gsub('%s+', ' ')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
  elseif opts.first_line then
    text = text:match('^[^\r\n]*') or ''
  end

  return truncate_display(text, opts.max_width)
end

local function format_text(msg)
  local text = '[autofill] ' .. tostring(msg or '')

  -- Keep echoes inside the command line width to avoid "Press ENTER" prompts.
  return M.preview_text(text, {
    first_line = true,
    max_width = cmdline_width(),
  })
end

function M.log(level, msg)
  local config = require('autofill.config').get()
  local config_level = level_map[config.log_level] or vim.log.levels.WARN
  local msg_level = level_map[level] or vim.log.levels.INFO
  if msg_level < config_level then return end

  local first_line = msg:match('^[^\n]*')
  local text = format_text(first_line)

  vim.schedule(function()
    if msg_level >= vim.log.levels.WARN then
      -- Errors/warnings: always visible — brief echo in insert mode, notify otherwise
      if vim.fn.mode() == 'i' then
        vim.api.nvim_echo({ { text, msg_level == vim.log.levels.ERROR and 'ErrorMsg' or 'WarningMsg' } }, false, {})
      else
        vim.notify(text, msg_level)
      end
    else
      -- Debug/info: silent, no history to avoid triggering prompt
      vim.api.nvim_echo({ { text, 'Comment' } }, false, {})
    end
  end)
end

function M.profile(msg)
  local config = require('autofill.config').get()
  if not config.profiling then return end

  local text = format_text(msg)
  vim.schedule(function()
    vim.api.nvim_echo({ { text, 'Comment' } }, false, {})
  end)
end

function M.get_api_key(env_var, opts)
  opts = opts or {}
  local key = os.getenv(env_var)
  if not key or key == '' then
    local msg = 'API key not found in environment variable: ' .. env_var
    if not opts.silent then
      M.log('warn', msg)
    end
    return nil, msg
  end
  return key
end

return M
