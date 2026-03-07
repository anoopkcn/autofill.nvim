# autofill.nvim

AI-assisted ghost-text autocompletion for Neovim.

`autofill.nvim` watches insert-mode edits, builds a compact prompt from the current buffer plus nearby context, and renders model output inline as ghost text. Suggestions can be accepted, partially accepted, or ignored while you keep typing.

## Features

- Ghost-text completions in insert mode
- Supported backends: Blablador, Claude, Gemini, and OpenAI
- Cached completions and quick local-prefix reuse
- Optional Treesitter and neighbor-file context, plus opt-in LSP symbols and diagnostics
- `:Autofill test` for live backend checks
- `:checkhealth autofill` for config and runtime checks
- Headless test suite and CI coverage for core regressions

## Requirements

- Neovim `0.10+`
- `curl`
- An API key for the backend you configure
- Treesitter context is enabled by default and can be disabled; LSP context is available as an opt-in config toggle

## Supported Backends

| Backend | Environment Variable | Default Model |
| --- | --- | --- |
| `blablador` | `BLABLADOR_API_KEY` | `alias-code` |
| `claude` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| `gemini` | `GEMINI_API_KEY` | `gemini-2.5-flash` |
| `openai` | `OPENAI_API_KEY` | `gpt-5-mini` |

`ollama` is intentionally not supported in the current release surface.

## Installation

Install the plugin with your plugin manager of choice. Replace the source with your repository path or local checkout.

Example with `lazy.nvim`:

```lua
{
  dir = "/path/to/autofill.nvim",
  config = function()
    require("autofill").setup({
      backend = "gemini",
      keymaps = {
        accept = "<Tab>",
      },
    })
  end,
}
```

## Quick Start

Minimum setup:

```lua
require("autofill").setup({
  backend = "claude",
  model = "claude-haiku-4-5-20251001",
})
```

Typical setup with explicit direct keymaps:

```lua
require("autofill").setup({
  backend = "gemini",
  model = "gemini-2.5-flash",
  log_level = "warn",
  temperature = {
    code = 0.1,
  },
  keymaps = {
    accept = "<Tab>",
    accept_word = "<C-l>",
    dismiss = "<C-]>",
  },
})
```

Direct keymaps are opt-in. The plugin does not claim `<Tab>` by default.

If you prefer to manage mappings yourself, use the built-in `<Plug>` targets:

```lua
vim.keymap.set("i", "<Tab>", "<Plug>(AutofillAccept)")
vim.keymap.set("i", "<C-l>", "<Plug>(AutofillAcceptWord)")
vim.keymap.set("i", "<C-]>", "<Plug>(AutofillDismiss)")
```

## Commands

- `:Autofill enable`
- `:Autofill disable`
- `:Autofill toggle`
- `:Autofill test`
- `:checkhealth autofill`

`:Autofill test` sends a real completion request using the current buffer and reports backend or credential failures directly.

## Configuration

Current defaults:

```lua
require("autofill").setup({
  enabled = true,
  backend = "claude",
  model = nil,
  debounce_ms = 200,
  throttle_ms = 400,
  context_window = 8000,
  context_ratio = 0.75,
  max_tokens = 256,
  log_level = "warn",
  profiling = false,
  streaming_display = true,
  neighbors = {
    enabled = true,
    budget = 2000,
    max_files = 2,
  },
  treesitter = {
    enabled = true,
  },
  lsp = {
    enabled = false,
  },
  prompt = {
    max_chars = 12000,
    max_neighbors_chars = 2500,
    max_neighbor_file_chars = 900,
    max_outline_chars = 1200,
    max_scope_chars = 900,
    max_diagnostics_chars = 600,
    max_symbol_count = 15,
    max_scope_count = 8,
    max_diagnostic_count = 5,
    mode = "auto",
    prose_filetypes = { "markdown", "text", "gitcommit", "rst", "asciidoc" },
  },
  temperature = {
    code = 0.1,
    prose = nil,
  },
  filetypes_exclude = {},
  keymaps = {
    accept = nil,
    accept_word = nil,
    dismiss = nil,
  },
  blablador = {
    api_key_env = "BLABLADOR_API_KEY",
    model = "alias-code",
    base_url = "https://api.helmholtz-blablador.fz-juelich.de/v1",
    timeout_ms = 10000,
  },
  claude = {
    api_key_env = "ANTHROPIC_API_KEY",
    model = "claude-haiku-4-5-20251001",
    timeout_ms = 10000,
  },
  gemini = {
    api_key_env = "GEMINI_API_KEY",
    model = "gemini-2.5-flash",
    timeout_ms = 10000,
  },
  openai = {
    api_key_env = "OPENAI_API_KEY",
    model = "gpt-5-mini",
    timeout_ms = 10000,
  },
})
```

