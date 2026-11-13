# esx.el

Minimal CIDER/SLIME-style Emacs client for
[esx](https://github.com/rsooio/esx), an ESM REPL with file-based namespaces.

The package only does runtime interaction. Completion, eldoc, xref, hover,
diagnostics, and rename are left to the JS/TS LSP setup.

## Commands

| Key | Command | Description |
| --- | --- | --- |
| `C-M-x` | `esx-eval` | Evaluate the active region, or the top-level node at point. Results are shown inline. |
| `C-c C-z` | `esx-jump` | Jump between the source buffer and the REPL. From a source buffer, sync the REPL namespace to the file namespace. |
| `C-c C-o` / `C-c C-g` | `esx-clear-result-overlays` | Clear inline results in the current buffer. `C-g` is not bound; `pre-command-hook` detects `keyboard-quit` and clears overlays only when no region is selected, so native quit semantics are preserved. |
| `RET` | `esx-repl-return` | Submit REPL input. |
| `M-p` / `M-n` | history | REPL input history. |
| `C-c M-o` | `esx-repl-clear-buffer` | Clear the REPL. |
| `M-x esx-shutdown` | | Stop the server and kill the REPL buffer. |

Evaluation errors are returned by the server as structured `ex` responses
and shown as `Error: ...`; they do not print Node's `Uncaught` text.  An eval
that receives no response is failed after `esx-eval-timeout` seconds
(default 30), so the REPL cannot hang forever.

Prefix arguments:

- `C-u C-M-x` evaluates in the current buffer/REPL namespace instead of the
  file namespace.
- `C-u C-c C-z` jumps to the REPL without changing its namespace.

## Module resolution

Relative imports resolve against the source file.  Bare imports (including
`#package-imports`) resolve through Node's ESM resolver with the source file as
the parent, so package `exports`/`imports` conditions are preserved.

## Namespace model

```text
file-ns   = file://<buffer-file-name>
buffer-ns = the REPL's current namespace, or a buffer-local override
```

Default eval prefers `file-ns`; `C-u` prefers `buffer-ns`. See
[DESIGN.md](https://github.com/rsooio/esx.el/blob/master/DESIGN.md).

## REPL buffer

There is one REPL buffer. Its name follows the current namespace:

```text
*ESX[user]*
*ESX[foo.js]*
```

It is an interactive CIDER/SLIME-style buffer with a prompt, editable input,
history, and asynchronous output inserted before the prompt.

## Installation

Install from git with `use-package` + `:vc`:

```elisp
(use-package esx
  :vc (:url "https://github.com/rsooio/esx.el")
  :custom
  (esx-server-command '("node" "/path/to/esx/cli.ts" "--server"))
  :config
  (esx-setup))   ; enable esx-mode in js-ts-mode / typescript-ts-mode
```

The package is the Emacs client only; the server lives in
[esx](https://github.com/rsooio/esx). Clone it and install its dependencies:

```sh
git clone https://github.com/rsooio/esx
cd esx && npm install
```

Point `esx-server-command` at that checkout as shown above, or run
`npm link` in the checkout to provide an `esx` executable and keep the
default `("esx" "--server")`.

Then `M-x esx-ensure` or `C-c C-z` starts the server and opens the REPL.

## Requirements

- Emacs 29+ (tree-sitter)
- Node 24+
- `tree-sitter-javascript` grammar for `js-ts-mode`

## Not implemented

- completion / eldoc / xref / flymake (LSP)
- debugger
- inspector
- load-file
- multiple servers / per-project REPL registry

## Development

```sh
make test     # ERT tests against a mock server
make compile  # byte-compile
```

## License

GPLv3, see [LICENSE](LICENSE).
