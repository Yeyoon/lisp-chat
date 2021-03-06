;; Common Lisp Script
;; Manoel Vilela

(defpackage :lisp-chat-server
  (:use :usocket :cl :lisp-chat-config :sb-thread)
  (:export :main))

(in-package :lisp-chat-server)


;; global vars
(defvar *day-names* '("Monday" "Tuesday" "Wednesday"
                      "Thursday" "Friday" "Saturday" "Sunday"))
(defvar *uptime* (multiple-value-list (get-decoded-time)))
(defparameter *commands-names* '("/users" "/help" "/log" "/quit" "/uptime"))
(defparameter *clients* nil)
(defparameter *messages-stack* nil)
(defparameter *messages-log* nil)
(defparameter *server-nickname* "@server")

;; thread control
(defvar *message-semaphore* (make-semaphore :name "message semaphore"
                                                      :count 0))
(defvar *client-mutex* (make-mutex :name "client list mutex"))



(defstruct message
  "This structure abstract the type message with is saved
   into *messages-log* and until consumed, temporally pushed
   to *messages-stack*. FROM, CONTENT and TIME has type string"
  from
  content
  time )

(defstruct client
  "This structure handle the creation/control of the clients of the server.
   NAME is a string. Socket is a USOCKET:SOCKET and address is a ipv4 encoded
   string. "
  name
  socket
  address)


(defun socket-peer-address (socket)
  "Given a USOCKET:SOCKET instance return a ipv4 encoded IP string"
  (format nil "~{~a~^.~}\:~a"
          (map 'list #'identity (get-peer-address socket))
          (get-peer-port socket)))

(defun client-stream (c)
  "Select the stream IO from the client"
  (socket-stream (client-socket c)))


(defun debug-format (&rest args)
  "If *debug* from lisp-chat-config is true, print debug info on
   running based on ARGS"
  (if *debug*
      (apply #'format args)))


(defun get-time ()
  "Return a encoded string as HH:MM:SS based on the current timestamp."
  (multiple-value-bind (second minute hour)
      (get-decoded-time)
    (format nil "~2,'0d:~2,'0d:~2,'0d" hour minute second)))


(defun formated-message (message)
  "The default message format of this server. MESSAGE is a string
   Changing this reflects all the layout from client/server.
   Probably this would be the MFRP: Manoel Fucking Raw Protocol.
   Because this we can still use netcat as client for lisp-chat."
  (format nil "|~a| [~a]: ~a"
          (message-time message)
          (message-from message)
          (message-content message)))

(defun command-message (content)
  "This function prepare the CONTENT as a message by the @server"
  (let* ((from *server-nickname*)
         (time (get-time))
         (message (make-message :from from :content content :time time)))
    (formated-message message)))

(defun call-command-by-name (string)
  "Wow, this is a horrible hack to get a string as symbol for functions/command
  like /help /users /log and so on."
  (funcall (find-symbol (string-upcase string) :lisp-chat-server)))

;; user commands prefixed with /
(defun /users ()
  "Return a list separated by commas of the currently logged users"
  (command-message (format nil "~{~a~^, ~}" (mapcar #'client-name *clients*))))


(defun /help ()
  "Show a list of the available commands of lisp-chat"
  (command-message (format nil "~{~a~^, ~}" *commands-names*)))


(defun /log (&optional (depth 20))
  "Show the last messages typed on the server.
   DEPTH is optional number of messages frames from log"
  (format nil "~{~a~^~%~}" (reverse (subseq *messages-log* 0
                                            (min depth (length *messages-log*))))))

(defun /uptime ()
  "Return a string nice encoded to preset the uptime since the server started."
  (multiple-value-bind
        (second minute hour date month year day-of-week dst-p tz)
      (values-list *uptime*)
    (declare (ignore dst-p))
    (command-message
     (format nil
             "Server online since ~2,'0d:~2,'0d:~2,'0d of ~a, ~2,'0d/~2,'0d/~d (GMT~@d)"
             hour minute second
             (nth day-of-week *day-names*)
             month date year
             (- tz)))))


(defun push-message (from content)
  "Push a messaged FROM as CONTENT into the *messages-stack*"
  (push (make-message :from from
                      :content content
                      :time (get-time))
        *messages-stack*)
  (signal-semaphore *message-semaphore*))

(defun client-delete (client)
  "Delete a CLIENT from the list *clients*"
  (with-mutex (*client-mutex*)
    (setf *clients* (remove-if (lambda (c)
                                 (equal (client-address c)
                                        (client-address client)))
                               *clients*)))
  (push-message "@server" (format nil "The user ~s exited from the party :("
                                  (client-name client)))
  (debug-format t "Deleted user ~a@~a~%"
                (client-name client)
                (client-address client))
  (socket-close (client-socket client)))

(defun send-message (client message)
  "Send to CLIENT a MESSAGE :type string"
  (let ((stream (client-stream client)))
    (write-line message stream)
    (finish-output stream)))

(defun client-reader-routine (client)
  "This function create a IO-bound procedure to act
   by reading the events of a specific CLIENT.
   On this software each client talks on your own thread."
  (loop for message = (read-line (client-stream client))
        while (not (equal message "/quit"))
        if (member message *commands-names* :test #'equal)
          do (send-message client (call-command-by-name message))
        else
          when (> (length message) 0)
            do (push-message (client-name client)
                             message)
        finally (client-delete client)))

(defun client-reader (client)
  "This procedure is a wrapper for CLIENT-READER-ROUTINE
   treating all the possible errors based on HANDLER-CASE macro."
  (handler-case (client-reader-routine client)
    (end-of-file () (client-delete client))
    (sb-int:simple-stream-error ()
      (progn (debug-format t "~a@~a timed output"
                           (client-name client)
                           (client-address client))
             (client-delete client)))
    (sb-bsd-sockets:not-connected-error ()
      (progn (debug-format t "~a@~a not connected more."
                           (client-name client)
                           (client-address client))
             (client-delete client)))))

(defun create-client (connection)
  "This procedure create a new client based on CONNECTION made by
  USOCKET:SOCKET-ACCEPT. This shit create a lot of side effects as messages
  if the debug is on because this makes all the log stuff to make analysis"
  (debug-format t "Incoming connection from ~a ~%" (socket-peer-address connection))
  (let ((client-stream (socket-stream connection)))
    (write-line "> Type your username: " client-stream)
    (finish-output client-stream)
    (let ((client (make-client :name (read-line client-stream)
                               :socket connection
                               :address (socket-peer-address connection))))
      (with-mutex (*client-mutex*)
        (debug-format t "Added new user ~a@~a ~%"
                      (client-name client)
                      (client-address client))
        (push client *clients*))
      (push-message "@server" (format nil "The user ~s joined to the party!" (client-name client)))
      (make-thread #'client-reader
                             :name (format nil "~a reader thread" (client-name client))
                             :arguments (list client)))))

;; a function defined to handle the errors of client thread
(defun safe-client-thread (connection)
  "This function is a wrapper for CREATE-CLIENT treating the
exceptions."
  (handler-case (create-client connection)
    (end-of-file () nil)
    (usocket:address-in-use-error () nil)))

(defun message-broadcast ()
  "This procedure is a general independent thread to run brodcasting
   all the clients when a message is ping on this server"
  (loop when (wait-on-semaphore *message-semaphore*)
          do (let ((message (formated-message (pop *messages-stack*))))
               (push message *messages-log*)
               (loop for client in *clients*
                     do (handler-case (send-message client message)
                          (sb-int:simple-stream-error () (client-delete client))
                          (sb-bsd-sockets:not-connected-error () (client-delete client)))))))

(defun connection-handler (socket-server)
  "This is a special thread just for accepting connections from SOCKET-SERVER
   and creating new clients from it."
  (loop for connection = (socket-accept socket-server)
        do (make-thread #'safe-client-thread
                        :arguments (list connection)
                        :name "create client")))

(defun server-loop (socket-server)
  "This is the general server-loop procedure. Create the threads
   necessary for the basic working state of this chat. The main idea
   is creating a MESSAGE-BROADCAST procedure and CONNECTION-HANDLER
   procedure running as separated threads.

   The first procedure send always a new message too all clients
   defined on *clients* when *messages-semaphore* is signalized.
   The second procedure is a general connection-handler for new
   clients trying connecting to the server."
  (format t "Running server... ~%")
  (let* ((connection-thread (make-thread #'connection-handler
                                                   :arguments (list socket-server)
                                                   :name "Connection handler"))
         (broadcast-thread (make-thread #'message-broadcast
                                                  :name "Message broadcast")))
    (join-thread connection-thread)
    (join-thread broadcast-thread)))

(defun main ()
  "Well, this function run all the necessary shits."
  (let ((socket-server (socket-listen *host* *port*)))
    (unwind-protect (handler-case (server-loop socket-server)
                      (usocket:address-in-use-error ()
                        (format t "Address ~a\@~a already busy."
                                *host*
                                *port*))
                      (sb-sys:interactive-interrupt ()
                        (format t "Closing the server...")))
      (socket-close socket-server))))
