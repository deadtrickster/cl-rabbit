(in-package :cl-rabbit.examples)

(defun test-send ()
  (with-connection (conn)
    (let ((socket (tcp-socket-new conn)))
      (socket-open socket "localhost" 5672)
      (login-sasl-plain conn "/" "guest" "guest")
      (channel-open conn 1)
      (basic-publish conn 1
                     :exchange ""
                     :routing-key "test-queue"
                     :body "this is the message content"
                     :properties '((:app-id . "Application id"))))))

(defun test-recv ()
  (with-connection (conn)
    (let ((socket (tcp-socket-new conn)))
      (socket-open socket "localhost" 5672)
      (login-sasl-plain conn "/" "guest" "guest")
      (channel-open conn 1)
      (let ((queue-name "test-queue"))
        (queue-declare conn 1 :queue queue-name)
        (basic-consume conn 1 queue-name)
        (let* ((result (consume-message conn))
               (message (envelope/message result)))
          (format t "Got message: ~s~%content: ~s~%props: ~s"
                  result (babel:octets-to-string (message/body message) :encoding :utf-8)
                  (message/properties message))
          (cl-rabbit:basic-ack conn 1 (envelope/delivery-tag result)))))))

(defun test-recv-in-thread ()
  (let ((out *standard-output*))
    (bordeaux-threads:make-thread #'(lambda ()
                                      (let ((*standard-output* out))
                                        (test-recv))))))
