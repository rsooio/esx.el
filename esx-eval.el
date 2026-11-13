;;; esx-eval.el --- Evaluation and inline results for esx -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
  '((((class color) (background light))
     :inherit font-lock-string-face
     :background "grey90"
     :box (:line-width -1 :color "yellow"))
    (((class color) (background dark))
     :inherit font-lock-string-face
     :background "grey10"
     :box (:line-width -1 :color "black"))
    (t :inherit font-lock-string-face))
  "Face for inline evaluation results."
  :group 'esx-eval)

(defface esx-error-overlay-face
  '((((class color) (background light))
     :background "orange red"
     :foreground "white"
     :extend t)
    (((class color) (background dark))
     :background "firebrick"
     :foreground "white"
     :extend t)
    (t :inherit error))
  "Face for inline evaluation errors."
  :group 'esx-eval)

(defcustom esx-result-max-length 200
  "Maximum number of characters shown in an inline result."
  :type 'integer
  :group 'esx-eval)

(defvar-local esx--result-overlays nil
  "Result overlays created in this buffer.")

(defun esx--ensure-result-hooks ()
  "Install the buffer-local overlay cleanup hook."
  (add-hook 'after-change-functions
            #'esx--clear-result-overlays-on-change nil t))

(defun esx--clear-result-overlays (&optional buffer)
  "Remove result overlays from BUFFER (default: current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (dolist (overlay esx--result-overlays)
      (when (overlayp overlay)
        (delete-overlay overlay)))
    (setq esx--result-overlays nil)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (overlay-get overlay 'esx-result)
        (delete-overlay overlay)))))

(defun esx--clear-result-overlays-on-change (&rest _)
  "Clear result overlays after the buffer text changes."
  (esx--clear-result-overlays))

(defun esx-clear-result-overlays ()
  "Clear inline evaluation results in the current buffer."
  (interactive)
  (esx--clear-result-overlays)
  (message "ESX results cleared"))

(defun esx--clear-results-on-quit ()
  "Clear result overlays when `C-g' runs `keyboard-quit'.
Do nothing when a region is selected: `C-g' is then cancelling the
selection, not dismissing evaluation results."
  (when (and (eq this-command 'keyboard-quit)
             (not (use-region-p)))
    (ignore-errors (esx--clear-result-overlays))))

(add-hook 'pre-command-hook #'esx--clear-results-on-quit)

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
      (esx--ensure-result-hooks)
      (let ((overlay (make-overlay position position)))
        (overlay-put overlay 'after-string
                     (propertize (concat " => " (esx--result-text value))
                                 'face 'esx-result-face))
        (overlay-put overlay 'esx-result t)
        (push overlay esx--result-overlays)))))

(defun esx--display-error (buffer position error)
  "Display ERROR at POSITION in BUFFER."
  (let ((text (or (esx--error-text error) "Evaluation error")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (esx--ensure-result-hooks)
        (let ((overlay (make-overlay position position)))
          (overlay-put overlay 'after-string
                       (propertize (concat " => " (esx--result-text text))
                                   'face 'esx-error-overlay-face))
          (overlay-put overlay 'esx-result t)
          (push overlay esx--result-overlays))))))

(defun esx--buffer-unchanged-p (buffer tick)
  "Return non-nil when BUFFER is live and has not changed since TICK."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (= tick (buffer-chars-modified-tick)))))

(defun esx--handle-eval-response (buffer position tick message)
  "Handle one eval response MESSAGE for BUFFER at POSITION.
TICK is the buffer modification tick captured when the eval started."
  (when (esx--has message "out")
    (esx-repl--ensure-buffer)
    (esx-repl--insert-output (esx--get message "out")))
  (when (esx--has message "err")
    (esx-repl--ensure-buffer)
    (esx-repl--insert-output (esx--get message "err") t))
  (when (esx--has message "value")
    (if (esx--buffer-unchanged-p buffer tick)
        (esx--display-result buffer position (esx--get message "value"))
      (message "ESX: result discarded because the buffer changed")))
  (when (esx--has message "ex")
    (if (esx--buffer-unchanged-p buffer tick)
        (esx--display-error buffer position (esx--get message "ex"))
      (message "ESX: error discarded because the buffer changed"))
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
           (tick (buffer-chars-modified-tick))
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
         (esx--handle-eval-response buffer position tick message))
       esx-eval-timeout))))

(provide 'esx-eval)
;;; esx-eval.el ends here
