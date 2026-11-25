#lang racket/base
;; The transport handshake reply comes from the server; a reply without any
;; entry is a protocol error, not a crash in the client.
(require rackunit racket/tcp "../../robotraconteur/message.rkt" "../../robotraconteur/client.rkt")

;; A one-shot TCP server on loopback that answers the first message with
;; `reply`. Returns the port number.
(define (serve-reply reply)
  (define l (tcp-listen 0 1 #t "127.0.0.1"))
  (define-values (_a port _b _c) (tcp-addresses l #t))
  (thread (lambda ()
            (define-values (in out) (tcp-accept l))
            (read-message in)
            (write-bytes (message->bytes reply) out)
            (flush-output out)
            (sleep 5)
            (tcp-close l)))
  port)

(test-case "a CreateConnection reply without entries is a ProtocolError"
  (define port (serve-reply (message (make-bytes 16 1) (make-bytes 16 0) 1 0 "" "" "" 0 0 '())))
  (define e (with-handlers ([exn:fail? values])
              (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=x" port) #:timeout 5)))
  (check-pred exn:fail:robotraconteur? e (if (exn? e) (exn-message e) (format "~a" e)))
  (when (exn:fail:robotraconteur? e)
    (check-equal? (rr-error-type e) 'ProtocolError)))
