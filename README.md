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
- Send concise Emacs buffer context without sending entire large buffers.
- Enter tmux copy-mode from Emacs without typing the tmux prefix key.
- Capture bounded tmux scrollback into a normal read-only Emacs buffer.
- Open `git diff` or Magit status for the current Codex project.
- Send Shift+Enter as a Codex CLI multiline-input newline in Codex terminal buffers.

## Requirements

- Emacs 27.1 or newer
- The official `codex` CLI
- `vterm`
- `tmux` when `codex-use-tmux` is enabled
- Optional: `eat` when `codex-backend` is set to `eat`
- Optional: `transient` for `codex-menu`
- Optional: `magit` for `codex-project-magit-status`

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
| `codex-send-context` | Send current buffer, file, directory, point, line, column, and safe active-region context. |
| `codex-send-command` | Send a one-line command to a selected Codex session. |
| `codex-tmux-copy-mode` | Enter tmux copy-mode for the current Codex session. |
| `codex-capture-transcript` | Capture bounded tmux scrollback into a read-only Emacs buffer. |
| `codex-project-diff` | Show `git diff` for the current Codex project. |
| `codex-project-magit-status` | Open Magit status for the current Codex project, or fall back to `git diff`. |

With the example `C-c d` prefix above:

| Key | Command |
| --- | --- |
| `C-c d m` | `codex-menu` |
| `C-c d c` | `codex` |
| `C-c d d` | `codex-dashboard` |
| `C-c d R` | `codex-resume-last` |
| `C-c d u` | `codex-yolo` |
| `C-c d r` | `codex-send-region` |
| `C-c d C` | `codex-send-context` |
| `C-c d s` | `codex-send-command` |
| `C-c d [` | `codex-tmux-copy-mode` |
| `C-c d p` | `codex-tmux-copy-mode` |
| `C-c d T` | `codex-capture-transcript` |
| `C-c d D` | `codex-project-diff` |
| `C-c d g` | `codex-project-magit-status` |

`codex-menu` loads `transient` lazily and signals a `user-error` if it is not
installed; other commands keep working without it.

`codex-send-context` sends a small text block describing the current Emacs
buffer and location. If the region is active, selected text is included only
when `codex-context-include-region-text` is non-nil and the region is no larger
than `codex-context-max-region-chars`.

Inside a Codex terminal buffer, `Shift+Enter` sends the same newline sequence as
`Ctrl+j`, which Codex CLI uses for multiline input in the composer.

## Configuration

Useful options:

```elisp
(setq codex-backend 'vterm)
(setq codex-use-tmux t)
(setq codex-display-full-frame t)
(setq codex-vterm-max-scrollback 5000)
(setq codex-transcript-line-limit 2000)
(setq codex-context-max-region-chars 4000)
(setq codex-context-include-region-text t)
```

Set `codex-use-tmux` to `nil` to run Codex directly in the terminal backend:

```elisp
(setq codex-use-tmux nil)
```

Extra CLI switches can be passed with `codex-program-switches`:

```elisp
(setq codex-program-switches '("--search"))
```

Transcript buffers are named with `codex-transcript-buffer-name-format`, which
receives the tmux session name as its only format argument. Git helpers use
`codex-git-program`, which defaults to `git`.

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
