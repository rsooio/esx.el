;;; esx-eval.el --- Evaluation and inline results for esx -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;;; Commentary:

;; One eval command: active region, or the top-level node at point.
;; Results are shown as inline overlays; stdout/stderr go to the REPL.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'treesit)
(require 'esx-client)
(require 'esx-ns)
(require 'esx-repl)

(defgroup esx-eval nil
  "Evaluation for esx."
  :group 'esx
  :prefix "esx-eval-")

(defface esx-result-face
  '((t :inherit font-lock-string-face))
  "Face for inline evaluation results."
  :group 'esx-eval)

(defcustom esx-result-max-length 200
  "Maximum number of characters shown in an inline result."
  :type 'integer
  :group 'esx-eval)

(defun esx--ensure-treesit ()
  "Signal an error unless the current buffer has a tree-sitter parser."
  (unless (treesit-parser-list)
    (user-error "ESX needs a tree-sitter parser; use js-ts-mode or typescript-ts-mode")))

(defun esx--code-bounds ()
  "Return the bounds of the code to evaluate.
Use the active region, or the top-level node at point."
  (if (region-active-p)
      (cons (region-beginning) (region-end))
    (esx--ensure-treesit)
    (let ((node (or (treesit-node-at (point))
                    (treesit-node-at (max (point-min) (1- (point)))))))
      (when-let* ((top (and node
                            (treesit-parent-until
                             node
                             (lambda (parent)
                               (member (treesit-node-type
                                        (treesit-node-parent parent))
                                       '("program" "module")))))))
        (cons (treesit-node-start top) (treesit-node-end top))))))

(defun esx--clear-result-overlays (buffer)
  "Remove result overlays from BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (when (overlay-get overlay 'esx-result)
          (delete-overlay overlay))))))

(defun esx--result-text (value)
  "Format VALUE for an inline overlay."
  (let ((text (replace-regexp-in-string "[\n\r]+" " " value)))
    (if (> (length text) esx-result-max-length)
        (concat (substring text 0 esx-result-max-length) "…")
      text)))

(defun esx--display-result (buffer position value)
  "Display VALUE at POSITION in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((overlay (make-overlay position position)))
        (overlay-put overlay 'after-string
                     (propertize (concat " => " (esx--result-text value))
                                 'face 'esx-result-face))
        (overlay-put overlay 'esx-result t)))))

(defun esx--display-error (buffer position error)
  "Display ERROR at POSITION in BUFFER."
  (let ((text (or (esx--error-text error) "Evaluation error")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((overlay (make-overlay position position)))
          (overlay-put overlay 'after-string
                       (propertize (concat " => " (esx--result-text text))
                                   'face 'esx-repl-error-face))
          (overlay-put overlay 'esx-result t))))))

(defun esx--handle-eval-response (buffer position message)
  "Handle one eval response MESSAGE for BUFFER at POSITION."
  (when (esx--has message "out")
    (esx-repl--ensure-buffer)
    (esx-repl--insert-output (esx--get message "out")))
  (when (esx--has message "err")
    (esx-repl--ensure-buffer)
    (esx-repl--insert-output (esx--get message "err") t))
  (when (esx--has message "value")
    (esx--display-result buffer position (esx--get message "value")))
  (when (esx--has message "ex")
    (esx--display-error buffer position (esx--get message "ex"))
    (esx-repl--ensure-buffer)
    (esx-repl--insert-output
     (concat (or (esx--error-text (esx--get message "ex")) "Evaluation error")
             "\n")
     t)))

;;;###autoload
(defun esx-eval (&optional prefix)
  "Evaluate the active region or the top-level node at point.
With PREFIX, use the current buffer namespace instead of the file namespace.
Results are shown inline; stdout/stderr go to the REPL."
  (interactive "P")
  (let ((bounds (esx--code-bounds)))
    (unless bounds
      (user-error "Nothing to evaluate: no region and point is not on a top-level node"))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (code (string-trim (buffer-substring-no-properties start end)))
           (buffer (current-buffer))
           (position (copy-marker end))
           (ns (if prefix (esx-current-ns) (esx-default-ns))))
      (when (string-empty-p code)
        (user-error "Nothing to evaluate"))
      (esx--clear-result-overlays buffer)
      (esx-repl--ensure-buffer)
      (esx-request
       "eval"
       (list (cons "code" code)
             (cons "ns" ns)
             (cons "file" (or buffer-file-name ""))
             (cons "line" (number-to-string (line-number-at-pos start)))
             (cons "column" (number-to-string
                             (save-excursion
                               (goto-char start)
                               (current-column)))))
       (lambda (message)
         (esx--handle-eval-response buffer position message))))))

(provide 'esx-eval)
;;; esx-eval.el ends here
