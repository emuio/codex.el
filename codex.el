;;; codex.el --- Codex CLI Emacs integration -*- lexical-binding: t -*-

;; Author: emuio
;; URL: https://github.com/emuio/codex.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (vterm "0.0.2"))
;; Keywords: tools, ai
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Run the official Codex CLI inside Emacs using vterm.  Authentication is left
;; to the Codex CLI, so ChatGPT OAuth and API-key sessions stored by `codex
;; login' are reused directly.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'project)
(require 'subr-x)

(defvar eat-terminal)
(defvar eat-term-name)
(defvar eat--synchronize-scroll-function)
(declare-function eat-make "eat")
(declare-function eat-term-send-string "eat")
(declare-function vterm-mode "vterm")
(declare-function vterm-copy-mode "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-send-string "vterm")
(declare-function magit-status "magit" (&optional directory))
(defvar vterm-max-scrollback)

(defgroup codex nil
  "Codex CLI interface for Emacs."
  :group 'tools)

(defface codex-repl-face
  nil
  "Face for Codex terminal buffers."
  :group 'codex)

(defcustom codex-program "codex"
  "Program used to start Codex CLI."
  :type 'string
  :group 'codex)

(defcustom codex-git-program "git"
  "Program used to run git commands for Codex project helpers."
  :type 'string
  :group 'codex)

(defcustom codex-backend 'vterm
  "Terminal backend used for Codex buffers."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "eat" eat))
  :group 'codex)

(defcustom codex-use-tmux t
  "When non-nil, run Codex inside a named tmux session."
  :type 'boolean
  :group 'codex)

(defcustom codex-tmux-program "tmux"
  "Program used to start or attach tmux sessions."
  :type 'string
  :group 'codex)

(defcustom codex-tmux-session-prefix "codex"
  "Prefix used for tmux sessions created by codex.el."
  :type 'string
  :group 'codex)

(defcustom codex-transcript-line-limit 2000
  "Maximum number of tmux scrollback lines captured by `codex-capture-transcript'."
  :type 'integer
  :group 'codex)

