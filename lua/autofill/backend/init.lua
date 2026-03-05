local util = require('autofill.util')

local M = {}

function M.complete(ctx, callback)
  local config = require('autofill.config').get()
  local backend_name = config.backend

  local ok, backend = pcall(require, 'autofill.backend.' .. backend_name)
  if not ok then
    util.log('error', 'Unknown backend: ' .. backend_name)
    return
  end

  backend.complete(ctx, callback)
end

return M
