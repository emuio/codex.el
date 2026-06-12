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
  (should (eq (lookup-key codex-command-map "p") #'codex-tmux-copy-mode)))

(ert-deftest codex-test-command-map-refreshes-existing-keymap ()
  (let ((codex-command-map (make-sparse-keymap)))
    (define-key codex-command-map "c" #'ignore)
    (codex--define-command-map)
    (should (eq (lookup-key codex-command-map "c") #'codex))
    (should (eq (lookup-key codex-command-map "[") #'codex-tmux-copy-mode))
    (should (eq (lookup-key codex-command-map "p") #'codex-tmux-copy-mode))))

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