Important options:

- `backend`: `blablador`, `claude`, `gemini`, or `openai`
- `model`: optional shorthand for the selected backend's model; when set, it overrides `openai.model`, `claude.model`, `gemini.model`, or `blablador.model` for the active backend
- `streaming_display`: use streaming ghost updates when `true`; use a real non-streaming backend request when `false`
- `prompt.mode`: choose `auto`, `code`, or `prose`; `auto` switches to prose instructions for configured prose filetypes and comment contexts
- `prompt.prose_filetypes`: filetypes that should use prose-oriented prompt instructions when `prompt.mode = "auto"`
- `temperature.code`: default `0.1`; lowers randomness for code-mode completions
- `temperature.prose`: optional prose-mode override; when `nil`, the backend keeps its own default temperature
- `profiling`: include timing output in `:Autofill test`
- `filetypes_exclude`: disable the plugin for specific filetypes
- `neighbors.enabled`: include nearby file snapshots in the prompt
- `neighbors.budget`: total neighbor-context character budget
- `neighbors.max_files`: maximum number of neighbor files included
- `treesitter.enabled`: include Treesitter-derived scope and semantic context in the prompt
- `lsp.enabled`: include LSP document symbols and nearby diagnostics in the prompt
- `blablador.base_url`: override the OpenAI-compatible Blablador API root when needed

If you prefer backend-specific configuration instead of the shorthand, keep setting the model inside the backend block:

```lua
require("autofill").setup({
  backend = "openai",
  openai = {
    model = "gpt-5-mini",
  },
})
```

Disable Treesitter-backed context if you want prompt construction to rely only on buffer, neighbors, and any explicitly enabled LSP data:

```lua
require("autofill").setup({
  treesitter = {
    enabled = false,
  },
})
```

Enable LSP-backed context explicitly if you want the previous behavior:

```lua
require("autofill").setup({
  lsp = {
    enabled = true,
  },
})
```

Force prose mode or tune temperatures explicitly if you want behavior that differs from the defaults:

```lua
require("autofill").setup({
  prompt = {
    mode = "prose",
  },
  temperature = {
    code = 0.05,
    prose = 0.7,
  },
})
```

## Health And Troubleshooting

Start with:

```vim
:checkhealth autofill
:Autofill test
```

Common problems:

- No suggestions appear:
  The plugin may be disabled, the current filetype may be excluded, the backend may be unsupported, or the API key may be missing.
- `Tab` does not accept completions:
  Direct keymaps are not enabled by default. Set `keymaps.accept = "<Tab>"` or bind `<Plug>(AutofillAccept)` yourself.
- A configured direct keymap is ignored:
  A buffer-local mapping may already own that key. In that case map the `<Plug>` target instead.
- Backend test fails immediately:
  Check the backend environment variable and confirm `curl` is installed.
- Suggestions feel too noisy or too slow:
  Tune `debounce_ms`, `throttle_ms`, `streaming_display`, and `neighbors`.

## Development

Syntax check:

```sh
find lua plugin tests -name '*.lua' -print0 | xargs -0 -n1 luac -p
```

Run the headless test suite:

```sh
XDG_STATE_HOME=/tmp nvim --headless -u NONE -i NONE "+set rtp+=." "+lua require('tests.run').run()" +qa!
```

CI runs the same syntax and headless checks on pushes and pull requests.

## LICENSE
[MIT](LICENSE)
