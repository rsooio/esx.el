# esx.el design

## Scope

Minimal CIDER/SLIME-style runtime client for `esx --server`.

Core interaction:

- one eval command
- one jump command
- one interactive REPL buffer
- inline result overlays in source buffers
- no LSP features, no debugger, no inspector, no load-file

## CIDER's design (reference)

CIDER is a client for nREPL. Its source/REPL linkage has four parts:

1. **One REPL per connection.** A connection belongs to a project/session.
   CIDER does not use a single global REPL; `cider-current-repl` resolves the
   REPL for the current buffer through the session. Multiple projects therefore
   get multiple REPL buffers.
2. **Connection-style buffer names.** The REPL buffer name template is
   `*cider-repl <project>(<host>:<port>)*`, so the name identifies both the
   project and the connection.
3. **One namespace variable per buffer.** `cider-buffer-ns` is buffer-local.
   Source buffers derive the ns from the `(ns ...)` form; the REPL and special
   buffers store it in `cider-buffer-ns`. `cider-current-ns` falls back to the
   current REPL's ns, then to `user`.
4. **Symmetric switching.**
   - Source `C-c C-z` -> `cider-switch-to-repl-buffer`; with a prefix argument
     it also sets the REPL ns to the source buffer's ns.
   - REPL `C-c C-z` -> `cider-switch-to-last-clojure-buffer`.
   - `cider-repl-set-ns` changes the REPL ns and re-renders the prompt.
   - `cider-eval-last-sexp-to-repl` evaluates with the source ns and inserts
     the result into the REPL without changing the REPL ns.

For esx's MVP we deliberately simplify point 1: **one connection and one REPL
buffer**, not one per project. Namespaces are still per-file, so most state is
isolated by the file URL. This keeps the implementation small; a project-level
connection registry can be added later without changing the public commands.

## Namespace model

Two namespaces:

```text
file-ns   = file://<buffer-file-name>   (nil when the buffer has no file)
buffer-ns = the REPL's current ns, or a buffer-local override
```

Priority:

```text
default eval:  file-ns > buffer-ns > "user"
C-u eval:      buffer-ns > file-ns > "user"
```

For a source buffer, `buffer-ns` normally means the current REPL namespace.
A source buffer may set its own buffer-local override; this is not exposed as a
command in the MVP.

`esx-current-ns` returns the current buffer/REPL namespace.
`esx-default-ns` returns the file-first namespace.

### eval

| Invocation | Namespace |
| --- | --- |
| `C-M-x` | `esx-default-ns` |
| `C-u C-M-x` | `esx-current-ns` |

### jump

| Invocation | Behavior |
| --- | --- |
| `C-c C-z` | Source -> REPL, set REPL ns to `esx-default-ns` |
| `C-u C-c C-z` | Source -> REPL, set REPL ns to `esx-current-ns` (usually keep it) |
| `C-c C-z` in REPL | Return to the source buffer that opened the REPL |

## Buffer naming

Only one REPL buffer exists. Its name follows the namespace:

```text
*ESX[user]*
*ESX[foo.js]*
```

`esx--ns-display` turns a `file://` namespace into its basename. The buffer is
renamed whenever the REPL namespace changes. This is more direct than CIDER's
project/port template and makes the current namespace visible in the buffer
list and mode line.

## Source eval

`esx-eval` is the only eval command:

- active region -> evaluate the region
- otherwise -> evaluate the top-level node at point
  (the node whose parent is `program` or `module`)

Results are displayed in an overlay at the end of the evaluated form:

```text
const x = 41; => undefined
x + 1          => 42
```

- `after-string` overlay, no buffer modification
- result face: light/dark grey background with a thin box, like CIDER
- error face: orange-red / firebrick background
- multiline results are flattened and truncated
- old result overlays in the buffer are removed before a new eval
- overlays are cleared automatically when the buffer text changes
- `C-c C-o` / `C-c C-g` clears all result overlays manually
- `C-g` is not bound: it is Emacs' quit character and is handled before
  local keymaps.  Instead, a `pre-command-hook` checks
  `this-command = keyboard-quit` and clears result overlays only when no
  region is selected; native quit semantics are preserved
- an eval result is discarded if the buffer changed while the request was in flight
- stdout/stderr go to the REPL buffer, not the overlay
- errors also go to the REPL

The REPL buffer is created in the background if it does not exist; eval never
switches windows.

The server evaluates through `node:inspector` (`Runtime.evaluate` with
`replMode: true`, then `Runtime.awaitPromise` for promise results), matching
Node main's REPL evaluator.  It does not use `node:repl` or an async IIFE.
Errors come from `exceptionDetails` and are returned as `ex` with
`status: ["eval-error", "done"]`.  The client also has an `esx-eval-timeout`
watchdog so a missing response cannot leave the REPL waiting forever.

## REPL

The REPL is a CIDER/SLIME-style interactive major mode:

```text
[output region] [prompt] [input region]
                ^
                output-end / prompt-start
```

- prompt shows `(esx--ns-display esx-repl-ns)`
- RET submits input
- output is inserted before the prompt
- history with M-p / M-n
- only `.ns` is kept as a REPL command
- `C-c C-z` returns to the source buffer

The current implementation's `output-end` after the prompt is a bug for
external output; this design fixes it.

## Commands

| Key | Command |
| --- | --- |
| `C-M-x` | `esx-eval` |
| `C-c C-z` | `esx-jump` |
| `C-c C-o` / `C-c C-g` | `esx-clear-result-overlays` |
| `RET` | `esx-repl-return` |
| `M-p` / `M-n` | REPL history |
| `C-c M-o` | `esx-repl-clear-buffer` |
| `M-x esx-shutdown` | stop the server |

Removed:

- eval-defun / eval-last-sexp / eval-region / eval-buffer / eval-dwim
- eval-last-sexp-to-repl
- load-file
- switch-ns / ns-browser
- `.vars` / `.load`

## Files

```text
esx.el           public mode, keymap, jump, lifecycle
esx-client.el    process, JSON lines, async eval
esx-repl.el      interactive REPL
esx-eval.el      esx-eval, code bounds, overlays
esx-ns.el        file-ns / buffer-ns / display
```

## Limitations

- one server / one REPL buffer (no per-project registry yet)
- no load-file, inspector, debugger, completion, eldoc, xref, diagnostics
- `require("./x")` resolves relative to the source file directory
- bare static/dynamic imports resolve through Node's ESM resolver with the
  source file as `parentURL` (`esx-modules://` + `registerHooks`), so package
  `exports`/`imports` conditions and `#aliases` are preserved
