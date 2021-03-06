(in-package :cl-rabbit)

(define-condition rabbitmq-error (error)
  ()
  (:documentation "General superclass for rabbitmq errors"))

(define-condition rabbitmq-library-error (rabbitmq-error)
  ((error-code        :type keyword
                      :initarg :error-code
                      :reader rabbitmq-library-error/error-code
                      :documentation "The response type as returned by the AMQP call")
   (error-description :type string
                      :initarg :error-description
                      :reader rabbitmq-library-error/error-description))
  (:report (lambda (condition out)
             (format out "AMQP library error: ~a" (rabbitmq-library-error/error-description condition))))
  (:documentation "Error that is raised when an AMQP call fails"))

(defun %check-client-version (name major minor patch)
  (multiple-value-bind (match strings)
      (cl-ppcre:scan-to-strings "^([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-[a-z]+)?$" name)
    (unless match
      (error "Version number reported from library has unexpected format: ~s" name))
    (let ((library-major (parse-integer (aref strings 0)))
          (library-minor (parse-integer (aref strings 1)))
          (library-patch (parse-integer (aref strings 2))))
      (or (> library-major major)
          (and (= library-major major)
               (or (> library-minor minor)
                   (and (= library-minor minor)
                        (>= library-patch patch))))))))

(defun check-client-version (major minor patch)
  (%check-client-version (version) major minor patch))

