# codex.el

`codex.el` runs the official Codex CLI inside Emacs.

The package is intentionally terminal-first: it keeps Codex authentication,
configuration, slash commands, image paste support, and other TUI behavior in
the official CLI while adding Emacs buffers, project-aware startup, tmux
session reuse, and a simple dashboard.

## Features

- Start Codex in the current project with `M-x codex`.
- Reuse the official Codex login state, including ChatGPT OAuth.
- Run through `vterm` by default for fast terminal rendering.
- Run Codex inside `tmux` by default so sessions can survive SSH disconnects.
- Attach external tmux sessions that are already running Codex.
- Manage live buffers and detected tmux sessions with `M-x codex-dashboard`.
- Open a focused command menu with `M-x codex-menu` when `transient` is available.
- Send a region, buffer, or one-line command to a running Codex session.
- Enter tmux copy-mode from Emacs without typing the tmux prefix key.
- Send Shift+Enter as a Codex CLI multiline-input newline in Codex terminal buffers.

## Requirements

- Emacs 27.1 or newer
- The official `codex` CLI
- `vterm`
- `tmux` when `codex-use-tmux` is enabled
- Optional: `eat` when `codex-backend` is set to `eat`
- Optional: `transient` for `codex-menu`

The package does not manage Codex authentication. Run `codex login` in a normal
terminal first, then `codex.el` will reuse that CLI login state.

## Installation

Clone this repository somewhere on your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/codex.el")
(require 'codex)
```

Then bind the command map to a prefix you like:

```elisp
(global-set-key (kbd "C-c d") codex-command-map)
```

## Usage

Common commands:

| Command | Description |
| --- | --- |
| `codex-menu` | Open a focused `transient` menu for common Codex commands. |
| `codex` | Start or switch to a Codex session for the current project. |
| `codex-dashboard` | Show live Codex buffers and detected Codex tmux sessions. |
| `codex-resume-last` | Run `codex resume --last` in the current project. |
| `codex-yolo` | Start Codex with approval and sandbox bypass switches. |
| `codex-send-region` | Send the active region, or the current buffer, to Codex. |
| `codex-send-command` | Send a one-line command to a selected Codex session. |
| `codex-tmux-copy-mode` | Enter tmux copy-mode for the current Codex session. |

With the example `C-c d` prefix above:

| Key | Command |
| --- | --- |
| `C-c d m` | `codex-menu` |
| `C-c d c` | `codex` |
| `C-c d d` | `codex-dashboard` |
| `C-c d R` | `codex-resume-last` |
| `C-c d u` | `codex-yolo` |
| `C-c d r` | `codex-send-region` |
| `C-c d s` | `codex-send-command` |
| `C-c d [` | `codex-tmux-copy-mode` |
| `C-c d p` | `codex-tmux-copy-mode` |

`codex-menu` loads `transient` lazily and signals a `user-error` if it is not
installed; other commands keep working without it.

Inside a Codex terminal buffer, `Shift+Enter` sends the same newline sequence as
`Ctrl+j`, which Codex CLI uses for multiline input in the composer.

## Configuration

Useful options:

```elisp
(setq codex-backend 'vterm)
(setq codex-use-tmux t)
(setq codex-display-full-frame t)
(setq codex-vterm-max-scrollback 5000)
```

Set `codex-use-tmux` to `nil` to run Codex directly in the terminal backend:

```elisp
(setq codex-use-tmux nil)
```

Extra CLI switches can be passed with `codex-program-switches`:

```elisp
(setq codex-program-switches '("--search"))
```

## Development

Run the test suite with:

```sh
emacs --batch -Q -L . -l codex-test.el -f ert-run-tests-batch-and-exit
```

Byte-compile with:

```sh
emacs --batch -Q -L . -f batch-byte-compile codex.el
```

## License

MIT
