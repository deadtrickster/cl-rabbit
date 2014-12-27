(in-package :cl-rabbit.examples)

(defun test-send ()
  (with-connection (conn)
    (let ((socket (tcp-socket-new conn)))
      (socket-open socket "localhost" 5672)
      (login-sasl-plain conn "/" "guest" "guest")
      (channel-open conn 1)
      (print conn)
      (basic-publish conn 1
                     :exchange "test-ex"
                     :routing-key "xx"
                     :body "this is the message content"
                     :properties '((:app-id . "Application id"))))))

(defun test-recv ()
  (with-connection (conn)
    (let ((socket (tcp-socket-new conn)))
      (socket-open socket "localhost" 5672)
      (login-sasl-plain conn "/" "guest" "guest")
      (channel-open conn 1)
      (exchange-declare conn 1 "test-ex" "topic")
      (let ((queue-name (queue-declare conn 1 :auto-delete t)))
        (queue-bind conn 1 :queue queue-name :exchange "test-ex" :routing-key "xx")
        (basic-consume conn 1 queue-name)
        (let* ((result (consume-message conn))
               (message (envelope/message result)))
          (format t "Got message: ~s~%content: ~s~%props: ~s"
                  result (babel:octets-to-string (message/body message)
                                                 :encoding :utf-8)
                  (message/properties message)))))))

(defun test-recv-in-thread ()
  (let ((out *standard-output*))
    (bordeaux-threads:make-thread #'(lambda ()
                                      (let ((*standard-output* out))
                                        (test-recv))))))
