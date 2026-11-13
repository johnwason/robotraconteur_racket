#lang racket/base
;; read-message takes the message size from the wire; it must not allocate the
;; whole claimed size before the data arrives.
(require rackunit "wire-util.rkt" "../../robotraconteur/message.rkt")

(test-case "a huge message size with little data does not allocate the claimed size"
  (define-values (in out) (make-pipe))
  ;; header claims 1 GiB, only 1000 bytes follow, then the stream ends
  (write-bytes (bytes-append #"RRAC" (u32 #x40000000) (make-bytes 1000 0)) out)
  (close-output-port out)
  (define before (vm-hwm-kb))
  (check-equal? (read-message in) eof)
  (define after (vm-hwm-kb))
  (when (and before after)
    (check-true (< (- after before) (* 128 1024))
                (format "peak memory grew by ~a MB" (quotient (- after before) 1024)))))

(test-case "a size smaller than the size field itself is rejected"
  (check-exn #rx"invalid message size"
             (lambda () (read-message (open-input-bytes (bytes-append #"RRAC" (u32 4)))))))

(test-case "messages larger than one read chunk still read"
  (define data (make-bytes (* 200 1024) 7))
  (define msg (raw-message (raw-element dt-uint8 (bytes-length data) data)))
  (define m (read-message (open-input-bytes msg)))
  (check-equal? (vector-length (elem-data (car (entry-elements (car (message-entries m))))))
                (bytes-length data)))
