;;; esx-test.el --- Tests for esx.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'esx)

(defvar esx-test--server
  (expand-file-name "mock-server.mjs"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun esx-test--start ()
  (setq esx-server-command (list "node" esx-test--server)
        esx-connection-timeout 5)
  (esx-start))

(defun esx-test--wait-for (predicate &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 5)))
        (ok nil))
    (while (and (< (float-time) deadline) (not ok))
      (accept-process-output nil 0.05)
      (setq ok (funcall predicate)))
    ok))

(defun esx-test--cleanup ()
  (esx-shutdown)
  (setq esx-repl-ns "user"))

(defmacro esx-test--with-server (&rest body)
  `(unwind-protect
       (progn (esx-test--start) ,@body)
     (esx-test--cleanup)))

(defun esx-test--result-overlays (buffer)
  (with-current-buffer buffer
    (seq-filter (lambda (overlay) (overlay-get overlay 'esx-result))
                (overlays-in (point-min) (point-max)))))

(defun esx-test--overlay-text (buffer)
  (mapconcat (lambda (overlay) (overlay-get overlay 'after-string))
             (esx-test--result-overlays buffer)
             "\n"))

(ert-deftest esx-client-eval ()
  (esx-test--with-server
   (let ((messages (esx-request-sync
                    "eval"
                    (list (cons "code" "1+1") (cons "ns" "user")))))
     (should (equal "mock:user:1+1" (esx--response-value messages)))
     (should-not (esx--response-error messages)))))

(ert-deftest esx-client-eval-error ()
  (esx-test--with-server
   (let* ((messages (esx-request-sync
                     "eval"
                     (list (cons "code" "throw new Error()") (cons "ns" "user"))))
          (error (esx--response-error messages)))
     (should (equal "Error: boom" (esx--error-text error))))))

(ert-deftest esx-code-bounds-region ()
  (with-temp-buffer
    (insert "const x = 1;\nconst y = 2;\n")
    (js-ts-mode)
    (transient-mark-mode 1)
    (goto-char (point-min))
    (let ((beg (point))
          (end (search-forward "const x = 1;")))
      (goto-char beg)
      (push-mark end nil t)
      (activate-mark)
      (let ((bounds (esx--code-bounds)))
        (should (equal "const x = 1;"
                       (buffer-substring-no-properties (car bounds) (cdr bounds))))))))

(ert-deftest esx-code-bounds-top-level ()
  (skip-unless (treesit-language-available-p 'javascript))
  (with-temp-buffer
    (insert "function foo(a) {\n  return a;\n}\n")
    (js-ts-mode)
    (goto-char (point-min))
    (search-forward "return")
    (let ((bounds (esx--code-bounds)))
      (should bounds)
      (should (string-match-p
               "function foo"
               (buffer-substring-no-properties (car bounds) (cdr bounds)))))))

(ert-deftest esx-eval-overlay ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (insert "const x = 1;\n")
     (js-ts-mode)
     (setq-local esx-repl-ns "user")
     (goto-char (point-min))
     (search-forward "const x")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                          (overlays-in (point-min) (point-max))))))
     (should (string-match-p "mock:user:const x = 1;"
                             (esx-test--overlay-text (current-buffer)))))))

(ert-deftest esx-eval-prefix-namespace ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (setq buffer-file-name "/tmp/esx-test.js")
     (insert "1+1\n")
     (js-ts-mode)
     (setq esx-repl-ns "repl")
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                          (overlays-in (point-min) (point-max))))))
     (should (string-match-p "mock:file:///tmp/esx-test.js:1\\+1"
                             (esx-test--overlay-text (current-buffer))))
     (esx--clear-result-overlays (current-buffer))
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval '(4))
     (should (esx-test--wait-for
              (lambda ()
                (string-match-p "mock:repl:1\\+1"
                                (esx-test--overlay-text (current-buffer)))))))))

(ert-deftest esx-jump-syncs-namespace ()
  (esx-test--with-server
   (let ((source (generate-new-buffer " *esx-source*")))
     (unwind-protect
         (progn
           (with-current-buffer source
             (setq buffer-file-name "/tmp/esx-jump.js")
             (insert "1+1\n")
             (js-ts-mode)
             (esx-jump))
           (should (equal "file:///tmp/esx-jump.js" esx-repl-ns))
           (should (equal "*ESX[esx-jump.js]*" (buffer-name esx-repl-buffer)))
           (with-current-buffer esx-repl-buffer
             (esx-jump))
           (should (eq (window-buffer (selected-window)) source)))
       (kill-buffer source)))))

(ert-deftest esx-jump-prefix-keeps-namespace ()
  (esx-test--with-server
   (with-temp-buffer
     (setq buffer-file-name "/tmp/esx-jump.js")
     (insert "1+1\n")
     (js-ts-mode)
     (setq esx-repl-ns "user")
     (esx-jump '(4))
     (should (equal "user" esx-repl-ns)))))

(ert-deftest esx-repl-buffer-name-follows-ns ()
  (esx-test--with-server
   (setq esx-repl-ns "user")
   (esx-repl)
   (should (equal "*ESX[user]*" (buffer-name esx-repl-buffer)))
   (esx-repl-set-ns "file:///tmp/foo.js")
   (should (equal "*ESX[foo.js]*" (buffer-name esx-repl-buffer)))))

(ert-deftest esx-repl-empty-input-inserts-new-prompt ()
  (let ((esx-repl-buffer nil)
        (esx-repl-ns "user"))
    (unwind-protect
        (progn
          (esx-repl--ensure-buffer)
          (with-current-buffer esx-repl-buffer
            (goto-char (point-max))
            (esx-repl-return)
            (should (equal "" (esx-repl--current-input)))
            (should (equal "ESX REPL\nuser> \nuser> "
                           (buffer-substring-no-properties (point-min) (point-max))))
            (insert "   ")
            (esx-repl-return)
            (should (equal "" (esx-repl--current-input)))
            (should (equal "ESX REPL\nuser> \nuser>    \nuser> "
                           (buffer-substring-no-properties (point-min) (point-max))))))
      (when (buffer-live-p esx-repl-buffer)
        (kill-buffer esx-repl-buffer)))))

(ert-deftest esx-source-output-goes-before-prompt ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (insert "1+1\n")
     (js-ts-mode)
     (setq-local esx-repl-ns "user")
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (with-current-buffer esx-repl-buffer
                  (string-match-p "mock-out" (buffer-string))))))
     (with-current-buffer esx-repl-buffer
       (let ((out (string-match "mock-out" (buffer-string)))
             (prompt (string-match "> \\'" (buffer-string))))
         (should out)
         (should prompt)
         (should (< out prompt)))))))


(ert-deftest esx-clear-result-overlays-command ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (insert "1+1\n")
     (js-ts-mode)
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                          (overlays-in (point-min) (point-max))))))
     (esx-clear-result-overlays)
     (should-not (esx-test--result-overlays (current-buffer))))))

(ert-deftest esx-result-overlay-auto-clears-on-edit ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (insert "1+1\n")
     (js-ts-mode)
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                          (overlays-in (point-min) (point-max))))))
     (goto-char (point-max))
     (insert " ")
     (should-not (esx-test--result-overlays (current-buffer))))))

(ert-deftest esx-stale-result-is-discarded ()
  (with-temp-buffer
    (insert "1+1\n")
    (let ((tick (buffer-chars-modified-tick))
          (position (copy-marker (point-max))))
      (goto-char (point-max))
      (insert "changed")
      (esx--handle-eval-response
       (current-buffer)
       position
       tick
       (list (cons 'status '("done"))
             (cons 'value "42")))
      (should-not (esx-test--result-overlays (current-buffer))))))


(ert-deftest esx-c-g-clears-result-overlays ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (insert "1+1\n")
     (js-ts-mode)
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                          (overlays-in (point-min) (point-max))))))
     (condition-case nil
         (execute-kbd-macro (kbd "C-g"))
       (quit nil))
     (should-not (esx-test--result-overlays (current-buffer))))))


(ert-deftest esx-c-g-keeps-overlay-with-region ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (with-temp-buffer
     (insert "1+1\n")
     (js-ts-mode)
     (goto-char (point-min))
     (search-forward "1+1")
     (esx-eval)
     (should (esx-test--wait-for
              (lambda ()
                (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                          (overlays-in (point-min) (point-max))))))
     (transient-mark-mode 1)
     (goto-char (point-min))
     (set-mark (point-max))
     (activate-mark)
     (should (use-region-p))
     (let ((this-command 'keyboard-quit))
       (esx--clear-results-on-quit))
     (should (esx-test--result-overlays (current-buffer)))
     (deactivate-mark)
     (let ((this-command 'keyboard-quit))
       (esx--clear-results-on-quit))
     (should-not (esx-test--result-overlays (current-buffer))))))


(ert-deftest esx-eval-timeout ()
  (skip-unless (treesit-language-available-p 'javascript))
  (esx-test--with-server
   (let ((esx-eval-timeout 0.2))
     (with-temp-buffer
       (insert "slow\n")
       (js-ts-mode)
       (goto-char (point-min))
       (search-forward "slow")
       (esx-eval)
       (should (esx-test--wait-for
                (lambda ()
                  (seq-find (lambda (overlay) (overlay-get overlay 'esx-result))
                            (overlays-in (point-min) (point-max))))
                2))
       (should (string-match-p "timed out"
                               (esx-test--overlay-text (current-buffer))))))))

(provide 'esx-test)
;;; esx-test.el ends here
