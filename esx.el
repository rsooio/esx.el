;;; esx.el --- Emacs client for the esx ESM REPL -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: esx.el contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, javascript, repl
;; URL: https://github.com/rsooio/esx.el

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
    (define-key map (kbd "C-c C-o") #'esx-clear-result-overlays)
    (define-key map (kbd "C-c C-g") #'esx-clear-result-overlays)
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
