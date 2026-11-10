#lang racket/base
;; Unit tests for the test vector blob reader.
(require rackunit racket/string "test-vectors.rkt")

(test-case "known vectors decode"
  (define c (get-test-vector "seq.double_constants" 'double))
  (check-true (> (vector-length c) 0))
  (check-true (flonum? (vector-ref c 0)))
  (define dims (get-test-vector "ts1.d5.to_service.dims" 'uint32))
  (check-equal? (vector-length (get-test-vector "ts1.d5.to_service" 'double))
                (for/product ([d dims]) d)))

(test-case "missing vector names the vector"
  (check-exn (lambda (e) (and (exn:fail? e) (string-contains? (exn-message e) "no.such.vector")))
             (lambda () (get-test-vector "no.such.vector" 'double))))

(test-case "type mismatch is rejected, not converted"
  (check-exn (lambda (e) (and (exn:fail? e)
                              (string-contains? (exn-message e) "type mismatch")
                              (string-contains? (exn-message e) "seq.double_constants")))
             (lambda () (get-test-vector "seq.double_constants" 'single))))

(test-case "64-bit unsigned values are exact"
  (for ([x (get-test-vector "ts1.u64_2.to_client" 'uint64)])
    (check-true (and (exact-nonnegative-integer? x) (< x (expt 2 64))))))
