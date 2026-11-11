;;; esx-client.el --- JSON-lines client for esx -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Process and request handling for the esx server.  The protocol is
;; newline-delimited JSON: each request has an `id' and an `op', and
;; responses carry the same `id' plus a `status' array.  A response with
;; \"done\" in `status' terminates the request.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup esx nil
  "Emacs client for the esx ESM REPL."
  :group 'languages
  :prefix "esx-")

(defcustom esx-server-command '("esx" "--server")
  "Command used to start the esx server.
For a local checkout, use something like
  (\"node\" \"/path/to/esx/cli.ts\" \"--server\")."
  :type '(repeat string)
  :group 'esx)

(defcustom esx-connection-timeout 10
  "Seconds to wait for the esx server hello message."
  :type 'number
  :group 'esx)

(defcustom esx-request-timeout 10
  "Seconds to wait for a synchronous esx request."
  :type 'number
  :group 'esx)

(defcustom esx-eval-timeout 30
  "Seconds to wait for an asynchronous eval response."
  :type 'number
  :group 'esx)

(cl-defstruct (esx-connection (:constructor esx--make-connection))
  process
  buffer
  pending
  next-id
  hello
  ns)

(defvar esx--connection nil
  "The current esx connection, or nil.")

(defvar esx--stopping nil
  "Non-nil while `esx-stop' is intentionally closing the process.")

(defvar esx-output-functions nil
  "Functions called with (TEXT IS-ERROR) for unsolicited server output.")

(defun esx-connected-p ()
  "Return non-nil when an esx server process is running."
  (and esx--connection
       (process-live-p (esx-connection-process esx--connection))))

(defun esx--has (alist key)
  "Return the cons cell for KEY in ALIST.
JSON parsing uses symbol keys, while requests use string keys."
  (or (assoc (intern key) alist)
      (assoc key alist)))

(defun esx--get (alist key &optional default)
  "Get KEY from ALIST, a JSON object."
  (let ((pair (esx--has alist key)))
    (if pair (cdr pair) default)))

(defun esx--status-p (message status)
  "Return non-nil when MESSAGE has STATUS in its status array."
  (member status (esx--get message "status")))

(defun esx--response-value (messages)
  "Return the last `value' from MESSAGES."
  (let (value)
    (dolist (message messages value)
      (when (esx--has message "value")
        (setq value (esx--get message "value"))))))

(defun esx--response-error (messages)
  "Return the first `ex' object from MESSAGES."
  (when-let* ((message (seq-find (lambda (m) (esx--has m "ex")) messages)))
    (esx--get message "ex")))

(defun esx--error-text (error)
  "Format ERROR, an `ex' object, as a human-readable string."
  (when error
    (let ((name (or (esx--get error "name") "Error"))
          (message (or (esx--get error "message") ""))
          (line (esx--get error "line"))
          (column (esx--get error "column")))
      (concat (format "%s: %s" name message)
              (when line (format " (%s:%s)" line (or column 0)))))))

(defun esx--send-message (connection message)
  "Send MESSAGE to CONNECTION."
  (let ((process (esx-connection-process connection)))
    (unless (process-live-p process)
      (error "ESX server is not running"))
    (process-send-string process (concat (json-encode message) "\n"))))

(defun esx--next-id (connection)
  "Return the next request id for CONNECTION."
  (number-to-string (cl-incf (esx-connection-next-id connection))))

(defun esx--request-message (id op params)
  "Build a request message with ID, OP, and PARAMS."
  (append (list (cons "id" id) (cons "op" op)) params))

(defun esx-request (op params &optional callback timeout)
  "Send an asynchronous request OP with PARAMS.
CALLBACK is called with each response message.  Return the request id.
TIMEOUT defaults to `esx-request-timeout'."
  (let* ((connection (esx-ensure-connection))
         (id (esx--next-id connection))
         (callback (or callback #'ignore))
         (timer (run-at-time
                 (or timeout esx-request-timeout) nil
                 (lambda ()
                   (when (gethash id (esx-connection-pending connection))
                     (remhash id (esx-connection-pending connection))
                     (funcall callback
                              (list (cons "id" id)
                                    (cons "status" '("error" "done"))
                                    (cons "ex"
                                          (list (cons "name" "TimeoutError")
                                                (cons "message"
                                                      (format "ESX request timed out: %s" op))
                                                (cons "stack" ""))))))))))
    (puthash id
             (lambda (message)
               (when (esx--status-p message "done")
                 (cancel-timer timer))
               (funcall callback message))
             (esx-connection-pending connection))
    (esx--send-message connection (esx--request-message id op params))
    id))

(defun esx-request-sync (op params &optional timeout)
  "Send OP with PARAMS and wait for the final response.
Return the list of response messages.  Signal an error on timeout."
  (let* ((connection (esx-ensure-connection))
         (id (esx--next-id connection))
         (done nil)
         (messages nil)
         (callback (lambda (message)
                     (push message messages)
                     (when (esx--status-p message "done")
                       (setq done t)))))
    (puthash id callback (esx-connection-pending connection))
    (esx--send-message connection (esx--request-message id op params))
    (let ((deadline (+ (float-time) (or timeout esx-request-timeout)))
          (process (esx-connection-process connection)))
      (while (and (not done) (< (float-time) deadline))
        (unless (process-live-p process)
          (remhash id (esx-connection-pending connection))
          (error "ESX server exited during request %s" op))
        (accept-process-output process 0.05))
      (unless done
        (remhash id (esx-connection-pending connection))
        (error "ESX request timed out: %s" op))
      (nreverse messages))))

(defun esx--dispatch-unsolicited (message)
  "Handle a response MESSAGE that has no pending request."
  (let ((text (or (esx--get message "out") (esx--get message "err"))))
    (when text
      (run-hook-with-args 'esx-output-functions text (esx--has message "err")))))

(defun esx--dispatch (process message)
  "Dispatch one decoded protocol MESSAGE from PROCESS."
  (let ((connection esx--connection))
    (unless (and connection
                 (or (null (esx-connection-process connection))
                     (eq process (esx-connection-process connection))))
      (setq connection nil))
    (cond
     ((equal (esx--get message "op") "hello")
      (when connection
        (setf (esx-connection-hello connection) message)))
     (connection
      (let ((id (esx--get message "id")))
        (if id
            (let ((callback (gethash id (esx-connection-pending connection))))
              (when callback
                (condition-case err
                    (funcall callback message)
                  (error (message "ESX callback error: %s"
                                  (error-message-string err))))
                (when (esx--status-p message "done")
                  (remhash id (esx-connection-pending connection)))))
          (esx--dispatch-unsolicited message))))
     (t
      (esx--dispatch-unsolicited message)))))

(defun esx--process-buffer (process)
  "Parse complete JSON lines from PROCESS's buffer."
  (with-current-buffer (process-buffer process)
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (let ((line (buffer-substring-no-properties (point-min) (1- (point)))))
        (delete-region (point-min) (point))
        (unless (string-empty-p (string-trim line))
          (condition-case err
              (esx--dispatch process
                             (json-parse-string line
                                                :object-type 'alist
                                                :array-type 'list
                                                :null-object nil
                                                :false-object nil))
            (error (message "ESX protocol error: %s"
                            (error-message-string err)))))))))

(defun esx--filter (process chunk)
  "Process filter for the esx server PROCESS."
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (insert chunk))
  (esx--process-buffer process))

(defun esx--fail-pending (connection reason)
  "Fail all pending requests in CONNECTION with REASON."
  (let ((pending (esx-connection-pending connection))
        ids)
    (maphash (lambda (id _callback) (push id ids)) pending)
    (dolist (id ids)
      (let ((callback (gethash id pending)))
        (when callback
          (funcall callback
                   (list (cons "id" id)
                         (cons "status" '("error" "done"))
                         (cons "ex" (list (cons "name" "ConnectionError")
                                          (cons "message" reason))))))
        (remhash id pending)))))

(defun esx--sentinel (process event)
  "Handle PROCESS state changes with EVENT."
  (unless (process-live-p process)
    (let ((connection esx--connection))
      (when (and connection (eq process (esx-connection-process connection)))
        (esx--fail-pending connection (format "ESX server exited: %s" event))
        (unless (or esx--stopping (process-get process 'esx-stopping))
          (message "ESX server exited: %s" event))))))

(defun esx--wait-for-hello (connection)
  "Wait until CONNECTION receives the server hello message."
  (let ((deadline (+ (float-time) esx-connection-timeout))
        (process (esx-connection-process connection)))
    (while (and (not (esx-connection-hello connection))
                (< (float-time) deadline))
      (unless (process-live-p process)
        (error "ESX server failed to start"))
      (accept-process-output process 0.05))
    (unless (esx-connection-hello connection)
      (error "Timed out waiting for the ESX server (output: %S)"
             (when (buffer-live-p (esx-connection-buffer connection))
               (with-current-buffer (esx-connection-buffer connection)
                 (buffer-string)))))
    (esx-connection-hello connection)))

(defun esx-start (&optional command)
  "Start an esx server using COMMAND.
Return the new connection."
  (when (esx-connected-p)
    (esx-stop))
  (let* ((command (or command esx-server-command))
         (process-buffer (generate-new-buffer " *esx-process*"))
         (stderr-buffer (get-buffer-create " *esx-stderr*"))
         (connection (esx--make-connection
                      :buffer process-buffer
                      :pending (make-hash-table :test #'equal)
                      :next-id 0
                      :ns "user")))
    ;; Install the connection before starting the process: the hello
    ;; message can arrive before `make-process' returns.
    (setq esx--connection connection)
    (condition-case err
        (let ((process (make-process
                        :name "esx"
                        :buffer process-buffer
                        :command command
                        :connection-type 'pipe
                        :coding 'utf-8-unix
                        :noquery t
                        :filter #'esx--filter
                        :sentinel #'esx--sentinel
                        :stderr stderr-buffer)))
          (setf (esx-connection-process connection) process)
          (esx--wait-for-hello connection)
          connection)
      (error
       (when-let* ((process (and connection
                                 (esx-connection-process connection))))
         (when (process-live-p process)
           (process-put process 'esx-stopping t)
           (delete-process process)))
       (setq esx--connection nil)
       (when (buffer-live-p process-buffer)
         (kill-buffer process-buffer))
       (signal (car err) (cdr err))))))

(defun esx-stop ()
  "Stop the current esx server and clear the connection."
  (interactive)
  (let ((esx--stopping t))
    (when esx--connection
      (let ((process (esx-connection-process esx--connection))
            (buffer (esx-connection-buffer esx--connection)))
        (when (process-live-p process)
          (process-put process 'esx-stopping t)
          (delete-process process))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    (setq esx--connection nil)))

(defun esx-ensure-connection ()
  "Return the current connection, starting a server if necessary."
  (if (esx-connected-p)
      esx--connection
    (esx-start)))

(defun esx-ping ()
  "Ping the esx server."
  (interactive)
  (let ((messages (esx-request-sync "ping" nil)))
    (message "ESX: %s" (or (esx--response-value messages) "no response"))))

(provide 'esx-client)
;;; esx-client.el ends here
