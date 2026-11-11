;;; esx-repl.el --- Interactive REPL for esx -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;;; Commentary:

;; CIDER/SLIME-style REPL: output region, prompt, editable input region,
;; history, and asynchronous output inserted before the prompt.
;;
;; There is exactly one REPL buffer.  Its name follows the current namespace:
;; *ESX[user]*, *ESX[foo.js]*, ...

;;; Code:

(require 'cl-lib)
(require 'js)
(require 'js-ts-mode nil t)
(require 'ring)
(require 'subr-x)
(require 'treesit)
(declare-function treesit-parser-root "treesit" (parser))
(require 'esx-client)
(require 'esx-ns)

(defgroup esx-repl nil
  "REPL for esx."
  :group 'esx
  :prefix "esx-repl-")

(defcustom esx-repl-history-size 200
  "Maximum number of REPL input history entries."
  :type 'integer
  :group 'esx-repl)

(defface esx-repl-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the REPL prompt."
  :group 'esx-repl)

(defface esx-repl-output-face
  '((t :inherit default))
  "Face for REPL output."
  :group 'esx-repl)

(defface esx-repl-result-face
  '((t :inherit font-lock-string-face))
  "Face for REPL results."
  :group 'esx-repl)

(defface esx-repl-error-face
  '((t :inherit error))
  "Face for REPL errors."
  :group 'esx-repl)

(defvar esx-repl-buffer nil
  "The single esx REPL buffer.")

(defvar esx--origin-buffer nil
  "Source buffer that opened the REPL.")

(defvar-local esx-repl-input-start nil)
(defvar-local esx-repl-output-start nil)
(defvar-local esx-repl-output-end nil)
(defvar-local esx-repl-prompt-start nil)
(defvar-local esx-repl-history nil)
(defvar-local esx-repl-history-index 0)

(defvar esx-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'esx-repl-return)
    (define-key map (kbd "M-p") #'esx-repl-previous-input)
    (define-key map (kbd "M-n") #'esx-repl-next-input)
    (define-key map (kbd "C-c C-z") #'esx-jump)
    (define-key map (kbd "C-c M-o") #'esx-repl-clear-buffer)
    map)
  "Keymap for `esx-repl-mode'.")

(defun esx-repl-buffer-name ()
  "Return the REPL buffer name for the current namespace."
  (format "*ESX[%s]*" (esx--ns-display esx-repl-ns)))

(defun esx-repl--markers ()
  "Create the REPL markers if they do not exist."
  (unless (markerp esx-repl-input-start)
    (setq esx-repl-input-start (make-marker)))
  (unless (markerp esx-repl-output-start)
    (setq esx-repl-output-start (make-marker)))
  (unless (markerp esx-repl-output-end)
    (setq esx-repl-output-end (make-marker)))
  (unless (markerp esx-repl-prompt-start)
    (setq esx-repl-prompt-start (make-marker))))

(defun esx-repl--rename-buffer ()
  "Rename the REPL buffer to match the current namespace."
  (when (buffer-live-p esx-repl-buffer)
    (with-current-buffer esx-repl-buffer
      (let ((name (esx-repl-buffer-name)))
        (unless (equal (buffer-name) name)
          (rename-buffer (generate-new-buffer-name name) t))))))

(defun esx-repl--insert-prompt ()
  "Insert a prompt at the end of the output and mark the input area."
  (esx-repl--markers)
  (let ((inhibit-read-only t))
    (goto-char esx-repl-output-end)
    (unless (bolp)
      (insert-before-markers "\n"))
    (let ((start (point))
          (prompt (format "%s> " (esx--ns-display esx-repl-ns))))
      (insert-before-markers
       (propertize prompt
                   'face 'esx-repl-prompt-face
                   'read-only t
                   'front-sticky '(read-only)
                   'rear-nonsticky '(read-only face field)
                   'field 'output))
      (set-marker esx-repl-prompt-start start)
      (set-marker esx-repl-output-start start)
      (set-marker esx-repl-output-end start)
      (set-marker esx-repl-input-start (point))))
  (goto-char (point-max)))

(defun esx-repl--update-prompt ()
  "Rewrite the current prompt to match `esx-repl-ns'."
  (when (and (buffer-live-p esx-repl-buffer)
             (markerp esx-repl-prompt-start)
             (markerp esx-repl-input-start)
             (<= (marker-position esx-repl-prompt-start)
                 (marker-position esx-repl-input-start)))
    (with-current-buffer esx-repl-buffer
      (let ((inhibit-read-only t)
            (start (marker-position esx-repl-prompt-start)))
        (delete-region esx-repl-prompt-start esx-repl-input-start)
        (goto-char start)
        (let ((prompt (format "%s> " (esx--ns-display esx-repl-ns))))
          (insert (propertize prompt
                              'face 'esx-repl-prompt-face
                              'read-only t
                              'front-sticky '(read-only)
                              'rear-nonsticky '(read-only face field)
                              'field 'output)))
        (set-marker esx-repl-input-start (point))
        (set-marker esx-repl-output-end start)))))

(defun esx-repl--insert-output (text &optional is-error result)
  "Insert TEXT before the prompt.
IS-ERROR selects the error face; RESULT selects the result face."
  (when (buffer-live-p esx-repl-buffer)
    (with-current-buffer esx-repl-buffer
      (esx-repl--markers)
      (let ((inhibit-read-only t)
            (face (cond (is-error 'esx-repl-error-face)
                        (result 'esx-repl-result-face)
                        (t 'esx-repl-output-face))))
        (save-excursion
          (goto-char esx-repl-output-end)
          (insert-before-markers (propertize text 'face face 'field 'output))
          (set-marker esx-repl-output-end (point))))
      (when (eq (window-buffer (selected-window)) (current-buffer))
        (goto-char (point-max))
        (recenter -1)))))

(defun esx-repl--current-input ()
  "Return the current REPL input."
  (esx-repl--markers)
  (buffer-substring-no-properties esx-repl-input-start (point-max)))

(defun esx-repl--replace-input (text)
  "Replace the current input with TEXT."
  (let ((inhibit-read-only t))
    (delete-region esx-repl-input-start (point-max))
    (goto-char esx-repl-input-start)
    (insert text)))

(defun esx-repl--add-history (input)
  "Add INPUT to the REPL history."
  (unless (or (string-empty-p input)
              (and (not (ring-empty-p esx-repl-history))
                   (string= input (ring-ref esx-repl-history 0))))
    (ring-insert esx-repl-history input))
  (setq esx-repl-history-index 0))

(defun esx-repl-previous-input ()
  "Replace the current input with the previous history entry."
  (interactive)
  (if (ring-empty-p esx-repl-history)
      (message "No REPL history")
    (let ((index (min esx-repl-history-index
                      (1- (ring-length esx-repl-history)))))
      (esx-repl--replace-input (ring-ref esx-repl-history index))
      (setq esx-repl-history-index (1+ index)))))

(defun esx-repl-next-input ()
  "Replace the current input with the next history entry."
  (interactive)
  (if (ring-empty-p esx-repl-history)
      (message "No REPL history")
    (let ((index (1- esx-repl-history-index)))
      (if (< index 0)
          (progn
            (esx-repl--replace-input "")
            (setq esx-repl-history-index 0))
        (esx-repl--replace-input (ring-ref esx-repl-history index))
        (setq esx-repl-history-index index)))))

(defun esx--treesit-root (parser)
  (if (fboundp 'treesit-parser-root-node)
      (treesit-parser-root-node parser)
    (treesit-parser-root parser)))

(defun esx-repl--input-complete-p (input)
  "Return non-nil when INPUT is a complete JavaScript form."
  (or (string-match-p "\\`\\s-*await\\b" input)
      (condition-case nil
          (with-temp-buffer
            (insert input)
            (delay-mode-hooks (js-ts-mode))
            (let* ((parser (treesit-parser-create 'javascript))
                   (root (esx--treesit-root parser)))
              (not (treesit-search-subtree
                    root
                    (lambda (node)
                      (equal (treesit-node-type node) "ERROR"))))))
        (error t))))

(defun esx-repl--handle-response (message)
  "Handle one eval response MESSAGE in the REPL."
  (when (esx--has message "out")
    (esx-repl--insert-output (esx--get message "out")))
  (when (esx--has message "err")
    (esx-repl--insert-output (esx--get message "err") t))
  (when (esx--has message "value")
    (esx-repl--insert-output (concat (esx--get message "value") "\n") nil t))
  (when (esx--has message "ex")
    (esx-repl--insert-output
     (concat (or (esx--error-text (esx--get message "ex")) "Evaluation error")
             "\n")
     t))
  (when (esx--status-p message "done")
    (esx-repl--insert-prompt)))

(defun esx-repl--send-eval (input)
  "Send INPUT to the server for the current REPL namespace."
  (let ((buffer (current-buffer)))
    (esx-request
     "eval"
     (list (cons "code" input)
           (cons "ns" esx-repl-ns)
           (cons "file" (or buffer-file-name ""))
           (cons "line" "1")
           (cons "column" "1"))
     (lambda (message)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (esx-repl--handle-response message))))
     esx-eval-timeout)))

(defun esx-repl--commit-input ()
  "Move the current input into the read-only output area."
  (goto-char (point-max))
  (let ((start esx-repl-input-start)
        (end (point-max)))
    (insert "\n")
    (add-text-properties start end
                         '(read-only t
                           rear-nonsticky (read-only)
                           face esx-repl-output-face))
    (set-marker esx-repl-output-start (point-max))
    (set-marker esx-repl-output-end (point-max))
    (set-marker esx-repl-input-start (point-max))))

(defun esx-repl--send-input ()
  "Send the current input and start a new output region."
  (let ((input (string-trim (esx-repl--current-input))))
    (if (string-empty-p input)
        (esx-repl--insert-prompt)
      (esx-repl--add-history input)
      (esx-repl--commit-input)
      (esx-repl--send-eval input))))

(defun esx-repl--command-p (input)
  "Return non-nil when INPUT is a REPL dot-command."
  (string-match-p "\\`\\.ns\\(?:\\s-\\|\\'\\)" input))

(defun esx-repl--run-command (input)
  "Run the dot-command INPUT.  The input is already in the output area."
  (cond
   ((string-match "\\`\\.ns\\s-*\\(.*\\)\\'" input)
    (let ((specifier (string-trim (match-string 1 input))))
      (if (string-empty-p specifier)
          (message "Current namespace: %s" esx-repl-ns)
        (esx-repl-set-ns (esx-ns-resolve specifier esx-repl-ns) nil)))
    (esx-repl--insert-prompt))
   (t
    (esx-repl--insert-prompt))))

(defun esx-repl-return (&optional force)
  "Evaluate the current input, or insert a newline.
With prefix argument FORCE, send even if the input looks incomplete."
  (interactive "P")
  (let ((input (string-trim (esx-repl--current-input))))
    (cond
     ((esx-repl--command-p input)
      (esx-repl--commit-input)
      (esx-repl--run-command input))
     ((or force (esx-repl--input-complete-p input))
      (esx-repl--send-input))
     (t
      (newline-and-indent)
      (message "[input not complete]")))))

(defun esx-repl-clear-buffer ()
  "Clear the whole REPL buffer."
  (interactive)
  (with-current-buffer esx-repl-buffer
    (let ((inhibit-read-only t))
      (erase-buffer))
    (set-marker esx-repl-input-start (point-min))
    (set-marker esx-repl-output-start (point-min))
    (set-marker esx-repl-output-end (point-min))
    (set-marker esx-repl-prompt-start (point-min))
    (esx-repl--insert-prompt)))

(defun esx-repl--reset ()
  "Reset the REPL buffer to its initial state."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "ESX REPL\n" 'face 'font-lock-comment-face)))
  (set-marker esx-repl-input-start (point-max))
  (set-marker esx-repl-output-start (point-max))
  (set-marker esx-repl-output-end (point-max))
  (set-marker esx-repl-prompt-start (point-max))
  (esx-repl--insert-prompt))

(defun esx-repl--ensure-buffer ()
  "Create the REPL buffer if necessary, without selecting it."
  (unless (buffer-live-p esx-repl-buffer)
    (setq esx-repl-buffer (get-buffer-create (esx-repl-buffer-name)))
    (with-current-buffer esx-repl-buffer
      (esx-repl-mode)
      (esx-repl--reset)))
  (esx-repl--rename-buffer)
  esx-repl-buffer)

(defun esx-repl--output-hook (text is-error)
  "Insert unsolicited server output TEXT into the REPL."
  (when (buffer-live-p esx-repl-buffer)
    (esx-repl--insert-output text is-error)))

(add-hook 'esx-output-functions #'esx-repl--output-hook)

;;;###autoload
(define-derived-mode esx-repl-mode js-mode "ESX-REPL"
  "Major mode for interacting with an esx server."
  (setq-local esx-repl-history (make-ring esx-repl-history-size))
  (setq-local esx-repl-history-index 0)
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only nil)
  (esx-repl--markers))

;;;###autoload
(defun esx-repl ()
  "Start (or switch to) the esx REPL."
  (interactive)
  (esx-ensure-connection)
  (esx-repl--ensure-buffer)
  (pop-to-buffer esx-repl-buffer))

(defun esx-repl-set-ns (ns &optional update-prompt)
  "Switch the REPL namespace to NS.
When UPDATE-PROMPT is non-nil, rewrite the current prompt."
  (setq esx-repl-ns (esx-ns-resolve ns esx-repl-ns))
  (esx-repl--rename-buffer)
  (when update-prompt
    (esx-repl--update-prompt))
  (message "ESX namespace: %s" (esx--ns-display esx-repl-ns)))

;;;###autoload
(defun esx-jump (&optional prefix)
  "Jump between the source buffer and the REPL.
With PREFIX, use the current buffer namespace instead of the file namespace."
  (interactive "P")
  (if (eq major-mode 'esx-repl-mode)
      (if (buffer-live-p esx--origin-buffer)
          (pop-to-buffer esx--origin-buffer)
        (user-error "No source buffer to return to"))
    (esx-ensure-connection)
    (setq esx--origin-buffer (current-buffer))
    (esx-repl-set-ns (if prefix (esx-current-ns) (esx-default-ns)))
    (esx-repl)))

(provide 'esx-repl)
;;; esx-repl.el ends here