(defun raise-rabbitmq-library-error (code)
  (let* ((string-ptr (amqp-error-string2 code))
         (description (cffi:foreign-string-to-lisp string-ptr)))
    (error 'rabbitmq-library-error
           :error-code (cffi:foreign-enum-keyword 'amqp-status-enum code)
           :error-description description)))

(define-condition rabbitmq-server-error (rabbitmq-error)
  ((method-id  :type integer
               :initarg :method-id
               :reader rabbitmq-server-error/method-id)
   (class-id  :type integer
               :initarg :class-id
               :reader rabbitmq-server-error/class-id)
   (reply-code :type integer
               :initarg :reply-code
               :initform 0
               :reader rabbitmq-server-error/reply-code)
   (reply-text :type string
               :initarg :message
               :initform "Unknown error"
               :reader rabbitmq-server-error/reply-text))
  (:report (lambda (condition out)
             (format out "RPC error: ~a: ~a"
                     (slot-value condition 'reply-code)
                     (slot-value condition 'message))))
  (:documentation "Error that is raised when the server reports an error condition"))

(defun raise-rabbitmq-server-error (state channel result)
  (declare (ignore state channel))
  (let* ((reply (getf result 'reply))
         (id (getf reply 'id))
         (decoded (getf reply 'decoded)))

    (cond ((eql id +amqp-channel-close-method+)
           (let ((reply-code (cffi:foreign-slot-value decoded '(:struct amqp-channel-close-t) 'reply-code))
                 (reply-text (bytes->string (cffi:foreign-slot-value decoded '(:struct amqp-channel-close-t) 'reply-text)))
                 (class-id (cffi:foreign-slot-value decoded '(:struct amqp-channel-close-t) 'class-id))
                 (method-id (cffi:foreign-slot-value decoded '(:struct amqp-channel-close-t) 'method-id)))
             ;; Send an ack to the server to indicate that the close message was received
             
             (error 'rabbitmq-server-error :method-id method-id :class-id class-id :reply-code reply-code :reply-text reply-text)))

          ((eql id +amqp-connection-close-method+)
           (let ((reply-code (cffi:foreign-slot-value decoded '(:struct amqp-connection-close-t) 'reply-code))
                 (reply-text (bytes->string (cffi:foreign-slot-value decoded '(:struct amqp-connection-close-t) 'reply-text)))
                 (class-id (cffi:foreign-slot-value decoded '(:struct amqp-connection-close-t) 'class-id))
                 (method-id (cffi:foreign-slot-value decoded '(:struct amqp-connection-close-t) 'method-id)))
             (error 'rabbitmq-server-error :method-id method-id :class-id class-id :reply-code reply-code :reply-text reply-text)))
          (t
           (error "WTF?")
           (error 'rabbitmq-server-error)))))

(defclass connection ()
  ((conn     :type cffi:foreign-pointer
             :initarg :conn
             :reader connection/native-connection)
   (closed-p :type t
             :initform nil
             :accessor connection/closed-p))
  (:documentation "Class representing a connection to a RabbitMQ server."))

(defmacro with-state ((state conn) &body body)
  `(progn
     (check-type ,conn connection)
     (let ((,state (connection/native-connection ,conn)))
       ,@body)))

(defclass message ()
  ((body       :type (simple-array (unsigned-byte 8) (*))
               :initarg :body
               :reader message/body)
   (properties :type list
               :initarg :properties
               :reader message/properties)))

(defmethod print-object ((obj message) stream)
  (print-unreadable-object (obj stream :type t :identity nil)
    (if (slot-boundp obj 'body)
        (format stream "LENGTH ~a" (array-dimension (slot-value obj 'body) 0))
        (format stream "NOT-BOUND"))))

(defmethod make-envelope-message ((value list))
  (make-instance 'message
                 :body (bytes->array (getf value 'body))
                 :properties (load-properties-to-plist (getf value 'properties))))

(defmethod make-envelope-message (message)
  (assert (cffi:pointerp message))
  (flet ((getval (slot-name)
           (cffi:foreign-slot-value message '(:struct amqp-message-t) slot-name)))
    (make-instance 'message
                   :body (bytes->array (getval 'body))
                   :properties (load-properties-to-plist (getval 'properties)))))

(defclass envelope ()
  ((channel      :type integer
                 :initarg :channel
                 :reader envelope/channel)
   (consumer-tag :type string
                 :initarg :consumer-tag
                 :reader envelope/consumer-tag)
   (delivery-tag :type integer
                 :initarg :delivery-tag
                 :reader envelope/delivery-tag)
   (redelivered  :type boolean
                 :initarg :redelivered
                 :reader envelope/redelivered)
   (exchange     :type string
                 :initarg :exchange
                 :reader envelope/exchange)
   (routing-key  :type string
                 :initarg :routing-key
                 :reader envelope/routing-key)
   (message      :type message
                 :initarg :message
                 :reader envelope/message)))

(defmethod print-object ((obj envelope) stream)
  (print-unreadable-safely (channel consumer-tag delivery-tag exchange routing-key) obj stream
    (format stream "CHANNEL ~s CONSUMER-TAG ~s DELIVERY-TAG ~s EXCHANGE ~s ROUTING-KEY ~s"
            channel consumer-tag delivery-tag exchange routing-key)))

(defun fail-if-null (ptr)
  (when (cffi-sys:null-pointer-p ptr)
    (error 'rabbitmq-error))
  ptr)

(defun verify-status (status)
  (let ((type (cffi:foreign-enum-keyword 'amqp-status-enum status)))
    (unless (eq type :amqp-status-ok)
      (raise-rabbitmq-library-error status))
    type))

(defun verify-rpc-reply (state channel result)
  (let ((reply-type (cffi:foreign-enum-keyword 'amqp-response-type-enum (getf result 'reply-type))))
    (case reply-type
      (:amqp-response-normal reply-type)
      (:amqp-response-server-exception (raise-rabbitmq-server-error state channel result))
      (:amqp-response-library-exception (raise-rabbitmq-library-error (getf result 'library-error)))
      (t (error "Unexpected error: ~s" reply-type)))))

(defun verify-rpc-framing-call (state channel result)
  (when (cffi:null-pointer-p result)
    (verify-rpc-reply state channel (amqp-get-rpc-reply state))))

(defun maybe-release-buffers (state)
  (amqp-maybe-release-buffers state))

;;;
;;;  API calls
;;;

(defun new-connection ()
  (let ((result (fail-if-null (amqp-new-connection))))
    (make-instance 'connection :conn result)))

(defun destroy-connection (conn)
  (unless (connection/closed-p conn)
    (with-state (state conn)
      (verify-status (amqp-destroy-connection state)))
    (setf (connection/closed-p conn) t)))

(defun tcp-socket-new (conn)
  "Create a new TCP socket.
Call CONNECTION-CLOSE to release socket resources."
  (with-state (state conn)
    (fail-if-null (amqp-tcp-socket-new state))))

(defun ssl-socket-new (conn)
  "Create a new SSL socket.
Call CONNECTION-CLOSE to release socket resources."
  (with-state (state conn)
    (fail-if-null (amqp-ssl-socket-new state))))

(defun ssl-socket-set-cacert (socket cafile)
  (verify-status (amqp-ssl-socket-set-cacert socket cafile)))

(defun ssl-socket-set-key (socket cert key)
  (verify-status (amqp-ssl-socket-set-key socket cert key)))

(defun connection-close (conn &key code)
  "Closes the entire connection.
Implicitly closes all channels and informs the broker the connection
is being closed, after receiving acknowldgement from the broker it closes
the socket.

Parameters:
CONN - the connection object
CODE - the reason code for closing the connection. Defaults to AMQP_REPLY_SUCCESS."
  (check-type code (or null integer))
  (with-state (state conn)
    (verify-rpc-reply state nil (amqp-connection-close state (or code +amqp-reply-success+)))))

(defun socket-open (socket host port)
  "Open a socket connection.
This function opens a socket connection returned from TCP-SOCKET-NEW
or SSL-SOCKET-NEW."
  (check-type host string)
  (check-type port alexandria:positive-integer)
  (verify-status (amqp-socket-open socket host port)))

(defun login-sasl-plain (conn vhost user password
                         &key
                           (channel-max 0) (frame-max 131072) (heartbeat 0) properties)
  "Login to the broker using the SASL PLAIN method.

Parameters:

CONN - The connection object

VHOST - the virtual host to connect to on the broker. The default on
most brokers is \"/\"

CHANNEL-MAX - the limit for the number of channels for the connection.
0 means no limit, and is a good default (AMQP_DEFAULT_MAX_CHANNELS)
Note that the maximum number of channels the protocol supports is
65535 (2^16, with the 0-channel reserved)

FRAME-MAX - the maximum size of an AMQP frame on the wire to request
of the broker for this connection. 4096 is the minimum size, 2^31-1 is
the maximum, a good default is 131072 (128 kB), or
AMQP_DEFAULT_FRAME_SIZE

HEARTBEAT - the number of seconds between heartbeat frame to request
of the broker. A value of 0 disables heartbeats. Note rabbitmq-c only
has partial support for hearts, as of v0.4.0 heartbeats are only
serviced during BASIC-PUBLISH, SIMPLE-WAIT-FRAME and
SIMPLE-WAIT-FRAME-NOBLOCK.

PROPERTIES - a table of properties to send to the broker"
  (check-type vhost string)
  (check-type user string)
  (check-type password string)
  (with-state (state conn)
    (with-amqp-table (table properties)
      (cffi:with-foreign-objects ((native-table '(:struct amqp-table-t)))
        (setf (cffi:mem-ref native-table '(:struct amqp-table-t)) table)
        (let ((reply (amqp-login-sasl-plain-with-properties state vhost channel-max frame-max heartbeat native-table
                                                            (cffi:foreign-enum-value 'amqp-sasl-method-enum
                                                                                     :amqp-sasl-method-plain)
                                                            user password)))
          (verify-rpc-reply state nil reply))))))

(defun channel-open (conn channel)
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-framing-call state nil (amqp-channel-open state channel))
      (maybe-release-buffers state))))

(defun channel-flow (conn channel active)
  "Enable/disable flow from peer.

This method asks the peer to pause or restart the flow of content data
sent by a consumer. This is a simple flow-control mechanism that a
peer can use to avoid overflowing its queues or otherwise finding
itself receiving more messages than it can process. Note that this
method is not intended for window control. It does not affect contents
returned by Basic.Get-Ok methods.

Parameters:
CONN - the connection object
CHANNEL - the channel that should be updated
ACTIVE - a boolean indicating if flow should be enabled or disabled"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (let ((result (amqp-channel-flow state channel (if active 1 0))))
           (verify-rpc-framing-call state channel result)
           (cffi:foreign-slot-value result '(:struct amqp-channel-flow-ok-t) 'active))
      (maybe-release-buffers state))))

(defun channel-flow-ok (conn channel active)
  "Confirms to the peer that a flow command was received and processed."
  (check-type channel integer)
  (with-state (state conn)
    (cffi:with-foreign-objects ((decoded '(:struct amqp-channel-flow-ok-t)))
      (setf (cffi:foreign-slot-value decoded '(:struct amqp-channel-flow-ok-t) 'active) (if active 1 0))
      (amqp-send-method state channel +amqp-channel-flow-ok-method+ decoded))))

(defun channel-close (conn channel &key reply-code)
  "Closes a channel.
Parameters:
CONN - the connection object
CHANNEL - the channel that should be closed
CODE - the reason code, defaults to AMQP_REPLY_SUCCESS"
  (check-type channel integer)
  (check-type reply-code (or null integer))
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-reply state channel (amqp-channel-close state channel (or reply-code +amqp-reply-success+)))
      (maybe-release-buffers state))))

(defun channel-close-ok% (state channel)
  (cffi:with-foreign-objects ((decoded '(:struct amqp-channel-close-ok-t)))
    (setf (cffi:foreign-slot-value decoded '(:struct amqp-channel-close-ok-t) 'dummy) 0)
    (amqp-send-method state channel +amqp-channel-close-ok-method+ decoded)))

(defun channel-close-ok (conn channel)
  "Confirm a CHANNEL close.
This method confirms a Channel.Close method and tells the recipient
that it is safeto release resources for the channel."
  (with-state (state conn)
    (channel-close-ok% state channel)))

(defun connection-close-ok (conn channel)
  "Confirm a CONN close.
This method confirms a Connection.Close method and tells the recipient
that it is safe to release resources for the connection and close the socket."
  (with-state (state conn)
    (cffi:with-foreign-objects ((decoded '(:struct amqp-connection-close-ok-t)))
      (setf (cffi:foreign-slot-value decoded '(:struct amqp-connection-close-ok-t) 'dummy) 0)
      (amqp-send-method state channel +amqp-connection-close-ok-method+ decoded))))

(deftype persistent-mode ()
  `(member t nil))

(defparameter *props-mapping*
  `((:content-type content-type :string string ,+amqp-basic-content-type-flag+)
    (:content-encoding content-encoding :string string ,+amqp-basic-content-encoding-flag+)
    (:persistent delivery-mode :persistent persistent-mode ,+amqp-basic-delivery-mode-flag+)
    (:priority priority :integer (unsigned-byte 8) ,+amqp-basic-priority-flag+)
    (:correlation-id correlation-id :string string ,+amqp-basic-correlation-id-flag+)
    (:reply-to reply-to :string string ,+amqp-basic-reply-to-flag+)
    (:expiration expiration :string string ,+amqp-basic-expiration-flag+)
    (:message-id message-id :string string ,+amqp-basic-message-id-flag+)
    (:timestamp timestamp :timestamp local-time:timestamp ,+amqp-basic-timestamp-flag+)
    (:type type :string string ,+amqp-basic-type-flag+)
    (:user-id user-id :string string ,+amqp-basic-user-id-flag+)
    (:app-id app-id :string string ,+amqp-basic-app-id-flag+)
    (:cluster-id cluster-id :string string ,+amqp-basic-cluster-id-flag+)
    (:headers headers :table list ,+amqp-basic-headers-flag+)))

(defun load-properties-to-alist (props)
  (loop
     with flags = (getf props 'flags)
     for def in *props-mapping*
     when (not (zerop (logand flags (fifth def))))
     collect (let ((value (getf props (second def))))
               (cons (first def)
                     (ecase (third def)
                       (:string (bytes->string value))
                       (:integer value)
                       (:table (amqp-table->lisp value))
                       (:persistent (if (= 2 value) t))
                       (:timestamp (local-time:unix-to-timestamp value)))))))

(defun load-properties-to-plist (props)
  (loop
     with flags = (getf props 'flags)
     for def in *props-mapping*
     when (not (zerop (logand flags (fifth def))))
     append (let ((value (getf props (second def))))
               (list (first def)
                     (ecase (third def)
                       (:string (bytes->string value))
                       (:integer value)
                       (:table (amqp-table->lisp value))
                       (:persistent (if (= 2 value) t))
                       (:timestamp (local-time:unix-to-timestamp value)))))))

(defun fill-in-properties-alist (properties)
  (let ((allocated-values nil)
        (flags 0))
    (labels ((string-native (string)
               (let* ((utf (babel:string-to-octets string :encoding :utf-8))
                      (ptr (array-to-foreign-char-array utf)))
                 (push ptr allocated-values)
                 (list 'len (array-dimension utf 0) 'bytes ptr)))
             (field-table (values)
               (multiple-value-bind (table allocated)
                   (table->amqp-table values)
                 (setq allocated-values (append allocated-values allocated))
                 table))
             (free-and-raise-error (fmt &rest params)
               (dolist (ptr allocated-values)
                 (cffi:foreign-free ptr))
               (apply #'error fmt params)))
      (let ((res (loop
                    for (key . value) in properties
                    for def = (find key *props-mapping* :key #'first)
                    unless def
                    do (free-and-raise-error "Unknown property in alist: ~s" key)
                    unless (typep value (fourth def))
                    do (free-and-raise-error "Illegal type for ~s: ~s. Expected: ~s"
                                             (first def) (type-of value) (fourth def))
                    do (setf flags (logior flags (fifth def)))
                    append (list (second def) (ecase (third def)
                                                (:string (string-native value))
                                                (:integer value)
                                                (:table (field-table value))
                                                (:persistent (if value 2 1))
                                                (:timestamp (local-time:timestamp-to-unix value)))))))
        (values (nconc (list 'flags flags) res)
                allocated-values)))))

(defun basic-ack (conn channel delivery-tag &key multiple)
  "Acknowledges a message.
Does a basic.ack on a received message.

Parameters:
CONN - the connection object
CHANNEL - the channel identifier
MULTIPLE - if true, ack all messages up to this delivery tag, if
false ack only this delivery tag"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (let ((result (amqp-basic-ack state channel delivery-tag (if multiple 1 0))))
           (unless (zerop result)
             (error 'rabbitmq-error)))
      (maybe-release-buffers state))))

(defun basic-nack (conn channel delivery-tag &key multiple requeue)
  "Do a basic.nack.
Actively reject a message, this has the same effect as amqp_basic_reject()
however, amqp_basic_nack() can negatively acknowledge multiple messages with
one call much like amqp_basic_ack() can acknowledge mutliple messages with
one call.

Parameters:
CONN - the connection object
CHANNEL - the channel identifier
DELIVERY-TAG - the delivery tag of the message to reject
MULTIPLE - if true negatively acknowledge all unacknowledged messages on this channel
REQUEUE - indicate to the broker whether it should requeue the message"
  (check-type channel integer)
  (check-type delivery-tag integer)
  (with-state (state conn)
    (unwind-protect
         (verify-status (amqp-basic-nack state channel delivery-tag (if multiple 1 0) (if requeue 1 0)))
      (maybe-release-buffers state))))

(defun basic-qos (conn channel prefetch-size prefetch-count &key global)
  "Specify quality of service.
This method requests a specific quality of service.
The QoS can be specified for the current channel or for all channels on the connection.
The particular properties and semantics of a qos method always
depend on the content class semantics. Though the qos method could in principle apply to both peers,
it is currently meaningful only for the server.

Parameters:
CONN - the connection object
CHANNEL - the channel identifier
PREFETCH-SIZE - specifies the prefetch window size in octets
PREFETCH-COUNT - specifies a prefetch window in terms of whole messages
GLOBAL - if T QoS settings should apply per-channel, if NIL QoS settings should apply per-consumer
(for new consumers on the channel; existing ones being unaffected)"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-framing-call state channel (amqp-basic-qos state channel prefetch-size prefetch-count global))
      (maybe-release-buffers state))))

(defun basic-publish (conn channel &key
                                     exchange routing-key mandatory immediate content-properties
                                     content (encoding :utf-8))
  "Publish a message on an exchange with a routing key.
Note that at the AMQ protocol level basic.publish is an async method:
this means error conditions that occur on the broker (such as
publishing to a non-existent exchange) will not be reflected in the
return value of this function.

Parameters:

CONN - the connection on which to send the message.

CHANNEL - the channel that should be used.

EXCHANGE - the exchange on the broker to publish to

ROUTING-KEY - the routing key to use when publishing the message

MANDATORY - indicate to the broker that the message MUST be routed to
a queue. If the broker cannot do this it should respond with a
basic.reject method

IMMEDIATE - indicate to the broker that the message MUST be delivered
to a consumer immediately. If the broker cannot do this it should
response with a basic.reject method.

CONTENT - can be either a vector of bytes, or a string. If it's a string,
then it will be encoded using ENCODING before sending.

CONTENT-PROPERTIES - indicates an alist of message properties. The
following property keywords are accepted:
:CONTENT-TYPE :CONTENT-ENCODING :DELIVERY-MODE :PRIORITY :CORRELATION-ID 
:REPLY-TO :EXPIRATION :MESSAGE-ID :TIMESTAMP :TYPE :USER-ID :APP-ID :CLUSTER-ID"
  (check-type channel integer)
  (check-type exchange (or null string))
  (check-type routing-key (or null string))
  (check-type content (or null vector string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((exchange-bytes exchange)
                              (routing-key-bytes routing-key))
           (labels ((send-with-properties (data props)
                      (verify-status (amqp-basic-publish state channel exchange-bytes routing-key-bytes
                                                         (if mandatory 1 0) (if immediate 1 0)
                                                         props data)))

                    (send-with-data (data)
                      (if content-properties
                          (cffi:with-foreign-objects ((p '(:struct amqp-basic-properties-t)))
                            (multiple-value-bind (props-list allocated)
                                (fill-in-properties-alist content-properties)
                              (unwind-protect
                                   (progn
                                     (setf (cffi:mem-ref p '(:struct amqp-basic-properties-t)) props-list)
                                     (send-with-properties data p))
                                (free-allocations allocated))))
                          ;; ELSE: No content-properties argument
                          (send-with-properties data (cffi:null-pointer)))))

             (if content
                 (with-bytes-struct (body-val (etypecase content
                                                (string (babel:string-to-octets content :encoding encoding))
                                                (vector content)))
                   (send-with-data body-val))
                 ;; ELSE: content is nil, send a blank struct
                 (send-with-data (list 'len 0 'bytes (cffi-sys:null-pointer))))))
      (maybe-release-buffers state))))

(defun exchange-declare (conn channel exchange &key (type "direct") passive durable auto-delete internal arguments)
  (check-type channel integer)
  (check-type exchange string)
  (check-type type string)
  (let ((version-0-6 (check-client-version 0 6 0)))
    (unless version-0-6
      (when auto-delete
        (error ":AUTO-DELETE is not supported in rabbitmq-c versions before 0.6.0"))
      (when internal
        (error ":INTERNAL is not supported in rabbitmq-c versions before 0.6.0")))
    (with-state (state conn)
      (unwind-protect
           (with-bytes-strings ((exchange-bytes exchange)
                                (type-bytes type))
             (with-amqp-table (table arguments)
               (if version-0-6
                   (verify-rpc-framing-call state channel
                                            (amqp-exchange-declare-0-6 state channel exchange-bytes type-bytes
                                                                       (if passive 1 0) (if durable 1 0)
                                                                       (if auto-delete 1 0) (if internal 1 0)
                                                                       table))
                   (verify-rpc-framing-call state channel
                                            (amqp-exchange-declare-0-5 state channel exchange-bytes type-bytes
                                                                       (if passive 1 0) (if durable 1 0)
                                                                       table)))))
        (maybe-release-buffers state)))))

(defun exchange-delete (conn channel exchange &key if-unused)
  (check-type channel integer)
  (check-type exchange string)
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((exchange-bytes exchange))
           (verify-rpc-framing-call state channel (amqp-exchange-delete state channel exchange-bytes (if if-unused 1 0))))
      (maybe-release-buffers state))))

(defun exchange-bind (conn channel &key destination source routing-key arguments)
  (check-type channel integer)
  (check-type destination (or null string))
  (check-type source (or null string))
  (check-type routing-key (or null string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((destination-bytes destination)
                              (source-bytes source)
                              (routing-key-bytes routing-key))
           (with-amqp-table (table arguments)
             (verify-rpc-framing-call state channel
                                      (amqp-exchange-bind state channel destination-bytes source-bytes
                                                          routing-key-bytes table))))
      (maybe-release-buffers state))))

(defun exchange-unbind (conn channel &key destination source routing-key arguments)
  (check-type channel integer)
  (check-type destination (or null string))
  (check-type source (or null string))
  (check-type routing-key (or null string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((destination-bytes destination)
                              (source-bytes source)
                              (routing-key-bytes routing-key))
           (with-amqp-table (table arguments)
             (verify-rpc-framing-call state channel
                                      (amqp-exchange-unbind state channel destination-bytes source-bytes
                                                            routing-key-bytes table))))
      (maybe-release-buffers state))))

(defun queue-declare (conn channel &key queue passive durable exclusive auto-delete arguments)
  "Declare queue, create if needed.

This method creates or checks a queue. When creating a new queue the
client can specify various properties that control the durability of
the queue and its contents, and the level of sharing for the queue.

This function returns three values: The name of the queue, the number
of messages waiting on the queue, the number of consumers for this
queue."
  (check-type channel integer)
  (check-type queue (or null string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-string (queue-bytes queue)
           (with-amqp-table (table arguments)
             (let ((result (amqp-queue-declare state channel queue-bytes (if passive 1 0) (if durable 1 0)
                                               (if exclusive 1 0) (if auto-delete 1 0) table)))
               (verify-rpc-framing-call state channel result)
               (values (bytes->string (cffi:foreign-slot-value result
                                                               '(:struct amqp-queue-declare-ok-t)
                                                               'queue))
                       (cffi:foreign-slot-value result '(:struct amqp-queue-declare-ok-t) 'message-count)
                       (cffi:foreign-slot-value result '(:struct amqp-queue-declare-ok-t) 'consumer-count)))))
      (maybe-release-buffers state))))

(defun queue-bind (conn channel &key queue exchange routing-key arguments)
  "Bind queue to an exchange.

This method binds a queue to an exchange. Until a queue is bound it
will not receive any messages. In a classic messaging model,
store-and-forward queues are bound to a direct exchange and
subscription queues are bound to a topic exchange."
  (check-type channel integer)
  (check-type queue (or null string))
  (check-type exchange (or null string))
  (check-type routing-key (or null string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((queue-bytes queue)
                              (exchange-bytes exchange)
                              (routing-key-bytes routing-key))
           (with-amqp-table (table arguments)
             (verify-rpc-framing-call state channel
                                      (amqp-queue-bind state channel queue-bytes exchange-bytes
                                                       routing-key-bytes table))))
      (maybe-release-buffers state))))

(defun queue-unbind (conn channel &key queue exchange routing-key arguments)
  (check-type channel integer)
  (check-type queue (or null string))
  (check-type exchange (or null string))
  (check-type routing-key (or null string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((queue-bytes queue)
                              (exchange-bytes exchange)
                              (routing-key-bytes routing-key))
           (with-amqp-table (table arguments)
             (verify-rpc-framing-call state channel
                                      (amqp-queue-unbind state channel queue-bytes exchange-bytes
                                                         routing-key-bytes table))
             nil))
      (maybe-release-buffers state))))

(defun queue-purge (conn channel &key (queue ""))
  (check-type channel integer)
  (check-type queue string)
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((queue-bytes queue))
           (let ((result (amqp-queue-purge state channel queue-bytes)))
             (verify-rpc-framing-call state channel result)
             (cffi:foreign-slot-value result '(:struct amqp-queue-purge-ok-t) 'message-count)))
      (maybe-release-buffers state))))

(defun queue-delete (conn channel &key (queue "") if-unused if-empty)
  (check-type channel integer)
  (check-type queue string)
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((queue-bytes queue))
           (let ((result (amqp-queue-delete state channel queue-bytes (if if-unused 1 0) (if if-empty 1 0))))
             (verify-rpc-framing-call state channel result)
             (cffi:foreign-slot-value result '(:struct amqp-queue-delete-ok-t) 'message-count)))
      (maybe-release-buffers state))))

(defun basic-consume (conn channel queue &key consumer-tag no-local no-ack exclusive arguments)
  (check-type channel integer)
  (check-type queue string)
  (check-type consumer-tag (or null string))
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((queue-bytes queue)
                              (consumer-tag-bytes consumer-tag))
           (with-amqp-table (table arguments)
             (let ((result (amqp-basic-consume state channel queue-bytes consumer-tag-bytes
                                               (if no-local 1 0) (if no-ack 1 0) (if exclusive 1 0) table)))
               (verify-rpc-framing-call state channel result)
               (bytes->string (cffi:foreign-slot-value result '(:struct amqp-basic-consume-ok-t) 'consumer-tag)))))
      (maybe-release-buffers state))))

(defun confirm-select (conn channel)
  "Put CHANNEL in confirm mode
Parameters:
CONN - the connection object
CHANNEL - the channel that should be put in confirm mode"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-framing-call state channel (amqp-confirm-select state channel))
      (maybe-release-buffers state))))

(defun tx-select (conn channel)
  "Put CHANNEL in transaction mode
Parameters:
CONN - the connection object
CHANNEL - the channel that should be put in transaction mode"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-framing-call state channel (amqp-tx-select state channel))
      (maybe-release-buffers state))))

(defun tx-commit (conn channel)
  "Commit the current transaction.
Parameters:
CONN - the connection object
CHANNEL - transaction"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-framing-call state channel (amqp-tx-commit state channel))
      (maybe-release-buffers state))))

(defun tx-rollback (conn channel)
  "Abandon the current transaction.
Parameters:
CONN - the connection object
CHANNEL - transaction channel"
  (check-type channel integer)
  (with-state (state conn)
    (unwind-protect
         (verify-rpc-framing-call state channel (amqp-tx-rollback state channel))
      (maybe-release-buffers state))))

(defun consume-message (conn &key timeout)
  "Wait for and consume a message.
Waits for a basic.deliver method on any channel, upon receipt of
basic.deliver it reads that message, and returns. If any other method
is received before basic.deliver, this function will raise a
RABBITMQ-LIBRARY-ERROR with its error code set
to :AMQP-UNEXPECTED-FRAME. The caller should then call
amqp_simple_wait_frame() to read this frame and take appropriate
action.

This function should be used after starting a consumer with the
BASIC-CONSUME function.

This function returns an instance of ENVELOPE that contains the
consumed message.

Parameters:

CONN - the connection object

TIMEOUT - the number of microseconds to wait for a message delivery.
Passing in NIL will result in blocking behavior."
  (check-type timeout (or null integer))
  (with-state (state conn)
    (unwind-protect
         (with-foreign-timeval (native-timeout timeout)
           (cffi:with-foreign-objects ((envelope '(:struct amqp-envelope-t)))
             (verify-rpc-reply state nil (amqp-consume-message state envelope native-timeout 0))
             (unwind-protect
                  (flet ((getval (slot-name)
                           (cffi:foreign-slot-value envelope '(:struct amqp-envelope-t) slot-name)))
                    (make-instance 'envelope
                                   :channel (getval 'channel)
                                   :consumer-tag (bytes->string (getval 'consumer-tag))
                                   :delivery-tag (getval 'delivery-tag)
                                   :redelivered (getval 'redelivered)
                                   :exchange (bytes->string (getval 'exchange))
                                   :routing-key (bytes->string (getval 'routing-key))
                                   :message (make-envelope-message (getval 'message))))
               (amqp-destroy-envelope envelope))))
      (maybe-release-buffers state))))

(defun basic-cancel (conn channel consumer-tag)
  (check-type channel integer)
  (check-type consumer-tag string)
  (with-state (state conn)
    (unwind-protect
         (with-bytes-strings ((consumer-tag-bytes consumer-tag))
           (verify-rpc-framing-call state channel (amqp-basic-cancel state channel consumer-tag-bytes)))
      (maybe-release-buffers state))))

;; Currently disabled, since it leaves the input buffer in an unpredictable state
#+nil
(defun basic-get (conn channel queue &key no-ack)
  "Do a basic.get
Synchonously polls the broker for a message in a queue, and
retrieves the message if a message is in the queue.

Parameters:
CONN - the connection object
CHANNEL - the channel identifier to use
QUEUE - the queue name to receive from
NO-ACK if true the message is automatically ack'ed
if false amqp_basic_ack should be called once the message
retrieved has been processed"
  (check-type channel int)
  (check-type queue string)
  (with-state (state conn)
    (unwind-protect
         (with-bytes-string (queue-bytes queue)
           (verify-rpc-reply state (amqp-basic-get state channel queue-bytes (if no-ack 1 0))))
      (maybe-release-buffers state))))

(defun data-in-buffer (conn)
  (with-state (state conn)
    (unwind-protect
         (not (zerop (amqp-data-in-buffer state)))
      (maybe-release-buffers state))))

(defun frames-enqueued (conn)
  (with-state (state conn)
    (unwind-protect
         (not (zerop (amqp-frames-enqueued state)))
      (maybe-release-buffers state))))

(defun get-sockfd (conn)
  (with-state (state conn)
    (amqp-get-sockfd state)))

(defmacro with-connection ((conn) &body body)
  (let ((conn-sym (gensym "CONN-")))
    `(let ((,conn-sym (new-connection)))
       (unwind-protect
            (let ((,conn ,conn-sym))
              ,@body)
         (destroy-connection ,conn-sym)))))

(defun version ()
  (amqp-version))
