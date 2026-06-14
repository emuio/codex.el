;;; codex-test.el --- Tests for codex.el -*- lexical-binding: t -*-

;; SPDX-License-Identifier: MIT

;;; Code:

(require 'ert)
(require 'codex)

(ert-deftest codex-test-command-switches-default ()
  (let ((codex-program-switches nil))
    (should (equal (codex--command-switches "/tmp/project/" nil)
                   '("--cd" "/tmp/project/")))))

(ert-deftest codex-test-command-switches-yolo ()
  (let ((codex-program-switches nil))
    (should (equal (codex--command-switches "/tmp/project/" :yolo)
                   '("--dangerously-bypass-approvals-and-sandbox"
                     "--cd" "/tmp/project/")))))

(ert-deftest codex-test-command-switches-resume-last ()
  (let ((codex-program-switches nil))
    (should (equal (codex--command-switches "/tmp/project/" :resume-last)
                   '("resume" "--last" "--cd" "/tmp/project/")))))

(ert-deftest codex-test-command-switches-preserve-user-switches ()
  (let ((codex-program-switches '("--no-alt-screen" "--search")))
    (should (equal (codex--command-switches "/tmp/project/" nil)
                   '("--no-alt-screen" "--search" "--cd" "/tmp/project/")))))

(ert-deftest codex-test-default-backend-is-vterm ()
  (should (eq codex-backend 'vterm)))

(ert-deftest codex-test-tmux-enabled-by-default ()
  (should codex-use-tmux))

(ert-deftest codex-test-tmux-session-name-is-stable-and-shell-safe ()
  (let ((session-name (codex--tmux-session-name "/tmp/project dir/")))
    (should (string-match-p "\\`codex-project-dir-[0-9a-f]\\{8\\}\\'"
                            session-name))))

(ert-deftest codex-test-vterm-command-string-shell-quotes ()
  (let ((codex-program "codex")
        (codex-program-switches '("--search"))
        (codex-notify-inject-session-environment nil))
    (should (equal (codex--vterm-command-string "/tmp/project dir/" nil)
                   "codex --search --cd /tmp/project\\ dir/"))))

(ert-deftest codex-test-tmux-command-string-wraps-codex-command ()
  (let ((codex-program "codex")
        (codex-program-switches '("--search"))
        (codex-tmux-program "tmux")
        (codex-tmux-session-prefix "codex")
        (codex-notify-inject-session-environment nil))
    (should (equal (codex--tmux-command-string "/tmp/project dir/" nil)
                   (concat "tmux new-session -A -s "
                           (codex--tmux-session-name "/tmp/project dir/")
                           " -c /tmp/project\\ dir/ "
                           "codex\\ --search\\ --cd\\ /tmp/project\\\\\\ dir/")))))

(ert-deftest codex-test-vterm-command-injects-notify-session-environment ()
  (let ((codex-program "codex")
        (codex-program-switches nil)
        (codex-tmux-session-prefix "codex")
        (codex-notify-inject-session-environment t))
    (let ((command (codex--vterm-command-string "/tmp/project dir/" nil "work")))
      (should (string-prefix-p "env " command))
      (should (string-match-p
               (regexp-quote
                (shell-quote-argument
                 "CODEX_EL_DIRECTORY=/tmp/project dir/"))
               command))
      (should (string-match-p
               (regexp-quote
                (shell-quote-argument "CODEX_EL_INSTANCE=work"))
               command))
      (should (string-match-p
               (regexp-quote
                (shell-quote-argument
                 (format "CODEX_EL_TMUX_SESSION=%s"
                         (codex--tmux-session-name "/tmp/project dir/" "work"))))
               command))
      (should (string-match-p
               (regexp-quote
                (shell-quote-argument
                 (format "CODEX_EL_BUFFER_NAME=%s"
                         (codex--buffer-name "/tmp/project dir/" "work"))))
               command)))))

(ert-deftest codex-test-tmux-copy-mode-args-target-session ()
  (let ((codex-tmux-program "tmux"))
    (should (equal (codex--tmux-copy-mode-args "/tmp/project dir/" nil)
                   (list "copy-mode"
                         "-t"
                         (codex--tmux-session-name "/tmp/project dir/" nil))))))

(ert-deftest codex-test-tmux-capture-pane-args-target-session-and-limit ()
  (should (equal (codex--tmux-capture-pane-args "codex-project" 123)
                 '("capture-pane" "-p" "-J" "-S" "-123" "-t" "codex-project"))))

(ert-deftest codex-test-transcript-buffer-name-uses-configured-format ()
  (let ((codex-transcript-buffer-name-format "*Transcript:%s*"))
    (should (equal (codex--transcript-buffer-name "codex-project")
                   "*Transcript:codex-project*"))))

(ert-deftest codex-test-transcript-buffer-is-read-only-plain-emacs-buffer ()
  (let ((buffer (codex--transcript-buffer
                 "codex-project" "/tmp/project/" "first line\nsecond line\n" 123)))
    (unwind-protect
        (with-current-buffer buffer
          (should buffer-read-only)
          (should-not (derived-mode-p 'vterm-mode))
          (should-not (bound-and-true-p eat-terminal))
          (should (save-excursion
                    (goto-char (point-min))
                    (search-forward "second line" nil t))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-parse-tmux-pane-line ()
  (let ((pane (codex--parse-tmux-pane-line
               (mapconcat #'identity
                          '("testgit" "0" "0" "%0" "26835" "node"
                            "/Users/emuio/git/TestGit" "1" "TestGit")
                          "\t"))))
    (should (equal (plist-get pane :session) "testgit"))
    (should (equal (plist-get pane :pane-id) "%0"))
    (should (equal (plist-get pane :pid) "26835"))
    (should (equal (plist-get pane :command) "node"))
    (should (equal (plist-get pane :directory) "/Users/emuio/git/TestGit"))
    (should (plist-get pane :active))
    (should (equal (plist-get pane :title) "TestGit"))))

(ert-deftest codex-test-process-tree-detects-codex-descendant ()
  (let ((processes (list (list :pid "26835" :ppid "26834" :command "-zsh")
                         (list :pid "76070" :ppid "26835"
                               :command "node /usr/local/bin/codex --dangerously-bypass-approvals-and-sandbox")
                         (list :pid "76071" :ppid "76070"
                               :command "/usr/local/lib/node_modules/@openai/codex/bin/codex"))))
    (should (codex--process-tree-has-command-p
             "26835" processes codex-tmux-codex-command-regexp))))

(ert-deftest codex-test-tmux-pane-detects-external-codex-session ()
  (let ((pane (list :session "testgit"
                    :pane-id "%0"
                    :pid "26835"
                    :command "node"
                    :directory "/Users/emuio/git/TestGit"
                    :active t))
        (processes (list (list :pid "26835" :ppid "26834" :command "-zsh")
                         (list :pid "76070" :ppid "26835"
                               :command "node /usr/local/bin/codex --dangerously-bypass-approvals-and-sandbox"))))
    (should (codex--tmux-pane-codex-p pane processes))))

(ert-deftest codex-test-external-tmux-buffer-name ()
  (should (equal (codex--external-tmux-buffer-name "testgit")
                 "*codex-tmux:testgit*")))

(ert-deftest codex-test-external-tmux-buffer-name-roundtrip ()
  (should (equal (codex--extract-tmux-session-from-buffer-name
                  "*codex-tmux:testgit*")
                 "testgit"))
  (should-not (codex--extract-tmux-session-from-buffer-name
               "*codex:/tmp/project/*")))

(ert-deftest codex-test-external-tmux-buffer-metadata-falls-back-to-session ()
  (let ((buffer (get-buffer-create (codex--external-tmux-buffer-name "testgit"))))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--tmux-codex-panes)
                   (lambda ()
                     (list (list :session "testgit"
                                 :directory "/Users/emuio/git/TestGit"
                                 :command "node")))))
          (should (equal (codex--buffer-instance-name buffer) "testgit"))
          (should (equal (codex--buffer-tmux-session buffer) "testgit"))
          (should (equal (codex--buffer-directory buffer)
                         "/Users/emuio/git/TestGit")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-buffer-tmux-session-falls-back-to-detected-directory ()
  (let ((buffer (get-buffer-create (codex--buffer-name "/Users/emuio/.emacs.d/"))))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local codex--session-directory "/Users/emuio/.emacs.d/")
          (setq-local codex--tmux-target-session "codex-emacs-d-1016e324")
          (cl-letf (((symbol-function 'codex--tmux-session-live-p)
                     (lambda (session)
                       (string= session "emacs")))
                    ((symbol-function 'codex--tmux-codex-panes)
                     (lambda ()
                       (list (list :session "emacs"
                                   :directory "/Users/emuio/.emacs.d/"
                                   :command "node")))))
            (should (equal (codex--buffer-tmux-session buffer) "emacs"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-dashboard-row-buffer-without-process ()
  (let ((buffer (get-buffer-create (codex--buffer-name "/tmp/project/"))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local codex--session-directory "/tmp/project/"))
          (let ((row (codex--dashboard-entry-vector
                      (list :type 'buffer :buffer buffer)
                      "12:34:56")))
            (should (equal (aref row 0) "buffer"))
            (should (equal (aref row 1) "default"))
            (should (equal (aref row 2) "project"))
            (should (equal (aref row 3) "no-process"))
            (should (equal (aref row 4) ""))
            (should (equal (aref row 5) "12:34:56"))
            (should (equal (aref row 7) "/tmp/project/"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-dashboard-row-tmux-entry ()
  (cl-letf (((symbol-function 'codex--tmux-capture-preview)
             (lambda (_session)
               "last terminal line")))
    (let ((row (codex--dashboard-entry-vector
                (list :type 'tmux
                      :session "testgit"
                      :directory "/Users/emuio/git/TestGit"
                      :command "node")
                "12:34:56")))
      (should (equal (aref row 0) "tmux"))
      (should (equal (aref row 1) "testgit"))
      (should (equal (aref row 2) "TestGit"))
      (should (equal (aref row 3) "tmux-live"))
      (should (equal (aref row 4) ""))
      (should (equal (aref row 5) "12:34:56"))
      (should (equal (aref row 6) "last terminal line"))
      (should (equal (aref row 7) "/Users/emuio/git/TestGit")))))

(ert-deftest codex-test-notify-json-marks-dashboard-entry-done ()
  (clrhash codex--notification-events)
  (unwind-protect
      (let* ((metadata-json
              "{\"tmux-session\":\"codex-project-work\",\"buffer-name\":\"*codex:/tmp/project/:work*\",\"directory\":\"/tmp/project/\",\"instance\":\"work\"}")
             (payload-json
              "{\"type\":\"agent-turn-complete\",\"thread-id\":\"thread-1\",\"turn-id\":\"turn-1\",\"cwd\":\"/tmp/project/\",\"last-assistant-message\":\"Implementation finished.\"}")
             (entry (list :type 'tmux
                          :session "codex-project-work"
                          :directory "/tmp/project/"))
             (row nil))
        (codex-notify-agent-turn-complete-json payload-json metadata-json)
        (setq row (codex--dashboard-entry-vector entry "12:34:56"))
        (should (equal (aref row 4) "done!"))
        (should (equal (aref row 6) "Implementation finished.")))
    (clrhash codex--notification-events)))

(ert-deftest codex-test-notify-json-falls-back-to-cwd-for-external-session ()
  (clrhash codex--notification-events)
  (unwind-protect
      (let* ((payload-json
              "{\"type\":\"agent-turn-complete\",\"thread-id\":\"thread-1\",\"turn-id\":\"turn-1\",\"cwd\":\"/tmp/project/\",\"last-assistant-message\":\"Done from cwd.\"}")
             (entry (list :type 'tmux
                          :session "external"
                          :directory "/tmp/project/")))
        (codex-notify-agent-turn-complete-json payload-json)
        (should (equal (codex--dashboard-entry-turn-state entry) "done!"))
        (should (equal (codex--dashboard-entry-preview entry) "Done from cwd.")))
    (clrhash codex--notification-events)))

(ert-deftest codex-test-dashboard-select-clears-notify-state ()
  (clrhash codex--notification-events)
  (let ((dashboard-buffer (get-buffer-create " *codex-dashboard-notify-test*"))
        (target-buffer (get-buffer-create " *codex-dashboard-notify-target*"))
        (entry (list :type 'tmux
                     :session "codex-project-work"
                     :directory "/tmp/project/")))
    (unwind-protect
        (progn
          (puthash "tmux:codex-project-work"
                   (list :last-assistant-message "Done")
                   codex--notification-events)
          (with-current-buffer dashboard-buffer
            (erase-buffer)
            (insert "entry")
            (add-text-properties
             (point-min) (point-max)
             (list 'codex-dashboard-entry entry))
            (goto-char (point-min)))
          (cl-letf (((symbol-function 'codex--dashboard-entry-buffer)
                     (lambda (_entry) target-buffer))
                    ((symbol-function 'codex--display-buffer)
                     (lambda (_buffer &optional _selected-window) nil)))
            (with-current-buffer dashboard-buffer
              (codex-dashboard-select)))
          (should-not (gethash "tmux:codex-project-work"
                               codex--notification-events)))
      (clrhash codex--notification-events)
      (when (buffer-live-p dashboard-buffer)
        (kill-buffer dashboard-buffer))
      (when (buffer-live-p target-buffer)
        (kill-buffer target-buffer)))))

(ert-deftest codex-test-dashboard-clean-preview-collapses-and-truncates ()
  (let ((codex-dashboard-preview-width 12))
    (should (equal (codex--dashboard-clean-preview
                    " \tfirst\nsecond   line with more text ")
                   "first second..."))))

(ert-deftest codex-test-tmux-capture-preview-uses-bounded-capture ()
  (let ((codex-dashboard-preview-lines 8)
        (captured-args nil))
    (cl-letf (((symbol-function 'codex--process-file-lines)
               (lambda (program &rest args)
                 (setq captured-args (cons program args))
                 '("first line" "" "last line"))))
      (should (equal (codex--tmux-capture-preview "testgit") "last line"))
      (should (equal captured-args
                     (list codex-tmux-program
                           "capture-pane" "-p" "-J"
                           "-S" "-8"
                           "-t" "testgit"))))))

(ert-deftest codex-test-tmux-capture-preview-returns-nil-without-output ()
  (cl-letf (((symbol-function 'codex--process-file-lines)
             (lambda (_program &rest _args)
               nil)))
    (should-not (codex--tmux-capture-preview "testgit"))))

(ert-deftest codex-test-dashboard-buffer-preview-falls-back-after-empty-tmux-capture ()
  (let ((buffer (get-buffer-create " *codex-dashboard-preview-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "older line\nfallback line\n"))
          (cl-letf (((symbol-function 'codex--buffer-tmux-session)
                     (lambda (_buffer)
                       "testgit"))
                    ((symbol-function 'codex--tmux-capture-preview)
                     (lambda (_session)
                       "")))
            (should (equal (codex--dashboard-entry-preview
                            (list :type 'buffer :buffer buffer))
                           "older line fallback line"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-dashboard-entries-include-external-tmux-without-duplicates ()
  (let* ((internal-dir "/tmp/internal/")
         (internal-session (codex--tmux-session-name internal-dir))
         (internal-buffer (get-buffer-create (codex--buffer-name internal-dir))))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--find-all-codex-buffers)
                   (lambda () (list internal-buffer)))
                  ((symbol-function 'codex--tmux-codex-panes)
                   (lambda ()
                     (list (list :session internal-session
                                 :directory internal-dir
                                 :command "node"
                                 :pane-id "%1"
                                 :pid "100")
                           (list :session "testgit"
                                 :directory "/Users/emuio/git/TestGit"
                                 :command "node"
                                 :pane-id "%0"
                                 :pid "26835")))))
          (let ((entries (codex--dashboard-entries)))
            (should (= (length entries) 2))
            (should (= (length (cl-remove-if-not
                                (lambda (entry)
                                  (eq (plist-get entry :type) 'buffer))
                                entries))
                       1))
            (should (cl-find-if
                     (lambda (entry)
                       (and (eq (plist-get entry :type) 'tmux)
                            (equal (plist-get entry :session) "testgit")))
                     entries))
            (should-not (cl-find-if
                         (lambda (entry)
                           (and (eq (plist-get entry :type) 'tmux)
                                (equal (plist-get entry :session)
                                       internal-session)))
                         entries))))
      (when (buffer-live-p internal-buffer)
        (kill-buffer internal-buffer)))))

(ert-deftest codex-test-command-map-has-copy-mode-shortcuts ()
  (should (eq (lookup-key codex-command-map "[") #'codex-tmux-copy-mode))
  (should (eq (lookup-key codex-command-map "p") #'codex-tmux-copy-mode))
  (should (eq (lookup-key codex-command-map "T") #'codex-capture-transcript))
  (should (eq (lookup-key codex-command-map "D") #'codex-project-diff))
  (should (eq (lookup-key codex-command-map "g") #'codex-project-magit-status)))

(ert-deftest codex-test-command-map-has-menu-binding ()
  (should (eq (lookup-key codex-command-map "m") #'codex-menu)))

(ert-deftest codex-test-command-map-refreshes-existing-keymap ()
  (let ((codex-command-map (make-sparse-keymap)))
    (define-key codex-command-map "c" #'ignore)
    (codex--define-command-map)
    (should (eq (lookup-key codex-command-map "c") #'codex))
    (should (eq (lookup-key codex-command-map "m") #'codex-menu))
    (should (eq (lookup-key codex-command-map "[") #'codex-tmux-copy-mode))
    (should (eq (lookup-key codex-command-map "p") #'codex-tmux-copy-mode))
    (should (eq (lookup-key codex-command-map "T") #'codex-capture-transcript))
    (should (eq (lookup-key codex-command-map "D") #'codex-project-diff))
    (should (eq (lookup-key codex-command-map "g") #'codex-project-magit-status))))

(ert-deftest codex-test-menu-errors-when-transient-is-missing ()
  (let ((original-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'transient)
                     nil
                   (funcall original-require feature filename noerror)))))
      (should-error (codex-menu) :type 'user-error))))

(ert-deftest codex-test-menu-defines-prefix-when-transient-is-available ()
  (skip-unless (require 'transient nil t))
  (should (eq (codex--ensure-transient-menu) 'codex--menu))
  (should (commandp 'codex--menu)))

(ert-deftest codex-test-command-map-has-context-binding ()
  (should (eq (lookup-key codex-command-map "C") #'codex-send-context)))

(ert-deftest codex-test-format-context-includes-buffer-location ()
  (with-temp-buffer
    (rename-buffer "context-location-test" t)
    (insert "first\nsecond\nthird\n")
    (goto-char 9)
    (setq buffer-file-name "/tmp/project/example.el")
    (let ((default-directory "/tmp/project/"))
      (cl-letf (((symbol-function 'codex--directory)
                 (lambda () "/tmp/project/")))
        (should
         (equal (codex--format-context)
                (string-join
                 '("Emacs context:"
                   "- Buffer: context-location-test"
                   "- File: /tmp/project/example.el"
                   "- Project/default directory: /tmp/project/"
                   "- Point: 9"
                   "- Line: 2"
                   "- Column: 2")
                 "\n")))))))

(ert-deftest codex-test-format-context-includes-small-active-region ()
  (with-temp-buffer
    (rename-buffer "context-region-test" t)
    (insert "alpha beta gamma")
    (goto-char 1)
    (push-mark 11 t t)
    (let ((codex-context-include-region-text t)
          (codex-context-max-region-chars 20)
          (transient-mark-mode t)
          (mark-active t))
      (cl-letf (((symbol-function 'codex--directory)
                 (lambda () "/tmp/project/")))
        (should
         (equal (codex--format-context)
                (string-join
                 '("Emacs context:"
                   "- Buffer: context-region-test"
                   "- File: none"
                   "- Project/default directory: /tmp/project/"
                   "- Point: 1"
                   "- Line: 1"
                   "- Column: 0"
                   "- Region: 1-11 (10 chars)"
                   "Selected text:"
                   "```text"
                   "alpha beta"
                   "```")
                 "\n")))))))

(ert-deftest codex-test-format-context-omits-large-region-text ()
  (with-temp-buffer
    (insert "0123456789abcdef")
    (goto-char 1)
    (push-mark (point-max) t t)
    (let ((codex-context-include-region-text t)
          (codex-context-max-region-chars 5)
          (transient-mark-mode t)
          (mark-active t))
      (cl-letf (((symbol-function 'codex--directory)
                 (lambda () "/tmp/project/")))
        (let ((context (codex--format-context)))
          (should-not (string-match-p "Region:" context))
          (should-not (string-match-p "Selected text:" context))
          (should-not (string-match-p "0123456789abcdef" context)))))))

(ert-deftest codex-test-format-context-respects-region-text-toggle ()
  (with-temp-buffer
    (rename-buffer "context-region-toggle-test" t)
    (insert "short text")
    (goto-char 1)
    (push-mark (point-max) t t)
    (let ((codex-context-include-region-text nil)
          (codex-context-max-region-chars 20)
          (transient-mark-mode t)
          (mark-active t))
      (cl-letf (((symbol-function 'codex--directory)
                 (lambda () "/tmp/project/")))
        (let ((context (codex--format-context)))
          (should (string-match-p "- Region: 1-11 (10 chars)" context))
          (should-not (string-match-p "Selected text:" context))
          (should-not (string-match-p "short text" context)))))))

(ert-deftest codex-test-terminal-mode-has-shift-return-binding ()
  (should (equal codex-shift-return-sequence "\C-j"))
  (should (eq (lookup-key codex-terminal-mode-map (kbd "S-<return>"))
              #'codex-send-shift-return))
  (should (eq (lookup-key codex-terminal-mode-map (kbd "S-RET"))
              #'codex-send-shift-return))
  (should (eq (lookup-key codex-terminal-mode-map (kbd "S-<kp-enter>"))
              #'codex-send-shift-return))
  (should (eq (lookup-key codex-terminal-mode-map (kbd "<S-kp-enter>"))
              #'codex-send-shift-return)))

(ert-deftest codex-test-terminal-mode-has-copy-mode-binding ()
  (should (eq (lookup-key codex-terminal-mode-map (kbd "C-c C-t"))
              #'codex-copy-mode)))

(ert-deftest codex-test-vterm-entry-command-uses-tmux-when-enabled ()
  (let ((codex-use-tmux t))
    (should (string-prefix-p "tmux new-session -A"
                             (codex--vterm-entry-command-string
                              "/tmp/project dir/" nil)))))

(ert-deftest codex-test-vterm-entry-command-can-skip-tmux ()
  (let ((codex-use-tmux nil)
        (codex-program "codex")
        (codex-program-switches nil)
        (codex-notify-inject-session-environment nil))
    (should (equal (codex--vterm-entry-command-string
                    "/tmp/project dir/" nil)
                   "codex --cd /tmp/project\\ dir/"))))

(ert-deftest codex-test-login-status-parser ()
  (should (codex--logged-in-status-p "Logged in using ChatGPT\n"))
  (should (codex--logged-in-status-p "Logged in using API key\n"))
  (should-not (codex--logged-in-status-p "Not logged in\n")))

(ert-deftest codex-test-buffer-name-roundtrip ()
  (let ((name (codex--buffer-name "/tmp/project/" "work")))
    (should (equal name "*codex:/tmp/project/:work*"))
    (should (equal (codex--extract-directory-from-buffer-name name)
                   "/tmp/project/"))
    (should (equal (codex--extract-instance-name-from-buffer-name name)
                   "work"))))

(ert-deftest codex-test-buffer-name-default-instance ()
  (let ((name (codex--buffer-name "/tmp/project/" nil)))
    (should (equal name "*codex:/tmp/project/*"))
    (should (equal (codex--extract-directory-from-buffer-name name)
                   "/tmp/project/"))
    (should-not (codex--extract-instance-name-from-buffer-name name))))

(ert-deftest codex-test-current-project-directory-prefers-codex-buffer-directory ()
  (let ((buffer (get-buffer-create (codex--buffer-name "/tmp/project/"))))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local codex--session-directory "/tmp/project/")
          (should (equal (codex--current-project-directory)
                         "/tmp/project/")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-git-diff-args-use-project-directory ()
  (should (equal (codex--git-diff-args "/tmp/project/")
                 '("-C" "/tmp/project/" "diff" "--no-color"))))

(ert-deftest codex-test-git-diff-buffer-name-uses-project-directory ()
  (should (equal (codex--git-diff-buffer-name "/tmp/project/")
                 "*codex-diff:/tmp/project/*")))

(ert-deftest codex-test-display-buffer-full-frame-by-default ()
  (let ((buffer (get-buffer-create " *codex-display-test*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (split-window-right)
          (codex--display-buffer buffer)
          (should (eq (current-buffer) buffer))
          (should (= (length (window-list)) 1)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-display-buffer-can-use-selected-window ()
  (let ((buffer (get-buffer-create " *codex-display-current-window-test*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (split-window-right)
          (codex--display-buffer buffer t)
          (should (eq (window-buffer (selected-window)) buffer))
          (should (= (length (window-list)) 2)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-other-windows))))

(ert-deftest codex-test-dashboard-select-preserves-selected-window ()
  (let ((dashboard-buffer (get-buffer-create " *codex-dashboard-select-test*"))
        (target-buffer (get-buffer-create " *codex-dashboard-target-test*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer dashboard-buffer
            (erase-buffer)
            (insert "entry")
            (add-text-properties
             (point-min) (point-max)
             (list 'codex-dashboard-entry
                   (list :type 'buffer :buffer target-buffer)))
            (goto-char (point-min)))
          (switch-to-buffer dashboard-buffer)
          (split-window-right)
          (select-window (get-buffer-window dashboard-buffer))
          (codex-dashboard-select)
          (should (eq (window-buffer (selected-window)) target-buffer))
          (should (= (length (window-list)) 2)))
      (when (buffer-live-p dashboard-buffer)
        (kill-buffer dashboard-buffer))
      (when (buffer-live-p target-buffer)
        (kill-buffer target-buffer))
      (delete-other-windows))))

(ert-deftest codex-test-dashboard-preview-preserves-selected-window ()
  (let ((dashboard-buffer (get-buffer-create " *codex-dashboard-preview-window-test*"))
        (target-buffer (get-buffer-create " *codex-dashboard-preview-target-test*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer dashboard-buffer
            (erase-buffer)
            (insert "entry")
            (add-text-properties
             (point-min) (point-max)
             (list 'codex-dashboard-entry
                   (list :type 'buffer :buffer target-buffer)))
            (goto-char (point-min)))
          (switch-to-buffer dashboard-buffer)
          (split-window-right)
          (select-window (get-buffer-window dashboard-buffer))
          (codex-dashboard-preview)
          (should (eq (window-buffer (selected-window)) target-buffer))
          (should (= (length (window-list)) 2)))
      (when (buffer-live-p dashboard-buffer)
        (kill-buffer dashboard-buffer))
      (when (buffer-live-p target-buffer)
        (kill-buffer target-buffer))
      (delete-other-windows))))

(ert-deftest codex-test-tmux-copy-mode-preserves-window-layout ()
  (let ((buffer (get-buffer-create (codex--buffer-name "/tmp/project/" "copy"))))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer buffer)
          (with-current-buffer buffer
            (setq-local codex--session-directory "/tmp/project/")
            (setq-local codex--session-instance "copy")
            (setq-local codex--tmux-target-session "codex-project-copy"))
          (split-window-right)
          (cl-letf (((symbol-function 'codex--ensure-tmux) #'ignore)
                    ((symbol-function 'process-file)
                     (lambda (&rest _args) 0)))
            (let ((codex-use-tmux t))
              (codex-tmux-copy-mode)))
          (should (eq (window-buffer (selected-window)) buffer))
          (should (= (length (window-list)) 2)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-other-windows))))

(provide 'codex-test)
;;; codex-test.el ends here