(defcustom codex-transcript-buffer-name-format "*codex-transcript:%s*"
  "Format string for transcript buffer names.

The tmux session name is passed as the only format argument."
  :type 'string
  :group 'codex)

(defcustom codex-program-switches nil
  "Command line switches passed to `codex' before the working directory."
  :type '(repeat string)
  :group 'codex)

(defcustom codex-yolo-switches '("--dangerously-bypass-approvals-and-sandbox")
  "Switches used by `codex-yolo'."
  :type '(repeat string)
  :group 'codex)

(defcustom codex-check-login-before-start t
  "When non-nil, verify `codex login status' before opening a session."
  :type 'boolean
  :group 'codex)

(defcustom codex-term-name "xterm-256color"
  "Terminal type to use for Codex buffers."
  :type 'string
  :group 'codex)

(defcustom codex-startup-delay 0.1
  "Delay in seconds before displaying a newly started Codex buffer."
  :type 'number
  :group 'codex)

(defcustom codex-large-buffer-threshold 100000
  "Buffer size above which `codex-send-region' asks before sending all text."
  :type 'integer
  :group 'codex)

(defcustom codex-context-max-region-chars 4000
  "Maximum active-region characters included by `codex-send-context'."
  :type 'integer
  :group 'codex)

(defcustom codex-context-include-region-text t
  "When non-nil, `codex-send-context' can include small active-region text.

Region text is included only when the region is active and no larger than
`codex-context-max-region-chars'."
  :type 'boolean
  :group 'codex)

(defcustom codex-max-buffer-size 80000
  "Maximum number of characters retained in Codex buffers.

Set to nil to disable automatic trimming."
  :type '(choice (integer :tag "Max characters")
                 (const :tag "No limit" nil))
  :group 'codex)

(defcustom codex-buffer-trim-ratio 0.4
  "Ratio of Codex buffer text retained when trimming."
  :type 'number
  :group 'codex)

(defcustom codex-start-hook nil
  "Hook run after Codex starts."
  :type 'hook
  :group 'codex)

(defcustom codex-display-full-frame t
  "When non-nil, show Codex buffers in the full current frame."
  :type 'boolean
  :group 'codex)

(defcustom codex-vterm-max-scrollback 5000
  "Maximum vterm scrollback lines for Codex buffers."
  :type 'integer
  :group 'codex)

(defcustom codex-shift-return-sequence "\C-j"
  "Terminal sequence sent for Shift+Return in Codex terminal buffers.

Codex CLI accepts C-j as a multiline-input newline in the composer.  Emacs
receives Shift+Return as an editor key event, so codex.el translates it to that
same terminal newline."
  :type 'string
  :group 'codex)

(defcustom codex-dashboard-include-tmux-sessions t
  "When non-nil, include detected external Codex tmux sessions in dashboard."
  :type 'boolean
  :group 'codex)

(defcustom codex-tmux-codex-command-regexp
  "\\(?:\\`\\|[ /]\\)codex\\(?:[[:space:]]\\|\\'\\)"
  "Regexp used to detect Codex commands in tmux pane process trees."
  :type 'regexp
  :group 'codex)

(defvar codex--directory-buffer-map (make-hash-table :test 'equal)
  "Remember selected Codex buffers per directory.")

(defvar codex--buffer-trim-timers (make-hash-table :test 'eq)
  "Debounce timers for Codex buffer trimming.")

(defvar-local codex--session-directory nil
  "Directory associated with the current Codex buffer.")

(defvar-local codex--session-instance nil
  "Instance name associated with the current Codex buffer.")

(defvar-local codex--tmux-target-session nil
  "tmux session associated with the current Codex buffer.")

(defun codex--ensure-transient-menu ()
  "Return the transient prefix command used by `codex-menu'."
  (unless (require 'transient nil t)
    (user-error "codex-menu requires the transient package"))
  (unless (fboundp 'codex--menu)
    (eval
     '(transient-define-prefix codex--menu ()
        "Open the Codex command menu."
        [["Sessions"
          ("c" "Start" codex)
          ("d" "Dashboard" codex-dashboard)
          ("R" "Resume last" codex-resume-last)
          ("u" "Yolo" codex-yolo)]
         ["Send"
          ("r" "Region or buffer" codex-send-region)
          ("s" "Command" codex-send-command)]
         ["Buffers"
          ("b" "Switch buffer" codex-switch-to-buffer)
          ("k" "Kill" codex-kill)]
         ["Tools"
          ("l" "Login status" codex-login-status)
          ("p" "tmux copy mode" codex-tmux-copy-mode)]])))
  'codex--menu)

;;;###autoload
(defun codex-menu ()
  "Open a transient menu for common Codex commands."
  (interactive)
  (call-interactively (codex--ensure-transient-menu)))

;;;###autoload (autoload 'codex-command-map "codex")
(defvar codex-command-map nil
  "Keymap for Codex commands.")

(defun codex--define-command-map ()
  "Define Codex command bindings, refreshing an existing keymap on reload."
  (unless (keymapp codex-command-map)
    (setq codex-command-map (make-sparse-keymap)))
  (define-key codex-command-map "b" #'codex-switch-to-buffer)
  (define-key codex-command-map "C" #'codex-send-context)
  (define-key codex-command-map "c" #'codex)
  (define-key codex-command-map "d" #'codex-dashboard)
  (define-key codex-command-map "D" #'codex-project-diff)
  (define-key codex-command-map "g" #'codex-project-magit-status)
  (define-key codex-command-map "k" #'codex-kill)
  (define-key codex-command-map "l" #'codex-login-status)
  (define-key codex-command-map "m" #'codex-menu)
  (define-key codex-command-map "p" #'codex-tmux-copy-mode)
  (define-key codex-command-map "r" #'codex-send-region)
  (define-key codex-command-map "R" #'codex-resume-last)
  (define-key codex-command-map "s" #'codex-send-command)
  (define-key codex-command-map "t" #'codex-toggle)
  (define-key codex-command-map "T" #'codex-capture-transcript)
  (define-key codex-command-map "u" #'codex-yolo)
  (define-key codex-command-map "y" #'codex-send-return)
  (define-key codex-command-map "[" #'codex-tmux-copy-mode)
  codex-command-map)

(codex--define-command-map)

(defvar codex-terminal-mode-map nil
  "Keymap active in Codex terminal buffers.")

(defun codex--define-terminal-mode-map ()
  "Define Codex terminal buffer bindings, refreshing keymap on reload."
  (unless (keymapp codex-terminal-mode-map)
    (setq codex-terminal-mode-map (make-sparse-keymap)))
  (define-key codex-terminal-mode-map (kbd "S-<return>")
              #'codex-send-shift-return)
  (define-key codex-terminal-mode-map (kbd "S-RET")
              #'codex-send-shift-return)
  (define-key codex-terminal-mode-map (kbd "S-<kp-enter>")
              #'codex-send-shift-return)
  (define-key codex-terminal-mode-map (kbd "<S-kp-enter>")
              #'codex-send-shift-return)
  (define-key codex-terminal-mode-map (kbd "C-c C-t")
              #'codex-copy-mode)
  codex-terminal-mode-map)

(codex--define-terminal-mode-map)

(define-minor-mode codex-terminal-mode
  "Minor mode for Codex terminal buffer key translations."
  :lighter nil
  :keymap codex-terminal-mode-map)

(defun codex--normalize-directory (directory)
  "Return DIRECTORY as an expanded directory name."
  (file-name-as-directory (expand-file-name directory)))

(defun codex--directory ()
  "Return the Codex working directory for the current buffer."
  (codex--normalize-directory
   (cond
    ((project-current) (project-root (project-current)))
    ((buffer-file-name) (file-name-directory buffer-file-name))
    (t default-directory))))

(defun codex--buffer-name (directory &optional instance-name)
  "Return a Codex buffer name for DIRECTORY and optional INSTANCE-NAME."
  (let ((dir (codex--normalize-directory directory)))
    (if (and instance-name (not (string-empty-p instance-name)))
        (format "*codex:%s:%s*" dir instance-name)
      (format "*codex:%s*" dir))))

(defun codex--extract-directory-from-buffer-name (buffer-name)
  "Extract the directory path from Codex BUFFER-NAME."
  (when (string-match "^\\*codex:\\([^:]+\\)\\(?::\\([^*]+\\)\\)?\\*$" buffer-name)
    (match-string 1 buffer-name)))

(defun codex--extract-instance-name-from-buffer-name (buffer-name)
  "Extract the instance name from Codex BUFFER-NAME."
  (when (string-match "^\\*codex:\\([^:]+\\)\\(?::\\([^*]+\\)\\)?\\*$" buffer-name)
    (match-string 2 buffer-name)))

(defun codex--external-tmux-buffer-name (session)
  "Return the buffer name used to attach external tmux SESSION."
  (format "*codex-tmux:%s*" session))

(defun codex--extract-tmux-session-from-buffer-name (buffer-name)
  "Extract the external tmux session from Codex BUFFER-NAME."
  (when (string-match "^\\*codex-tmux:\\([^*]+\\)\\*$" buffer-name)
    (match-string 1 buffer-name)))

(defun codex--command-switches (directory mode)
  "Build Codex CLI switches for DIRECTORY and MODE.

MODE may be nil, `:yolo', or `:resume-last'."
  (append
   (when (eq mode :resume-last)
     '("resume" "--last"))
   codex-program-switches
   (when (eq mode :yolo)
     codex-yolo-switches)
   (list "--cd" (codex--normalize-directory directory))))

(defun codex--vterm-command-string (directory mode)
  "Build the shell command used to start Codex in vterm."
  (mapconcat #'shell-quote-argument
             (cons codex-program (codex--command-switches directory mode))
             " "))

(defun codex--sanitize-tmux-session-part (value)
  "Return VALUE as a tmux-session-safe string fragment."
  (let* ((sanitized (replace-regexp-in-string
                     "-+" "-"
                     (replace-regexp-in-string
                      "[^A-Za-z0-9_-]+" "-"
                      (string-trim value))))
         (trimmed (string-trim sanitized "-+" "-+")))
    (unless (string-empty-p trimmed)
      trimmed)))

(defun codex--tmux-session-name (directory &optional instance-name)
  "Return the tmux session name for DIRECTORY and INSTANCE-NAME."
  (let* ((dir (codex--normalize-directory directory))
         (prefix (or (codex--sanitize-tmux-session-part
                      codex-tmux-session-prefix)
                     "codex"))
         (project (or (codex--sanitize-tmux-session-part
                       (file-name-nondirectory (directory-file-name dir)))
                      "project"))
         (instance (and instance-name
                        (not (string-empty-p instance-name))
                        (codex--sanitize-tmux-session-part instance-name)))
         (hash (substring (secure-hash 'sha1 dir) 0 8)))
    (string-join
     (delq nil (list prefix project instance hash))
     "-")))

(defun codex--tmux-command-string (directory mode &optional instance-name)
  "Build the shell command used to attach or create a Codex tmux session."
  (mapconcat #'shell-quote-argument
             (list codex-tmux-program
                   "new-session"
                   "-A"
                   "-s"
                   (codex--tmux-session-name directory instance-name)
                   "-c"
                   (codex--normalize-directory directory)
                   (codex--vterm-command-string directory mode))
             " "))

(defun codex--tmux-copy-mode-args (directory &optional instance-name)
  "Return tmux arguments for entering copy-mode.

DIRECTORY and INSTANCE-NAME identify the Codex tmux session."
  (list "copy-mode"
        "-t"
        (codex--tmux-session-name directory instance-name)))

(defun codex--tmux-copy-mode-target-args (session)
  "Return tmux arguments for entering copy-mode in SESSION."
  (list "copy-mode" "-t" session))

(defun codex--tmux-capture-pane-args (session line-limit)
  "Return tmux arguments to capture SESSION scrollback.

LINE-LIMIT bounds how far back tmux reads from the pane history."
  (list "capture-pane"
        "-p"
        "-J"
        "-S"
        (format "-%d" (max 1 (or line-limit 1)))
        "-t"
        session))

(defun codex--tmux-attach-command-string (session)
  "Build the shell command used to attach tmux SESSION."
  (mapconcat #'shell-quote-argument
             (list codex-tmux-program "attach-session" "-t" session)
             " "))

(defconst codex--tmux-pane-format
  (mapconcat #'identity
             '("#{session_name}"
               "#{window_index}"
               "#{pane_index}"
               "#{pane_id}"
               "#{pane_pid}"
               "#{pane_current_command}"
               "#{pane_current_path}"
               "#{pane_active}"
               "#{pane_title}")
             "\t")
  "tmux format used by `codex--tmux-list-panes'.")

(defun codex--parse-tmux-pane-line (line)
  "Parse one tmux list-panes LINE into a plist."
  (let ((fields (split-string line "\t" nil)))
    (when (>= (length fields) 9)
      (list :session (nth 0 fields)
            :window (nth 1 fields)
            :pane (nth 2 fields)
            :pane-id (nth 3 fields)
            :pid (nth 4 fields)
            :command (nth 5 fields)
            :directory (nth 6 fields)
            :active (string= (nth 7 fields) "1")
            :title (nth 8 fields)))))

(defun codex--parse-process-line (line)
  "Parse one ps LINE into a plist."
  (when (string-match
         "\\`[[:space:]]*\\([0-9]+\\)[[:space:]]+\\([0-9]+\\)[[:space:]]+\\(.*\\)\\'"
         line)
    (list :pid (match-string 1 line)
          :ppid (match-string 2 line)
          :command (match-string 3 line))))

(defun codex--process-tree-has-command-p (root-pid processes regexp)
  "Return non-nil when ROOT-PID or its descendants match REGEXP.

PROCESSES is a list of plists with :pid, :ppid, and :command."
  (let ((queue (list (format "%s" root-pid)))
        seen
        found)
    (while (and queue (not found))
      (let ((pid (pop queue)))
        (unless (member pid seen)
          (push pid seen)
          (let ((process (cl-find pid processes
                                  :key (lambda (entry)
                                         (plist-get entry :pid))
                                  :test #'string=)))
            (when (and process
                       (string-match-p regexp
                                       (or (plist-get process :command) "")))
              (setq found t))
            (dolist (child processes)
              (when (string= pid (or (plist-get child :ppid) ""))
                (push (plist-get child :pid) queue)))))))
    found))

(defun codex--tmux-session-prefix-p (session)
  "Return non-nil when SESSION looks like a codex.el-created tmux session."
  (let ((prefix (or (codex--sanitize-tmux-session-part
                     codex-tmux-session-prefix)
                    "codex")))
    (string-prefix-p prefix session)))

(defun codex--tmux-pane-codex-p (pane processes)
  "Return non-nil when PANE appears to be running Codex.

PROCESSES should be the output of `codex--list-processes'."
  (let ((session (or (plist-get pane :session) ""))
        (command (or (plist-get pane :command) ""))
        (pid (plist-get pane :pid)))
    (or (codex--tmux-session-prefix-p session)
        (string-match-p codex-tmux-codex-command-regexp command)
        (and pid
             (codex--process-tree-has-command-p
              pid processes codex-tmux-codex-command-regexp)))))

(defun codex--process-file-lines (program &rest args)
  "Return PROGRAM output lines for ARGS, or nil when the command fails."
  (when (or (file-executable-p program) (executable-find program))
    (with-temp-buffer
      (let ((exit-code (apply #'process-file program nil t nil args)))
        (when (and (integerp exit-code) (zerop exit-code))
          (split-string (buffer-string) "\n" t))))))

(defun codex--tmux-list-panes ()
  "Return all tmux panes as plists."
  (mapcar #'codex--parse-tmux-pane-line
          (codex--process-file-lines codex-tmux-program
                                     "list-panes" "-a" "-F"
                                     codex--tmux-pane-format)))

(defun codex--list-processes ()
  "Return local process table entries as plists."
  (mapcar #'codex--parse-process-line
          (codex--process-file-lines "/bin/ps"
                                     "-axo" "pid=,ppid=,command=")))

(defun codex--tmux-codex-panes ()
  "Return one detected Codex pane per tmux session."
  (when (and codex-use-tmux codex-dashboard-include-tmux-sessions)
    (let ((processes (delq nil (codex--list-processes)))
          seen
          result)
      (dolist (pane (delq nil (codex--tmux-list-panes)))
        (let ((session (plist-get pane :session)))
          (when (and session
                     (not (member session seen))
                     (codex--tmux-pane-codex-p pane processes))
            (push session seen)
            (push pane result))))
      (nreverse result))))

(defun codex--tmux-pane-for-session (session)
  "Return the detected tmux pane for SESSION, if any."
  (cl-find session
           (codex--tmux-codex-panes)
           :key (lambda (pane)
                  (plist-get pane :session))
           :test #'string=))

(defun codex--same-directory-p (left right)
  "Return non-nil when LEFT and RIGHT name the same directory."
  (and left
       right
       (string= (file-truename (codex--normalize-directory left))
                (file-truename (codex--normalize-directory right)))))

(defun codex--tmux-pane-for-directory (directory)
  "Return the detected tmux pane for DIRECTORY, if any."
  (cl-find-if
   (lambda (pane)
     (codex--same-directory-p directory (plist-get pane :directory)))
   (codex--tmux-codex-panes)))

(defun codex--tmux-session-live-p (session)
  "Return non-nil when tmux SESSION exists."
  (and session
       (let ((exit-code (process-file codex-tmux-program
                                      nil nil nil
                                      "has-session" "-t" session)))
         (and (integerp exit-code) (zerop exit-code)))))

(defun codex--vterm-entry-command-string (directory mode &optional instance-name)
  "Build the command sent to vterm for DIRECTORY, MODE, and INSTANCE-NAME."
  (if codex-use-tmux
      (codex--tmux-command-string directory mode instance-name)
    (codex--vterm-command-string directory mode)))

(defun codex--ensure-program ()
  "Signal a user error unless `codex-program' is executable."
  (unless (or (file-executable-p codex-program)
              (executable-find codex-program))
    (user-error "Cannot find Codex CLI executable: %s" codex-program)))

(defun codex--login-status-output ()
  "Return output from `codex login status'."
  (with-temp-buffer
    (let ((exit-code (process-file codex-program nil t nil "login" "status")))
      (cons exit-code (buffer-string)))))

(defun codex--logged-in-status-p (status-output)
  "Return non-nil when STATUS-OUTPUT indicates Codex is logged in."
  (let ((case-fold-search nil))
    (string-match-p "\\`[[:space:]\n\r]*Logged in\\b" status-output)))

(defun codex--logged-in-p ()
  "Return non-nil when Codex CLI reports a valid login."
  (pcase-let ((`(,exit-code . ,output) (codex--login-status-output)))
    (and (integerp exit-code)
         (zerop exit-code)
         (codex--logged-in-status-p output))))

(defun codex--ensure-login ()
  "Signal a user error unless Codex CLI is logged in."
  (when codex-check-login-before-start
    (unless (codex--logged-in-p)
      (user-error "Codex is not logged in. Run `codex login' in a terminal"))))

(defun codex--ensure-eat ()
  "Signal a user error unless eat is available."
  (unless (require 'eat nil t)
    (user-error "Package `eat' is required for codex.el")))

(defun codex--ensure-vterm ()
  "Signal a user error unless vterm is available."
  (unless (require 'vterm nil t)
    (user-error "Package `vterm' is required for codex.el")))

(defun codex--ensure-tmux-program ()
  "Signal a user error unless tmux is available."
  (unless (or (file-executable-p codex-tmux-program)
              (executable-find codex-tmux-program))
    (user-error "Cannot find tmux executable: %s" codex-tmux-program)))

(defun codex--ensure-tmux ()
  "Signal a user error unless tmux is available."
  (when codex-use-tmux
    (codex--ensure-tmux-program)))

(defun codex--ensure-git ()
  "Signal a user error unless git is available."
  (unless (or (file-executable-p codex-git-program)
              (executable-find codex-git-program))
    (user-error "Cannot find git executable: %s" codex-git-program)))

(defun codex--codex-buffer-p (buffer)
  "Return non-nil when BUFFER is a Codex buffer."
  (or (string-match-p "^\\*codex:" (buffer-name buffer))
      (string-match-p "^\\*codex-tmux:" (buffer-name buffer))))

(defun codex--buffer-directory (buffer)
  "Return the directory associated with Codex BUFFER."
  (with-current-buffer buffer
    (or codex--session-directory
        (codex--extract-directory-from-buffer-name (buffer-name buffer))
        (when-let* ((session (codex--extract-tmux-session-from-buffer-name
                              (buffer-name buffer)))
                    (pane (codex--tmux-pane-for-session session)))
          (plist-get pane :directory)))))

(defun codex--buffer-instance-name (buffer)
  "Return the instance name associated with Codex BUFFER."
  (with-current-buffer buffer
    (or codex--session-instance
        (codex--extract-instance-name-from-buffer-name (buffer-name buffer))
        (codex--extract-tmux-session-from-buffer-name (buffer-name buffer)))))

(defun codex--buffer-tmux-session (buffer)
  "Return the tmux session associated with Codex BUFFER, if any."
  (with-current-buffer buffer
    (let* ((directory (codex--buffer-directory buffer))
           (candidates
            (delq nil
                  (list codex--tmux-target-session
                        (codex--extract-tmux-session-from-buffer-name
                         (buffer-name buffer))
                        (when directory
                          (codex--tmux-session-name
                           directory
                           (codex--buffer-instance-name buffer))))))
           (live-session (cl-find-if #'codex--tmux-session-live-p candidates))
           (detected-pane (and directory
                               (codex--tmux-pane-for-directory directory))))
      (or live-session
          (plist-get detected-pane :session)))))

(defun codex--current-project-directory ()
  "Return the project directory for the current Codex context."
  (codex--normalize-directory
   (or (and (codex--codex-buffer-p (current-buffer))
            (codex--buffer-directory (current-buffer)))
       (codex--directory))))

(defun codex--tmux-session-entry-for-buffer (buffer)
  "Return a tmux session entry for Codex BUFFER, if it has one."
  (when-let ((session (codex--buffer-tmux-session buffer)))
    (list :session session
          :directory (codex--buffer-directory buffer)
          :buffer buffer)))

(defun codex--current-tmux-session-entry ()
  "Return the tmux session entry for the current Codex buffer."
  (when (codex--codex-buffer-p (current-buffer))
    (codex--tmux-session-entry-for-buffer (current-buffer))))

(defun codex--tmux-session-entries ()
  "Return detected Codex tmux sessions as completion entries."
  (let (seen result)
    (cl-labels
        ((add-entry
          (entry)
          (let ((session (plist-get entry :session)))
            (when (and session (not (member session seen)))
              (push session seen)
              (push entry result)))))
      (dolist (buffer (codex--find-all-codex-buffers))
        (when-let ((entry (codex--tmux-session-entry-for-buffer buffer)))
          (add-entry entry)))
      (dolist (pane (codex--tmux-codex-panes))
        (add-entry (list :session (plist-get pane :session)
                         :directory (plist-get pane :directory)
                         :pane-id (plist-get pane :pane-id)))))
    (nreverse result)))

(defun codex--format-tmux-session-entry (entry)
  "Return a completion label for tmux session ENTRY."
  (let* ((session (plist-get entry :session))
         (directory (plist-get entry :directory))
         (project-name (if directory
                           (file-name-nondirectory
                            (directory-file-name directory))
                         "Unknown")))
    (format "%s (%s) %s"
            session
            project-name
            (abbreviate-file-name (or directory "")))))

(defun codex--read-tmux-session-entry ()
  "Prompt for a detected Codex tmux session entry."
  (let ((entries (codex--tmux-session-entries)))
    (unless entries
      (user-error "No Codex tmux session found"))
    (let* ((choices (mapcar (lambda (entry)
                              (cons (codex--format-tmux-session-entry entry)
                                    entry))
                            entries))
           (selection (completing-read "Codex tmux session: "
                                       (mapcar #'car choices)
                                       nil t)))
      (cdr (assoc selection choices)))))

(defun codex--select-tmux-session-entry (&optional force-prompt)
  "Return a tmux session entry, prompting when FORCE-PROMPT is non-nil."
  (or (and (not force-prompt)
           (codex--current-tmux-session-entry))
      (codex--read-tmux-session-entry)))

(defun codex--transcript-buffer-name (session)
  "Return the transcript buffer name for tmux SESSION."
  (format codex-transcript-buffer-name-format session))

(defun codex--tmux-capture-pane-output (session line-limit)
  "Return captured tmux scrollback text for SESSION and LINE-LIMIT."
  (with-temp-buffer
    (let ((exit-code (apply #'process-file
                            codex-tmux-program
                            nil t nil
                            (codex--tmux-capture-pane-args
                             session line-limit))))
      (unless (and (integerp exit-code) (zerop exit-code))
        (user-error "tmux capture-pane failed for %s: %s"
                    session
                    (string-trim (buffer-string))))
      (buffer-string))))

(defun codex--transcript-buffer (session directory text line-limit)
  "Return a read-only transcript buffer for SESSION containing TEXT.

DIRECTORY and LINE-LIMIT are shown as capture metadata."
  (let ((buffer (get-buffer-create (codex--transcript-buffer-name session))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Codex tmux transcript\n" 'face 'header-line))
        (insert (format "Session: %s\n" session))
        (when directory
          (insert (format "Directory: %s\n" directory)))
        (insert (format "Line limit: %d\n" (max 1 (or line-limit 1))))
        (insert (format "Captured: %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S %z")))
        (insert text)
        (unless (bolp)
          (insert "\n"))
        (goto-char (point-min))
        (special-mode)
        (setq buffer-read-only t)))
    buffer))

(defun codex--git-diff-args (directory)
  "Return git arguments for showing DIRECTORY diff."
  (list "-C" (codex--normalize-directory directory) "diff" "--no-color"))

(defun codex--git-diff-buffer-name (directory)
  "Return the git diff buffer name for DIRECTORY."
  (format "*codex-diff:%s*" (codex--normalize-directory directory)))

(defun codex--git-diff-output (directory)
  "Return `git diff' output for DIRECTORY."
  (codex--ensure-git)
  (with-temp-buffer
    (let ((exit-code (apply #'process-file
                            codex-git-program
                            nil t nil
                            (codex--git-diff-args directory))))
      (unless (and (integerp exit-code) (zerop exit-code))
        (user-error "git diff failed in %s: %s"
                    (codex--normalize-directory directory)
                    (string-trim (buffer-string))))
      (buffer-string))))

(defun codex--git-diff-buffer (directory)
  "Return a read-only `git diff' buffer for DIRECTORY."
  (let* ((dir (codex--normalize-directory directory))
         (output (codex--git-diff-output dir))
         (buffer (get-buffer-create (codex--git-diff-buffer-name dir))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (if (string-empty-p output)
                    "No differences.\n"
                  output))
        (goto-char (point-min))
        (diff-mode)
        (setq buffer-read-only t)))
    buffer))

(defun codex--find-all-codex-buffers ()
  "Return all live Codex buffers."
  (cl-remove-if-not #'codex--codex-buffer-p (buffer-list)))

(defun codex--find-codex-buffers-for-directory (directory)
  "Return live Codex buffers associated with DIRECTORY."
  (let ((target (file-truename (codex--normalize-directory directory))))
    (cl-remove-if-not
     (lambda (buffer)
       (when-let ((dir (codex--buffer-directory buffer)))
         (string= target (file-truename (codex--normalize-directory dir)))))
     (codex--find-all-codex-buffers))))

(defun codex--select-buffer-from-choices (prompt buffers &optional simple-format)
  "Prompt with PROMPT to select from BUFFERS.

When SIMPLE-FORMAT is non-nil, show just the instance name."
  (when buffers
    (let* ((choices
            (mapcar
             (lambda (buffer)
               (let* ((name (buffer-name buffer))
                      (dir (codex--buffer-directory buffer))
                      (instance (codex--buffer-instance-name buffer))
                      (display (if simple-format
                                   (or instance "default")
                                 (if dir
                                     (format "%s%s (%s)"
                                             (file-name-nondirectory
                                              (directory-file-name dir))
                                             (if instance
                                                 (format ":%s" instance)
                                               "")
                                             dir)
                                   name))))
                 (cons display buffer)))
             buffers))
           (selection (completing-read prompt (mapcar #'car choices) nil t)))
      (cdr (assoc selection choices)))))

(defun codex--get-or-prompt-for-buffer ()
  "Return a Codex buffer for the current directory or prompt for one."
  (let* ((directory (codex--directory))
         (directory-buffers (codex--find-codex-buffers-for-directory directory)))
    (cond
     ((= (length directory-buffers) 1)
      (car directory-buffers))
     ((> (length directory-buffers) 1)
      (codex--select-buffer-from-choices
       (format "Select Codex instance for %s: "
               (abbreviate-file-name directory))
       directory-buffers
       t))
     (t
      (let ((remembered-buffer (gethash directory codex--directory-buffer-map)))
        (if (and remembered-buffer (buffer-live-p remembered-buffer))
            remembered-buffer
          (codex--select-buffer-from-choices
           "No Codex instance in this directory. Select another instance: "
           (codex--find-all-codex-buffers))))))))

(defun codex--cleanup-directory-mapping ()
  "Remove the current buffer from remembered directory mappings."
  (let ((dying-buffer (current-buffer)))
    (maphash (lambda (directory buffer)
               (when (eq buffer dying-buffer)
                 (remhash directory codex--directory-buffer-map)))
             codex--directory-buffer-map)))

(defun codex--schedule-buffer-trim ()
  "Schedule trim for the current Codex buffer."
  (when codex-max-buffer-size
    (let ((buffer (current-buffer)))
      (when-let ((timer (gethash buffer codex--buffer-trim-timers)))
        (cancel-timer timer))
      (puthash
       buffer
       (run-with-idle-timer
        0.5 nil
        (lambda (target)
          (when (buffer-live-p target)
            (with-current-buffer target
              (codex--trim-buffer))))
        buffer)
       codex--buffer-trim-timers))))

(defun codex--trim-buffer ()
  "Trim the current buffer if it exceeds `codex-max-buffer-size'."
  (when (and codex-max-buffer-size
             (> (buffer-size) codex-max-buffer-size))
    (let* ((keep-size (max 1 (floor (* codex-max-buffer-size codex-buffer-trim-ratio))))
           (delete-end (max (point-min) (- (point-max) keep-size)))
           (inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (delete-region (point-min) delete-end)
        (insert (propertize "[older Codex output trimmed]\n" 'face 'shadow))))))

(defun codex--on-buffer-change (_beg _end _len)
  "Handle Codex buffer changes."
  (codex--schedule-buffer-trim))

(defun codex--setup-repl-faces ()
  "Apply Codex REPL faces in the current buffer."
  (buffer-face-set :inherit 'codex-repl-face)
  (codex-terminal-mode 1)
  (when (fboundp 'face-remap-add-relative)
    (face-remap-add-relative 'nobreak-space :underline nil)))

(defun codex--start-vterm-command-in-buffer (directory command)
  "Start COMMAND in the current buffer using vterm.

DIRECTORY becomes the buffer working directory."
  (codex--ensure-vterm)
  (cd directory)
  (setq-local vterm-max-scrollback codex-vterm-max-scrollback)
  (unless (derived-mode-p 'vterm-mode)
    (vterm-mode))
  (when-let ((process (get-buffer-process (current-buffer))))
    (accept-process-output process 0.1))
  (vterm-send-string "clear")
  (vterm-send-return)
  (vterm-send-string command)
  (vterm-send-return))

(defun codex--start-vterm-in-buffer (directory mode &optional instance-name)
  "Start Codex in the current buffer using vterm.

DIRECTORY is the working directory.  MODE is passed to
`codex--command-switches'."
  (when codex-use-tmux
    (codex--ensure-tmux))
  (codex--start-vterm-command-in-buffer
   directory
   (codex--vterm-entry-command-string directory mode instance-name)))

(defun codex--start-eat-in-buffer (buffer-name directory mode)
  "Start Codex in the current buffer using eat.

BUFFER-NAME is the display name passed to `eat-make'.  DIRECTORY is the
working directory.  MODE is passed to `codex--command-switches'."
  (codex--ensure-eat)
  (cd directory)
  (setq-local eat-term-name codex-term-name)
  (when (boundp 'eat-enable-directory-tracking)
    (setq-local eat-enable-directory-tracking t))
  (when (boundp 'eat-enable-shell-command-history)
    (setq-local eat-enable-shell-command-history nil))
  (when (boundp 'eat-enable-shell-prompt-annotation)
    (setq-local eat-enable-shell-prompt-annotation nil))
  (let ((process-adaptive-read-buffering nil))
    (condition-case err
        (apply #'eat-make
               buffer-name
               codex-program
               nil
               (codex--command-switches directory mode))
      (error
       (signal 'codex-start-error (list (error-message-string err)))))))

(defun codex--start-session (directory mode &optional instance-name)
  "Start a Codex session in DIRECTORY with MODE and INSTANCE-NAME."
  (codex--ensure-program)
  (codex--ensure-login)
  (let* ((dir (codex--normalize-directory directory))
         (buffer-name (codex--buffer-name dir instance-name))
         (trimmed-buffer-name (string-trim-right (string-trim buffer-name "\\*") "\\*"))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (setq-local codex--session-directory dir)
      (setq-local codex--session-instance instance-name)
      (setq-local codex--tmux-target-session
                  (when codex-use-tmux
                    (codex--tmux-session-name dir instance-name)))
      (pcase codex-backend
        ('vterm (codex--start-vterm-in-buffer dir mode instance-name))
        ('eat (codex--start-eat-in-buffer trimmed-buffer-name dir mode))
        (_ (user-error "Unsupported Codex backend: %S" codex-backend)))
      (codex--setup-repl-faces)
      (add-hook 'after-change-functions #'codex--on-buffer-change nil t)
      (add-hook 'kill-buffer-hook #'codex--cleanup-directory-mapping nil t)
      (sleep-for codex-startup-delay)
      (puthash dir buffer codex--directory-buffer-map)
      (run-hooks 'codex-start-hook))
	    buffer))

(defun codex--attach-external-tmux-session (session directory)
  "Attach external tmux SESSION in a Codex vterm buffer.

DIRECTORY is used as the buffer working directory."
  (codex--ensure-tmux)
  (let* ((dir (codex--normalize-directory directory))
         (buffer-name (codex--external-tmux-buffer-name session))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (setq-local codex--session-directory dir)
      (setq-local codex--session-instance session)
      (setq-local codex--tmux-target-session session)
      (codex--start-vterm-command-in-buffer
       dir
       (codex--tmux-attach-command-string session))
      (codex--setup-repl-faces)
      (add-hook 'after-change-functions #'codex--on-buffer-change nil t)
      (add-hook 'kill-buffer-hook #'codex--cleanup-directory-mapping nil t)
      (puthash dir buffer codex--directory-buffer-map))
    buffer))

(defun codex--get-or-start-session (directory mode &optional instance-name)
  "Return an existing Codex session or start one.

DIRECTORY, MODE, and INSTANCE-NAME are passed to `codex--start-session'."
  (let ((buffer (and (not mode)
                     (get-buffer (codex--buffer-name directory instance-name)))))
    (if (and buffer (buffer-live-p buffer))
        buffer
      (codex--start-session directory mode instance-name))))

(defun codex--show-not-running-message ()
  "Display a message when no Codex session is available."
  (message "No Codex session running"))

(defun codex--display-buffer (buffer)
  "Display Codex BUFFER according to `codex-display-full-frame'."
  (if codex-display-full-frame
      (progn
        (switch-to-buffer buffer)
        (delete-other-windows)
        (selected-window))
    (display-buffer buffer)))

(defun codex--terminal-send-string (string)
  "Send STRING and RET to the terminal in the current Codex buffer."
  (cond
   ((derived-mode-p 'vterm-mode)
    (vterm-send-string string t)
    (vterm-send-return))
   ((bound-and-true-p eat-terminal)
    (eat-term-send-string eat-terminal string)
    (eat-term-send-string eat-terminal (kbd "RET")))
   (t
    (user-error "Current Codex buffer is not backed by vterm or eat"))))

(defun codex--context-region-lines ()
  "Return formatted active-region context lines for the current buffer."
  (when (use-region-p)
    (let* ((beg (region-beginning))
           (end (region-end))
           (length (- end beg)))
      (when (<= length codex-context-max-region-chars)
        (let ((lines (list (format "- Region: %d-%d (%d chars)"
                                   beg end length))))
          (if codex-context-include-region-text
              (let* ((text (buffer-substring-no-properties beg end))
                     (fence (if (string-match-p "```" text) "````" "```")))
                (append lines
                        (list "Selected text:"
                              (concat fence "text")
                              text
                              fence)))
            lines))))))

(defun codex--format-context ()
  "Return a concise context block for the current Emacs buffer."
  (string-join
   (append
    (list "Emacs context:"
          (format "- Buffer: %s" (buffer-name))
          (format "- File: %s" (or buffer-file-name "none"))
          (format "- Project/default directory: %s" (codex--directory))
          (format "- Point: %d" (point))
          (format "- Line: %d" (line-number-at-pos))
          (format "- Column: %d" (current-column)))
    (codex--context-region-lines))
   "\n"))

;;;###autoload
(defun codex-send-shift-return ()
  "Send Shift+Return to the current Codex terminal buffer."
  (interactive)
  (cond
   ((derived-mode-p 'vterm-mode)
    (vterm-send-string codex-shift-return-sequence))
   ((bound-and-true-p eat-terminal)
    (eat-term-send-string eat-terminal codex-shift-return-sequence))
   (t
    (user-error "Current Codex buffer is not backed by vterm or eat"))))

(defun codex--send-command (command)
  "Send COMMAND to a selected Codex terminal buffer."
  (if-let ((buffer (codex--get-or-prompt-for-buffer)))
      (progn
        (with-current-buffer buffer
          (codex--terminal-send-string command)
          (codex--display-buffer buffer))
        buffer)
    (codex--show-not-running-message)
    nil))

;;;###autoload
(defun codex (&optional arg)
  "Start or switch to a Codex session for the current directory.

With prefix ARG, prompt for an instance name."
  (interactive "P")
  (let* ((directory (codex--directory))
         (instance-name (when arg
                          (read-string "Codex instance name: ")))
         (buffer (codex--get-or-start-session directory nil instance-name)))
    (codex--display-buffer buffer)
    buffer))

;;;###autoload
(defun codex-yolo (&optional arg)
  "Start a Codex session with approvals and sandbox bypassed.

With prefix ARG, prompt for an instance name."
  (interactive "P")
  (let* ((directory (codex--directory))
         (instance-name (or (when arg
                              (read-string "Codex yolo instance name: "))
                            "yolo"))
         (buffer (codex--start-session directory :yolo instance-name)))
    (codex--display-buffer buffer)
    buffer))

;;;###autoload
(defun codex-resume-last (&optional arg)
  "Resume the latest Codex session for the current directory.

With prefix ARG, prompt for an instance name."
  (interactive "P")
  (let* ((directory (codex--directory))
         (instance-name (or (when arg
                              (read-string "Codex resume instance name: "))
                            "resume"))
         (buffer (codex--start-session directory :resume-last instance-name)))
    (codex--display-buffer buffer)
    buffer))

;;;###autoload
(defun codex-toggle ()
  "Show, hide, or start the Codex buffer for the current directory."
  (interactive)
  (let ((buffer (or (codex--get-or-prompt-for-buffer)
                    (codex--get-or-start-session (codex--directory) nil))))
    (if-let ((window (get-buffer-window buffer)))
        (delete-window window)
      (codex--display-buffer buffer))))

;;;###autoload
(defun codex-switch-to-buffer (&optional arg)
  "Switch to a Codex buffer.

With prefix ARG, select from all Codex buffers."
  (interactive "P")
  (let ((buffer (if arg
                    (codex--select-buffer-from-choices
                     "Select Codex instance: "
                     (codex--find-all-codex-buffers))
                  (codex--get-or-prompt-for-buffer))))
    (if buffer
        (switch-to-buffer buffer)
      (codex--show-not-running-message))))

;;;###autoload
(defun codex-kill (&optional arg)
  "Kill Codex buffer and process.

With prefix ARG, kill all Codex buffers."
  (interactive "P")
  (let ((buffers (if arg
                     (codex--find-all-codex-buffers)
                   (let ((buffer (codex--get-or-prompt-for-buffer)))
                     (when buffer (list buffer))))))
    (if buffers
        (when (yes-or-no-p
               (format "Kill %d Codex instance%s? "
                       (length buffers)
                       (if (= (length buffers) 1) "" "s")))
          (dolist (buffer buffers)
            (when (buffer-live-p buffer)
              (kill-buffer buffer))))
      (codex--show-not-running-message))))

;;;###autoload
(defun codex-send-command (command &optional arg)
  "Read and send COMMAND to Codex.

With prefix ARG, switch to the Codex buffer after sending."
  (interactive "sCodex command: \nP")
  (let ((buffer (codex--send-command command)))
    (when (and arg buffer)
      (switch-to-buffer buffer))))

;;;###autoload
(defun codex-send-context ()
  "Send concise Emacs buffer context to a selected Codex session."
  (interactive)
  (codex--send-command (codex--format-context)))

;;;###autoload
(defun codex-send-region (&optional arg)
  "Send the region or current buffer to Codex.

With prefix ARG, prompt for instructions to prepend."
  (interactive "P")
  (let* ((text (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (when (or (<= (buffer-size) codex-large-buffer-threshold)
                           (yes-or-no-p "Buffer is large. Send anyway? "))
                   (buffer-substring-no-properties (point-min) (point-max)))))
         (prompt (when arg
                   (read-string "Instructions for Codex: ")))
         (full-text (cond
                     ((and prompt text) (format "%s\n\n%s" prompt text))
                     (text text))))
    (when full-text
      (codex--send-command full-text))))

;;;###autoload
(defun codex-send-return ()
  "Send RET to Codex."
  (interactive)
  (codex--send-command ""))

;;;###autoload
(defun codex-copy-mode ()
  "Enter the best copy mode for the current Codex terminal buffer."
  (interactive)
  (if (and codex-use-tmux
           (codex--codex-buffer-p (current-buffer))
           (codex--buffer-tmux-session (current-buffer)))
      (codex-tmux-copy-mode)
    (cond
     ((derived-mode-p 'vterm-mode)
      (vterm-copy-mode))
     ((bound-and-true-p eat-terminal)
      (user-error "No tmux session found; use the terminal backend copy mode"))
     (t
      (user-error "Current buffer is not a Codex terminal buffer")))))

;;;###autoload
(defun codex-tmux-copy-mode ()
  "Enter tmux copy-mode for the current Codex session.

This bypasses terminal prefix keys, which is useful when an input method
intercepts `C-b ['."
  (interactive)
  (unless codex-use-tmux
    (user-error "Codex tmux mode is disabled"))
  (codex--ensure-tmux)
  (let* ((buffer (or (and (codex--codex-buffer-p (current-buffer))
                          (current-buffer))
                     (codex--get-or-prompt-for-buffer)))
         (target-session (and buffer
                              (codex--buffer-tmux-session buffer))))
    (unless target-session
      (user-error "No Codex tmux session found"))
    (let ((exit-code (apply #'process-file
                            codex-tmux-program
                            nil nil nil
                            (codex--tmux-copy-mode-target-args
                             target-session))))
      (unless (and (integerp exit-code) (zerop exit-code))
        (user-error "tmux copy-mode failed for %s"
                    target-session)))
    (when buffer
      (codex--display-buffer buffer))))

;;;###autoload
(defun codex-capture-transcript (&optional arg)
  "Capture bounded tmux scrollback for a Codex session.

The captured transcript is shown in a read-only Emacs buffer, not in a
terminal buffer.  With prefix ARG, always prompt for a detected Codex tmux
session instead of using the current Codex buffer."
  (interactive "P")
  (codex--ensure-tmux-program)
  (let* ((entry (codex--select-tmux-session-entry arg))
         (session (plist-get entry :session))
         (directory (plist-get entry :directory))
         (output (codex--tmux-capture-pane-output
                  session codex-transcript-line-limit))
         (buffer (codex--transcript-buffer
                  session directory output codex-transcript-line-limit)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun codex-project-diff ()
  "Show `git diff' for the current Codex project."
  (interactive)
  (pop-to-buffer
   (codex--git-diff-buffer (codex--current-project-directory))))

;;;###autoload
(defun codex-project-magit-status ()
  "Open Magit status for the current Codex project.

When Magit is not available, show `git diff' for the project instead."
  (interactive)
  (let ((directory (codex--current-project-directory)))
    (if (require 'magit nil t)
        (magit-status directory)
      (message "Magit is not available; showing git diff instead")
      (pop-to-buffer (codex--git-diff-buffer directory)))))

;;;###autoload
(defun codex-login-status ()
  "Show `codex login status' in the minibuffer."
  (interactive)
  (codex--ensure-program)
  (pcase-let ((`(,exit-code . ,output) (codex--login-status-output)))
    (if (and (integerp exit-code) (zerop exit-code))
        (message "%s" (string-trim output))
      (user-error "codex login status failed: %s" (string-trim output)))))

(defvar codex-dashboard-buffer-name "*Codex Dashboard*"
  "Name of the Codex dashboard buffer.")

(defvar codex-dashboard-mode-map nil
  "Keymap for `codex-dashboard-mode'.")

(unless codex-dashboard-mode-map
  (setq codex-dashboard-mode-map (make-sparse-keymap))
  (define-key codex-dashboard-mode-map (kbd "RET") #'codex-dashboard-select)
  (define-key codex-dashboard-mode-map (kbd "TAB") #'codex-dashboard-preview)
  (define-key codex-dashboard-mode-map (kbd "g") #'codex-dashboard-refresh)
  (define-key codex-dashboard-mode-map (kbd "k") #'codex-dashboard-kill-instance)
  (define-key codex-dashboard-mode-map (kbd "q") #'codex-dashboard-quit)
  (define-key codex-dashboard-mode-map (kbd "r") #'codex-dashboard-refresh)
  (define-key codex-dashboard-mode-map (kbd "n") #'next-line)
  (define-key codex-dashboard-mode-map (kbd "p") #'previous-line))

(define-derived-mode codex-dashboard-mode fundamental-mode "Codex Dashboard"
  "Major mode for managing Codex instances."
  (setq buffer-read-only t)
  (setq truncate-lines t)
  (setq-local cursor-type 'box)
  (use-local-map codex-dashboard-mode-map))

(defun codex--dashboard-entries ()
  "Return dashboard entries for live buffers and external tmux sessions."
  (let* ((buffers (codex--find-all-codex-buffers))
         (buffer-sessions (delq nil
                                (mapcar #'codex--buffer-tmux-session
                                        buffers)))
         (buffer-entries (mapcar (lambda (buffer)
                                   (list :type 'buffer :buffer buffer))
                                 buffers))
         (tmux-entries
          (mapcar
           (lambda (pane)
             (list :type 'tmux
                   :session (plist-get pane :session)
                   :directory (plist-get pane :directory)
                   :command (plist-get pane :command)
                   :pane-id (plist-get pane :pane-id)
                   :pid (plist-get pane :pid)))
           (cl-remove-if
            (lambda (pane)
              (member (plist-get pane :session) buffer-sessions))
            (codex--tmux-codex-panes)))))
    (append buffer-entries tmux-entries)))

(defun codex-dashboard-get-entry-at-point ()
  "Return the dashboard entry referenced by the current line."
  (get-text-property (line-beginning-position) 'codex-dashboard-entry))

(defun codex-dashboard-get-buffer-at-point ()
  "Return the Codex buffer referenced by the current dashboard line."
  (let ((entry (codex-dashboard-get-entry-at-point)))
    (when (eq (plist-get entry :type) 'buffer)
      (plist-get entry :buffer))))

(defun codex--dashboard-entry-buffer (entry)
  "Return a buffer for dashboard ENTRY, attaching tmux sessions as needed."
  (pcase (plist-get entry :type)
    ('buffer
     (plist-get entry :buffer))
    ('tmux
     (codex--attach-external-tmux-session
      (plist-get entry :session)
      (or (plist-get entry :directory) default-directory)))))

(defun codex--format-dashboard-line (entry)
  "Format a dashboard line for ENTRY."
  (pcase (plist-get entry :type)
    ('buffer
     (let* ((buffer (plist-get entry :buffer))
            (dir (codex--buffer-directory buffer))
            (instance (or (codex--buffer-instance-name buffer) "default"))
            (project-name (if dir
                              (file-name-nondirectory (directory-file-name dir))
                            "Unknown"))
            (process (and (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (get-buffer-process buffer))))
            (status (if process
                        (if (eq (process-status process) 'run)
                            "running"
                          (symbol-name (process-status process)))
                      "no-process"))
            (command (with-current-buffer buffer
                       (cond
                        ((and codex--tmux-target-session
                              (derived-mode-p 'vterm-mode))
                         "tmux")
                        ((derived-mode-p 'vterm-mode) "vterm")
                        ((bound-and-true-p eat-terminal) "eat")
                        (process (process-name process))
                        (t "")))))
       (format "%-8s %-22s %-18s %-12s %-10s %s"
               "buffer"
               instance
               project-name
               status
               command
               (abbreviate-file-name (or dir "")))))
    ('tmux
     (let* ((session (plist-get entry :session))
            (dir (plist-get entry :directory))
            (project-name (if dir
                              (file-name-nondirectory (directory-file-name dir))
                            "Unknown"))
            (command (or (plist-get entry :command) "tmux")))
       (format "%-8s %-22s %-18s %-12s %-10s %s"
               "tmux"
               session
               project-name
               "detected"
               command
               (abbreviate-file-name (or dir "")))))
    (_
     (format "%-8s %-22s %-18s %-12s %-10s %s"
             "unknown" "" "" "" "" ""))))

;;;###autoload
(defun codex-dashboard ()
  "Open the Codex terminal dashboard."
  (interactive)
  (let ((dashboard-buffer (get-buffer-create codex-dashboard-buffer-name))
        (entries (codex--dashboard-entries)))
    (with-current-buffer dashboard-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Codex Terminal Dashboard\n" 'face 'header-line))
        (insert (propertize "Terminal/process state, not model turn state.\n" 'face 'shadow))
        (insert (propertize (make-string 50 ?=) 'face 'shadow))
        (insert "\n\n")
        (if entries
            (progn
              (insert (format "%-8s %-22s %-18s %-12s %-10s %s\n"
                              "Source" "Instance" "Project" "TermState" "Command" "Directory"))
              (insert (propertize (make-string 104 ?-) 'face 'shadow))
              (insert "\n")
              (dolist (entry entries)
                (let ((line-start (point)))
                  (insert (codex--format-dashboard-line entry))
                  (insert "\n")
                  (put-text-property line-start (line-end-position)
                                     'codex-dashboard-entry entry))))
          (insert (propertize "No Codex terminal instances detected." 'face 'warning)))
        (insert "\n\nKeybindings:")
        (insert "\n  RET - Select or attach instance")
        (insert "\n  TAB - Preview instance")
        (insert "\n  k   - Kill instance")
        (insert "\n  r/g - Refresh")
        (insert "\n  q   - Quit")
        (goto-char (point-min))
        (when entries
          (forward-line 5)))
      (codex-dashboard-mode)
      (setq buffer-read-only t))
    (switch-to-buffer dashboard-buffer)))

(defun codex-dashboard-select ()
  "Select the Codex instance at point."
  (interactive)
  (when-let* ((entry (codex-dashboard-get-entry-at-point))
              (buffer (codex--dashboard-entry-buffer entry)))
    (codex-dashboard-quit)
    (codex--display-buffer buffer)))

(defun codex-dashboard-preview ()
  "Preview the Codex instance at point."
  (interactive)
  (when-let* ((entry (codex-dashboard-get-entry-at-point))
              (buffer (codex--dashboard-entry-buffer entry)))
    (codex--display-buffer buffer)))

(defun codex-dashboard-kill-instance ()
  "Kill the Codex instance at point."
  (interactive)
  (when-let ((entry (codex-dashboard-get-entry-at-point)))
    (pcase (plist-get entry :type)
      ('buffer
       (let ((buffer (plist-get entry :buffer)))
         (when (yes-or-no-p
                (format "Kill Codex buffer %s? " (buffer-name buffer)))
           (kill-buffer buffer)
           (codex-dashboard-refresh))))
      ('tmux
       (let ((session (plist-get entry :session)))
         (when (yes-or-no-p
                (format "Kill tmux session %s? " session))
           (let ((exit-code (process-file codex-tmux-program
                                          nil nil nil
                                          "kill-session" "-t" session)))
             (unless (and (integerp exit-code) (zerop exit-code))
               (user-error "tmux kill-session failed for %s" session)))
           (codex-dashboard-refresh)))))))

(defun codex-dashboard-quit ()
  "Close the Codex dashboard."
  (interactive)
  (quit-window t))

(defun codex-dashboard-refresh ()
  "Refresh the Codex dashboard."
  (interactive)
  (codex-dashboard))

;;;###autoload
(define-minor-mode codex-mode
  "Global minor mode for Codex CLI commands."
  :global t
  :lighter " Codex"
  :keymap nil)

(provide 'codex)
;;; codex.el ends here
