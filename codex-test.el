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
        (codex-program-switches '("--search")))
    (should (equal (codex--vterm-command-string "/tmp/project dir/" nil)
                   "codex --search --cd /tmp/project\\ dir/"))))

(ert-deftest codex-test-tmux-command-string-wraps-codex-command ()
  (let ((codex-program "codex")
        (codex-program-switches '("--search"))
        (codex-tmux-program "tmux")
        (codex-tmux-session-prefix "codex"))
    (should (equal (codex--tmux-command-string "/tmp/project dir/" nil)
                   (concat "tmux new-session -A -s "
                           (codex--tmux-session-name "/tmp/project dir/")
                           " -c /tmp/project\\ dir/ "
                           "codex\\ --search\\ --cd\\ /tmp/project\\\\\\ dir/")))))

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

(ert-deftest codex-test-dashboard-format-buffer-without-process ()
  (let ((buffer (get-buffer-create (codex--buffer-name "/tmp/project/"))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local codex--session-directory "/tmp/project/"))
          (let ((line (codex--format-dashboard-line
                       (list :type 'buffer :buffer buffer))))
            (should (string-match-p "\\bbuffer\\b" line))
            (should (string-match-p "\\bdefault\\b" line))
            (should (string-match-p "\\bproject\\b" line))
            (should (string-match-p "\\bno-process\\b" line))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-dashboard-format-tmux-entry ()
  (let ((line (codex--format-dashboard-line
               (list :type 'tmux
                     :session "testgit"
                     :directory "/Users/emuio/git/TestGit"
                     :command "node"))))
    (should (string-match-p "\\btmux\\b" line))
    (should (string-match-p "\\btestgit\\b" line))
    (should (string-match-p "\\bTestGit\\b" line))
    (should (string-match-p "\\bdetected\\b" line))
    (should (string-match-p "\\bnode\\b" line))))

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
        (codex-program-switches nil))
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

(provide 'codex-test)
;;; codex-test.el ends here
