#lang racket/base
;; Messages larger than rr-max-message-size (default 12 MiB, the C++ core's
;; default max_message_size) are rejected from the size in the header, before
;; the body is read; the limit can be raised or turned off.
(require rackunit "wire-util.rkt" "../../robotraconteur/message.rkt")

(define (message-of-size n)
  ;; one uint8 element padded so the whole message is n bytes
  (define base (bytes-length (raw-message (raw-element dt-uint8 0 #""))))
  (define k (- n base))
  (raw-message (raw-element dt-uint8 k (make-bytes k 1))))

(define limit (* 12 1024 1024))

(test-case "default limit is 12 MiB"
  (check-equal? (rr-max-message-size) limit))

(test-case "a header claiming more than the limit is rejected before the body is read"
  ;; only the 8-byte header is available: the size alone must be rejected
  (check-exn #rx"exceeds the maximum"
             (lambda () (read-message (open-input-bytes (bytes-append #"RRAC" (u32 (add1 limit))))))))

(test-case "a message of exactly the limit is accepted"
  (define m (read-message (open-input-bytes (message-of-size limit))))
  (check-pred message? m))

(test-case "the limit can be raised or turned off"
  (define big (message-of-size (+ limit 1000)))
  (check-exn #rx"exceeds the maximum" (lambda () (read-message (open-input-bytes big))))
  (parameterize ([rr-max-message-size (* 16 1024 1024)])
    (check-pred message? (read-message (open-input-bytes big))))
  (parameterize ([rr-max-message-size #f])
    (check-pred message? (read-message (open-input-bytes big)))))

(test-case "the parameter rejects invalid values"
  (check-exn exn:fail:contract? (lambda () (rr-max-message-size 0)))
  (check-exn exn:fail:contract? (lambda () (rr-max-message-size "big"))))
