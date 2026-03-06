local helpers = require('tests.helpers')

local function find_symbol(symbols, name)
  for _, symbol in ipairs(symbols or {}) do
    if symbol.name == name then
      return symbol
    end
  end
  return nil
end

return function()
  helpers.reset_runtime()

  local config = require('autofill.config')
  local buffer_context = require('autofill.context.buffer')
  local context = require('autofill.context')
  local treesitter_context = require('autofill.context.treesitter')
  local lsp_context = require('autofill.context.lsp')
  local neighbors_context = require('autofill.context.neighbors')
  local prompt = require('autofill.backend.prompt')

  config.setup({
    context_window = 16,
    context_ratio = 0.5,
  })

  local buffer_bufnr = helpers.new_buffer({
    'prefix prefix prefix',
    'cursor-here-suffix',
    'tail tail tail',
  }, {
    filetype = 'lua',
    row = 2,
    col = 6,
  })
  local sliced = buffer_context.get_text(buffer_bufnr, { 2, 6 })
  assert(#sliced.before <= 8 and #sliced.after <= 8, 'buffer context should honor the configured byte budgets')
  assert(sliced.is_truncated_before and sliced.is_truncated_after, 'buffer context should flag truncated slices')

  config.setup({
    context_window = 200,
    context_ratio = 0.5,
  })

  local original_ts_get_context = treesitter_context.get_context
  local original_lsp_get_context = lsp_context.get_context
  local original_lsp_get_symbols = lsp_context.get_symbols
  local original_neighbors_get_context = neighbors_context.get_context

  treesitter_context.get_context = function()
    return {
      scopes = {
        { type = 'function_declaration', line = 3, header = 'local function demo()' },
      },
      in_comment = false,
      in_string = true,
    }
  end
  lsp_context.get_context = function()
    return {
      diagnostics = {
        { line = 7, severity = vim.diagnostic.severity.WARN, message = 'unused local value' },
      },
    }
  end
  lsp_context.get_symbols = function()
    return {
      { kind = 'Function', name = 'demo', line = 3, container = '' },
    }
  end
  neighbors_context.get_context = function()
    return {
      { filename = 'helper.lua', content = 'return 1' },
    }
  end

  local gather_bufnr = helpers.new_buffer({
    'local example = ',
  }, {
    name = '/tmp/autofill-context-prompt/sample.lua',
    filetype = 'lua',
    row = 1,
    col = 16,
  })
  local gathered = context.gather(gather_bufnr, { 1, 16 })
  local message = prompt.build_user_message(gathered)
  assert(vim.deep_equal(gathered.provider_order, {
    'buffer',
    'treesitter',
    'lsp',
    'neighbors',
  }), 'gather should expose the builtin provider order')
  assert(gathered.providers.buffer.before == gathered.before_cursor, 'gather should preserve legacy buffer fields from provider output')
  assert(gathered.providers.treesitter == gathered.treesitter, 'gather should preserve legacy Treesitter fields from provider output')
  assert(gathered.providers.lsp == nil, 'gather should omit disabled LSP provider output')
  assert(gathered.lsp == nil, 'gather should preserve absent legacy LSP fields when disabled')
  assert(gathered.providers.neighbors == gathered.neighbors, 'gather should preserve legacy neighbor fields from provider output')
  assert(message:find('File: sample.lua', 1, true), 'prompt should include the current filename')
  assert(message:find('Language: lua', 1, true), 'prompt should include the current filetype')
  assert(message:find('Related files:\n--- helper.lua ---\nreturn 1', 1, true), 'prompt should include neighbor file snapshots')
  assert(message:find('Scope chain:\n  function_declaration %(line 3%): local function demo%(%)'), 'prompt should include Treesitter scopes')
  assert(message:find('Cursor is inside a string.', 1, true), 'prompt should include Treesitter semantic hints')
  assert(not message:find('File outline:', 1, true), 'prompt should omit LSP symbols when LSP context is disabled')
  assert(not message:find('Nearby diagnostics:', 1, true), 'prompt should omit diagnostics when LSP context is disabled')
  assert(message:find('local example = <CURSOR>', 1, true), 'prompt should include the cursor marker')
  local related_pos = assert(message:find('Related files:', 1, true))
  local scope_pos = assert(message:find('Scope chain:', 1, true))
  local cursor_pos = assert(message:find('local example = <CURSOR>', 1, true))
  assert(related_pos < scope_pos and scope_pos < cursor_pos, 'prompt sections should render in stable provider-backed order when LSP context is disabled')

  config.setup({
    context_window = 200,
    context_ratio = 0.5,
    treesitter = {
      enabled = false,
    },
  })

  gathered = context.gather(gather_bufnr, { 1, 16 })
  message = prompt.build_user_message(gathered)
  assert(gathered.providers.treesitter == nil, 'gather should omit disabled Treesitter provider output')
  assert(gathered.treesitter == nil, 'gather should preserve absent legacy Treesitter fields when disabled')
  assert(not message:find('Scope chain:', 1, true), 'prompt should omit Treesitter scopes when Treesitter context is disabled')
  assert(not message:find('Cursor is inside a string.', 1, true), 'prompt should omit Treesitter semantic hints when Treesitter context is disabled')
  related_pos = assert(message:find('Related files:', 1, true))
  cursor_pos = assert(message:find('local example = <CURSOR>', 1, true))
  assert(related_pos < cursor_pos, 'prompt should preserve section ordering when Treesitter context is disabled')

  config.setup({
    context_window = 200,
    context_ratio = 0.5,
    lsp = {
      enabled = true,
    },
  })

  gathered = context.gather(gather_bufnr, { 1, 16 })
  message = prompt.build_user_message(gathered)
  assert(gathered.providers.lsp == gathered.lsp, 'gather should preserve legacy LSP fields from provider output when enabled')
  assert(message:find('File outline:\n  Function demo %(line 3%)'), 'prompt should include LSP symbols when enabled')
  assert(message:find('Nearby diagnostics:\n  Line 7 %[WARN%]: unused local value'), 'prompt should include nearby diagnostics when enabled')
  local outline_pos = assert(message:find('File outline:', 1, true))
  local diagnostics_pos = assert(message:find('Nearby diagnostics:', 1, true))
  related_pos = assert(message:find('Related files:', 1, true))
  scope_pos = assert(message:find('Scope chain:', 1, true))
  cursor_pos = assert(message:find('local example = <CURSOR>', 1, true))
  assert(related_pos < outline_pos and outline_pos < scope_pos and scope_pos < diagnostics_pos and diagnostics_pos < cursor_pos, 'prompt sections should render in stable provider-backed order when LSP context is enabled')

  config.setup({
    context_window = 200,
    context_ratio = 0.5,
    prompt = {
      max_chars = 700,
      max_neighbors_chars = 90,
      max_neighbor_file_chars = 18,
      max_outline_chars = 80,
      max_scope_chars = 80,
      max_diagnostics_chars = 70,
      max_symbol_count = 1,
      max_scope_count = 1,
      max_diagnostic_count = 1,
    },
  })

  local tight_message = prompt.build_user_message({
    filename = '/tmp/tight.lua',
    filetype = 'lua',
    before_cursor = string.rep('b', 40),
    after_cursor = string.rep('a', 40),
    is_truncated_before = true,
    is_truncated_after = true,
    neighbors = {
      { filename = 'neighbor.lua', content = string.rep('n', 40), is_truncated = true },
      { filename = 'ignored.lua', content = 'return 2' },
    },
    treesitter = {
      scopes = {
        { type = 'function_declaration', line = 3, header = string.rep('scope', 10) },
        { type = 'if_statement', line = 4, header = 'ignored scope' },
      },
      in_comment = true,
      in_string = true,
    },
    lsp = {
      symbols = {
        { kind = 'Function', name = 'Alpha', line = 3, container = '' },
        { kind = 'Function', name = 'Beta', line = 4, container = '' },
      },
      diagnostics = {
        { line = 7, severity = vim.diagnostic.severity.WARN, message = string.rep('warn ', 20) },
        { line = 8, severity = vim.diagnostic.severity.ERROR, message = 'ignored diagnostic' },
      },
    },
  })
  assert(#tight_message <= 700, 'prompt should honor the configured overall character budget')
  assert(tight_message:find('Context notes:\nContext before the cursor was truncated.\nContext after the cursor was truncated.', 1, true), 'prompt should signal truncated surrounding buffer context')
  assert(tight_message:find('Related files %(truncated%):'), 'prompt should signal truncated related-file context')
  assert(tight_message:find('%-%-%- neighbor%.lua %(truncated%) %-%-%-'), 'prompt should signal per-file neighbor truncation')
  assert(not tight_message:find('ignored.lua', 1, true), 'prompt should drop extra optional context when section budgets are exhausted')
  assert(tight_message:find('File outline %(truncated%):'), 'prompt should signal truncated outline sections')
  assert(tight_message:find('Scope chain %(truncated%):'), 'prompt should signal truncated scope sections')
  assert(tight_message:find('Nearby diagnostics %(truncated%):'), 'prompt should signal truncated diagnostics sections')

  treesitter_context.get_context = original_ts_get_context
  lsp_context.get_context = original_lsp_get_context
  lsp_context.get_symbols = original_lsp_get_symbols
  neighbors_context.get_context = original_neighbors_get_context

  local original_get_clients = vim.lsp.get_clients
  local original_make_params = vim.lsp.util.make_text_document_params
  local original_buf_request_all = vim.lsp.buf_request_all
  local original_diagnostic_get = vim.diagnostic.get

  vim.lsp.get_clients = function(opts)
    if opts and opts.method == 'textDocument/documentSymbol' then
      return { { id = 1 }, { id = 2 } }
    end
    return {}
  end
  vim.lsp.util.make_text_document_params = function()
    return { uri = 'file:///tmp/autofill-context-lsp/example.lua' }
  end
  vim.lsp.buf_request_all = function(_, _, _, callback)
    callback({
      one = {
        result = {
          {
            name = 'Outer',
            kind = 12,
            range = { start = { line = 1 } },
            children = {
              {
                name = 'Inner',
                kind = 6,
                range = { start = { line = 2 } },
              },
            },
          },
          {
            name = 'Outer',
            kind = 12,
            range = { start = { line = 1 } },
          },
        },
      },
      two = {
        result = {
          {
            name = 'Var',
            kind = 13,
            location = { range = { start = { line = 8 } } },
          },
        },
      },
    })
  end
  vim.diagnostic.get = function()
    return {
      { lnum = 9, message = 'closest', severity = vim.diagnostic.severity.ERROR },
      { lnum = 8, message = 'second closest', severity = vim.diagnostic.severity.WARN },
      { lnum = 20, message = 'too far away', severity = vim.diagnostic.severity.INFO },
    }
  end

  local lsp_bufnr = helpers.new_buffer({
    'local x = 1',
    'local y = 2',
    'local z = 3',
    'local a = 4',
    'local b = 5',
    'local c = 6',
    'local d = 7',
    'local e = 8',
    'local f = 9',
    'local g = 10',
  }, {
    name = '/tmp/autofill-context-lsp/example.lua',
    filetype = 'lua',
    row = 10,
    col = 0,
  })
  lsp_context.refresh_symbols(lsp_bufnr, { immediate = true })
  helpers.wait(200, function()
    local symbols = lsp_context.get_symbols(lsp_bufnr)
    return symbols ~= nil and #symbols == 3
  end, 'LSP symbols were not refreshed')

  local symbols = lsp_context.get_symbols(lsp_bufnr)
  assert(find_symbol(symbols, 'Outer') ~= nil, 'LSP symbols should include top-level document symbols')
  assert(find_symbol(symbols, 'Inner') ~= nil, 'LSP symbols should include nested child symbols')
  assert(find_symbol(symbols, 'Var') ~= nil, 'LSP symbols should include location-based symbols')

  local diagnostics = lsp_context.get_context(lsp_bufnr, { 10, 0 })
  assert(diagnostics and #diagnostics.diagnostics == 2, 'LSP diagnostics should filter to nearby entries')
  assert(diagnostics.diagnostics[1].message == 'closest', 'LSP diagnostics should sort by proximity')
  assert(diagnostics.diagnostics[2].message == 'second closest', 'LSP diagnostics should keep the next closest entries')

  local pending_symbol_callbacks = {}
  vim.lsp.buf_request_all = function(_, _, _, callback)
    pending_symbol_callbacks[#pending_symbol_callbacks + 1] = callback
  end

  local stale_lsp_bufnr = helpers.new_buffer({
    'local original = 1',
  }, {
    name = '/tmp/autofill-context-lsp/stale.lua',
    filetype = 'lua',
    row = 1,
    col = 17,
  })
  lsp_context.refresh_symbols(stale_lsp_bufnr, { immediate = true })
  helpers.wait(200, function()
    return #pending_symbol_callbacks == 1
  end, 'initial stale-response LSP request was not scheduled')

  vim.api.nvim_buf_set_lines(stale_lsp_bufnr, 0, -1, false, {
    'local updated = 2',
  })
  lsp_context.mark_symbols_dirty(stale_lsp_bufnr)
  pending_symbol_callbacks[1]({
    stale = {
      result = {
        {
          name = 'Stale',
          kind = 12,
          range = { start = { line = 0 } },
        },
      },
    },
  })
  vim.wait(20)
  assert(lsp_context.get_symbols(stale_lsp_bufnr) == nil, 'stale symbol callbacks should be ignored after insert-mode edits dirty the buffer')

  lsp_context.refresh_symbols(stale_lsp_bufnr, { immediate = true, if_dirty = true })
  helpers.wait(200, function()
    return #pending_symbol_callbacks == 2
  end, 'dirty-symbol refresh was not scheduled after invalidation')
  pending_symbol_callbacks[2]({
    fresh = {
      result = {
        {
          name = 'Fresh',
          kind = 12,
          range = { start = { line = 0 } },
        },
      },
    },
  })
  helpers.wait(200, function()
    local refreshed = lsp_context.get_symbols(stale_lsp_bufnr)
    return refreshed ~= nil and find_symbol(refreshed, 'Fresh') ~= nil
  end, 'fresh symbol callback did not repopulate the symbol cache')

  vim.lsp.get_clients = original_get_clients
  vim.lsp.util.make_text_document_params = original_make_params
  vim.lsp.buf_request_all = original_buf_request_all
  vim.diagnostic.get = original_diagnostic_get

  config.setup({
    neighbors = {
      enabled = true,
      budget = 120,
      max_files = 2,
      include_disk_files = true,
      disk_scan_limit = 16,
    },
  })

  local neighbor_dir = vim.fn.tempname()
  vim.fn.mkdir(neighbor_dir, 'p')
  vim.fn.writefile({
    'export default function foo() {',
    '  return 1',
    '}',
  }, neighbor_dir .. '/foo.js')

  local current_bufnr = helpers.new_buffer({
    "import foo from './foo'",
    'const value = foo()',
  }, {
    name = neighbor_dir .. '/main.js',
    filetype = 'javascript',
    row = 2,
    col = 5,
  })
  local revision_before = neighbors_context.get_revision(current_bufnr)
  helpers.new_buffer({
    'export const util = () => 2',
  }, {
    name = neighbor_dir .. '/util.js',
    filetype = 'javascript',
  })
  helpers.new_buffer({
    'def other():',
    '    return 3',
  }, {
    name = '/tmp/autofill-context-other/other.py',
    filetype = 'python',
  })

  local neighbor_snapshots = neighbors_context.get_context(current_bufnr)
  assert(neighbor_snapshots and #neighbor_snapshots == 2, 'neighbors context should include the top configured number of files')
  assert(neighbor_snapshots[1].filename == 'foo.js', 'neighbors context should prioritize imported files in the same directory')
  assert(neighbor_snapshots[2].filename == 'util.js', 'neighbors context should rank same-directory same-filetype files ahead of unrelated buffers')
  assert(neighbor_snapshots[1].content:find('export default function foo', 1, true), 'neighbors context should load unopened same-directory files from disk')

  vim.wait(20)
  vim.fn.writefile({ 'export const later = () => 4' }, neighbor_dir .. '/later.js')
  local revision_after = neighbors_context.get_revision(current_bufnr)
  assert(revision_before ~= revision_after, 'neighbors revision should change when same-directory disk candidates change')

  local original_get_parser = vim.treesitter.get_parser
  local original_get_captures_at_pos = vim.treesitter.get_captures_at_pos

  local function make_node(node_type, start_row, end_row, parent)
    local node = {
      _type = node_type,
      _start_row = start_row,
      _end_row = end_row,
      _parent = parent,
    }

    function node:type()
      return self._type
    end

    function node:range()
      return self._start_row, 0, self._end_row, 0
    end

    function node:parent()
      return self._parent
    end

    return node
  end

  local ts_bufnr = helpers.new_buffer({
    'local function demo()',
    '  return value',
    'end',
  }, {
    filetype = 'lua',
    row = 2,
    col = 3,
  })
  local scope_node = make_node('function_declaration', 0, 2, nil)
  local leaf_node = make_node('identifier', 1, 1, scope_node)
  local root = {}

  function root:named_descendant_for_range()
    return leaf_node
  end

  vim.treesitter.get_parser = function()
    return {
      parse = function()
        return {
          {
            root = function()
              return root
            end,
          },
        }
      end,
    }
  end
  vim.treesitter.get_captures_at_pos = function()
    return {
      { capture = 'comment' },
      { capture = 'string' },
    }
  end

  local ts_context = treesitter_context.get_context(ts_bufnr, { 2, 3 })
  assert(ts_context and ts_context.node_type == 'identifier', 'Treesitter context should report the leaf node type')
  assert(ts_context.in_comment and ts_context.in_string, 'Treesitter context should include semantic capture flags')
  assert(#ts_context.scopes == 1, 'Treesitter context should collect scope ancestors')
  assert(ts_context.scopes[1].header == 'local function demo()', 'Treesitter scope headers should use the first line of the scope node')

  vim.treesitter.get_parser = original_get_parser
  vim.treesitter.get_captures_at_pos = original_get_captures_at_pos

  helpers.reset_runtime()
end
