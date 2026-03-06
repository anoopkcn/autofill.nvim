# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Neovim plugin (Lua) that provides AI ghost-text autocompletion in insert mode. It watches typing via `TextChangedI`, builds a prompt from buffer text + optional context (treesitter, neighbor files, and opt-in LSP data), sends it to a configurable AI backend, and renders the response as inline ghost text using extmarks. Targets Neovim >= 0.10. No external Lua dependencies.

## Commands

**Syntax check:**
```sh
find lua plugin tests -name '*.lua' -print0 | xargs -0 -n1 luac -p
```

**Run all tests (headless Neovim):**
```sh
XDG_STATE_HOME=/tmp nvim --headless -u NONE -i NONE "+set rtp+=." "+lua require('tests.run').run()" +qa!
```

There is no way to run a single test file in isolation. The test runner in `tests/run.lua` has a hardcoded list; to run one test, temporarily comment out the others.

CI (`.github/workflows/ci.yml`) runs both the syntax check and headless tests on every push/PR.

## Architecture

### Request lifecycle

1. **Trigger** (`trigger.lua`) — `TextChangedI` autocmd fires, debounces/throttles, creates a snapshot of buffer state (cursor, changedtick, sequence number). Snapshots are checked for staleness at every async boundary.

2. **Cache** (`cache.lua`) — Two-tier LRU: a "quick cache" keyed on buffer position + context revision (cheap to compute), and a "full cache" keyed on the actual prompt hash. Both have 50-entry limit and 30s TTL.

3. **Context** (`context/`) — Provider-based system via `context/registry.lua`. Four built-in providers run in order: buffer, treesitter, lsp, neighbors. The LSP provider is disabled by default and only contributes when `lsp.enabled = true`. Each provider has `collect()` and optional `revision()`. The registry collects all provider data into a single context object.

4. **Prompt** (`backend/prompt.lua`) — Shared across all backends. Builds a user message from context with budget-aware section fitting (neighbors, outline, scopes, diagnostics, cursor text). Sections are added greedily up to `prompt.max_chars`.

5. **Backend** (`backend/init.lua` dispatches to `backend/{claude,gemini,openai,blablador}.lua`) — Each backend formats the prompt into its API's request shape. Response text passes through `sanitize.lua` (strips code fences, trims overlap with surrounding code).

6. **Transport** (`transport/request.lua` + `transport/http.lua`) — Cancel-before-send pattern: each new request for a buffer cancels the previous one. HTTP is `vim.system` + curl with SSE streaming support. Session-keyed so multiple buffers can have independent in-flight requests.

7. **Display** (`display/ghost.lua`) — Renders suggestion as extmark virtual text (inline `virt_text` + `virt_lines` for multiline). Handles accept, accept-word, dismiss, and advance (when typed chars match the suggestion prefix). Streaming renders are throttled to 75ms.

### Key design patterns

- **Snapshot staleness**: Every async callback (timer fire, HTTP response, SSE chunk) re-checks that the snapshot matches current state (buffer, cursor, changedtick, mode, sequence number) before proceeding.
- **Session-per-buffer**: `trigger.lua` maintains per-buffer sessions with timers; `request.lua` maintains per-session-key HTTP state. Buffer cleanup happens on `InsertLeave`, `BufLeave`, `BufDelete`.
- **Keymap wrapping**: Direct keymaps (e.g. `<Tab>`) save and wrap existing mappings via fallback `<Plug>` targets, restoring originals on teardown.
- **Config validation**: `config.lua` has thorough `inspect()` / `validate()` that runs on `setup()`. Backend runtime checks (curl exists, API key set) are separate in `backend/init.lua:inspect_runtime()`.

### Test conventions

Tests live in `tests/*_spec.lua`. Each spec file is a function (not a module table) that runs assertions via `assert()`. Test helpers are in `tests/helpers.lua` — provides `reset_runtime()`, `new_buffer()`, `feedkeys()`, `wait()`. Tests run inside headless Neovim with no user config (`-u NONE`).

## Supported backends

`blablador`, `claude`, `gemini`, `openai` — each configured under its own key in `config.lua`. `ollama` was intentionally removed.
