;;; esx-ns.el --- Namespace helpers for esx -*- lexical-binding: t; -*-

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

;; Two namespaces:
;;   file-ns   derived from `buffer-file-name'
;;   buffer-ns the REPL's current namespace, or a buffer-local override
;;
;; Default eval prefers file-ns; C-u prefers buffer-ns.  See DESIGN.md.

;;; Code:

(require 'esx-client)
(require 'subr-x)
(require 'url-expand nil t)
(require 'url-util)

(defvar esx-repl-ns "user"
  "Current namespace of the esx REPL.")

(defvar-local esx-buffer-ns nil
  "Optional buffer-local namespace override.
When nil, source buffers fall back to the REPL namespace.")

(defun esx-file-url (path)
  "Return a file URL for PATH."
  (concat "file://"
          (replace-regexp-in-string
           " " "%20"
           (expand-file-name path))))

(defun esx-file-ns ()
  "Return the file namespace of the current buffer, or nil."
  (when buffer-file-name
    (esx-file-url buffer-file-name)))

(defun esx-current-ns ()
  "Return the current buffer/REPL namespace."
  (if (eq major-mode 'esx-repl-mode)
      esx-repl-ns
    (or esx-buffer-ns esx-repl-ns "user")))

(defun esx-default-ns ()
  "Return the file-first namespace for the current buffer."
  (or (esx-file-ns) (esx-current-ns)))

(defun esx--ns-display (ns)
  "Return a short display name for NS."
  (if (string-prefix-p "file://" ns)
      (file-name-nondirectory (url-unhex-string (substring ns 7)))
    ns))

(defun esx-ns-resolve (specifier &optional current)
  "Resolve SPECIFIER relative to CURRENT namespace."
  (let ((current (or current esx-repl-ns)))
    (if (or (string-prefix-p "." specifier)
            (string-prefix-p "/" specifier))
        (if (string-prefix-p "file://" current)
            (url-expand-file-name specifier current)
          (esx-file-url specifier))
      specifier)))

(provide 'esx-ns)
;;; esx-ns.el ends here
