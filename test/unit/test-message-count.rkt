#lang racket/base
;; A numeric element's count comes from the wire; the reader must not allocate
;; for it before checking that the message holds that much data.
(require rackunit "wire-util.rkt" "../../robotraconteur/message.rkt")

(test-case "numeric element count larger than the message is rejected without allocating"
  ;; 64M doubles claimed (a 512 MB vector) in a message of about 100 bytes
  (define msg (raw-message (raw-element dt-double #x4000000 #"")))
  (define before (vm-hwm-kb))
  (check-exn #rx"message truncated" (lambda () (bytes->message msg)))
  (define after (vm-hwm-kb))
  (when (and before after)
    (check-true (< (- after before) (* 128 1024))
                (format "peak memory grew by ~a MB" (quotient (- after before) 1024)))))

(test-case "numeric element counts that fit still read"
  (define data (bytes-append (real->floating-point-bytes 1.5 8 #f)
                             (real->floating-point-bytes -2.0 8 #f)))
  (define m (bytes->message (raw-message (raw-element dt-double 2 data))))
  (check-equal? (elem-data (car (entry-elements (car (message-entries m))))) (vector 1.5 -2.0)))
