(defpackage :cl-rabbit
  (:use :cl)
  (:documentation "CFFI-based interface to RabbitMQ")
  (:export #:basic-ack
           #:basic-consume
           #:basic-nack
           #:basic-publish
           #:basic-qos
           #:channel-close
           #:channel-flow
           #:channel-open
           #:consume-message
           #:destroy-connection
           #:envelope
           #:envelope/channel
           #:envelope/consumer-tag
           #:envelope/delivery-tag
           #:envelope/redelivered
           #:envelope/exchange
           #:envelope/message
           #:envelope/routing-key
           #:exchange-bind
           #:exchange-declare
           #:exchange-delete
           #:exchange-unbind
           #:login-sasl-plain
           #:message
           #:message/body
           #:message/properties
           #:new-connection
           #:queue-bind
           #:queue-declare
           #:queue-unbind
           #:rabbitmq-error
           #:rabbitmq-server-error
           #:socket-open
           #:tcp-socket-new
           #:with-connection
           #:version
           #:queue-purge
           #:queue-delete
           #:rabbitmq-library-error
           #:rabbitmq-library-error/error-code
           #:rabbitmq-library-error/error-description
           #:rabbitmq-server-error/type
           #:basic-cancel
           #:rabbitmq-server-error/reply-code
           #:rabbitmq-server-error/message
           #:+amqp-reply-success+
           #:+amqp-content-too-large+
           #:+amqp-no-route+
           #:+amqp-no-consumers+
           #:+amqp-access-refused+
           #:+amqp-not-found+
           #:+amqp-resource-locked+
           #:+amqp-precondition-failed+
           #:+amqp-connection-forced+
           #:+amqp-invalid-path+
           #:+amqp-frame-error+
           #:+amqp-syntax-error+
           #:+amqp-command-invalid+
           #:+amqp-channel-error+
           #:+amqp-unexpected-frame+
           #:+amqp-resource-error+
           #:+amqp-not-allowed+
           #:+amqp-not-implemented+
           #:+amqp-internal-error+))

(defpackage :cl-rabbit.examples
  (:use :cl :cl-rabbit)
  (:documentation "Examples for cl-rabbit"))
