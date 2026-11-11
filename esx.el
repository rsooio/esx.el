;;; esx.el --- Emacs client for the esx ESM REPL -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: esx.el contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, javascript, repl
;; URL: https://example.invalid/esx.el

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Minimal CIDER/SLIME-style runtime client for esx:
;;   C-M-x    evaluate the region or top-level node; inline overlay
;;   C-c C-z  jump between the source buffer and the REPL
;;
;; Language intelligence is left to the JS/TS LSP setup.

;;; Code:

(require 'esx-client)
(require 'esx-ns)
(require 'esx-repl)
(require 'esx-eval)

(defgroup esx nil
  "Emacs client for the esx ESM REPL."
  :group 'languages
  :prefix "esx-")

(defvar esx-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-x") #'esx-eval)
    (define-key map (kbd "C-c C-z") #'esx-jump)
    map)
  "Keymap for `esx-mode'.")

;;;###autoload
(define-minor-mode esx-mode
  "Minor mode for evaluating JavaScript into an esx server."
  :lighter " ESX"
  :keymap esx-mode-map)

;;;###autoload
(defun esx-ensure ()
  "Start the esx server and open the REPL if necessary."
  (interactive)
  (esx-ensure-connection)
  (esx-repl))

;;;###autoload
(defun esx-shutdown ()
  "Stop the esx server and kill the REPL buffer."
  (interactive)
  (esx-stop)
  (when (buffer-live-p esx-repl-buffer)
    (kill-buffer esx-repl-buffer))
  (setq esx-repl-buffer nil
        esx--origin-buffer nil
        esx-repl-ns "user")
  (message "ESX stopped"))

;;;###autoload
(defun esx-restart ()
  "Restart the esx server and open the REPL."
  (interactive)
  (esx-shutdown)
  (esx-ensure))

(defun esx-setup ()
  "Enable `esx-mode' in JavaScript and TypeScript tree-sitter buffers."
  (add-hook 'js-ts-mode-hook #'esx-mode)
  (add-hook 'typescript-ts-mode-hook #'esx-mode))

(provide 'esx)
;;; esx.el ends here
