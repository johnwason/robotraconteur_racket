#lang racket/base
;; Reader for the Robot Raconteur test vector blob.
;; Format: robotraconteur/test/data/TEST_VECTORS_FORMAT.md (version 1).
;;
;; The blob is read relative to this source file (test/data/test_vectors.bin),
;; or from the path in RR_TEST_VECTORS when set.

(require racket/runtime-path racket/promise)

(provide get-test-vector
         test-vectors-path)

(define-runtime-path default-blob "../data/test_vectors.bin")

(define (test-vectors-path)
  (or (getenv "RR_TEST_VECTORS") default-blob))

;; type symbol -> (code element-size decoder)
(define (int-decoder size signed?)
  (lambda (b off) (integer-bytes->integer b signed? #f off (+ off size))))
(define formats
  (hash 'double (list 1 8 (lambda (b off) (floating-point-bytes->real b #f off (+ off 8))))
        'single (list 2 4 (lambda (b off) (floating-point-bytes->real b #f off (+ off 4))))
        'int8   (list 3 1 (lambda (b off) (let ([x (bytes-ref b off)]) (if (> x 127) (- x 256) x))))
        'uint8  (list 4 1 (lambda (b off) (bytes-ref b off)))
        'int16  (list 5 2 (int-decoder 2 #t))
        'uint16 (list 6 2 (int-decoder 2 #f))
        'int32  (list 7 4 (int-decoder 4 #t))
        'uint32 (list 8 4 (int-decoder 4 #f))
        'int64  (list 9 8 (int-decoder 8 #t))
        'uint64 (list 10 8 (int-decoder 8 #f))))

(define header-size 24)
(define entry-size 64)
(define name-size 48)

(define (u32 b off) (integer-bytes->integer b #f #f off (+ off 4)))

;; The blob is loaded and validated once (requirements 1-3).
(define blob
  (delay
    (define path (test-vectors-path))
    (define b (call-with-input-file path (lambda (in) (read-bytes (file-size path) in))))
    (define (bad msg) (error 'test-vectors "~a: ~a" msg path))
    (when (eof-object? b) (bad "empty test vector blob"))
    (unless (>= (bytes-length b) header-size) (bad "test vector blob too short"))
    (unless (equal? (subbytes b 0 8) #"RRTVECTS") (bad "invalid test vector blob magic"))
    (unless (= (u32 b 8) 1) (bad (format "unsupported test vector blob version ~a" (u32 b 8))))
    (unless (= (u32 b 12) entry-size) (bad (format "unsupported test vector entry size ~a" (u32 b 12))))
    (unless (= (u32 b 20) (bytes-length b)) (bad "test vector blob file_size does not match file"))
    (unless (<= (+ header-size (* entry-size (u32 b 16))) (bytes-length b))
      (bad "truncated test vector index"))
    b))

;; Name comparison up to the first NUL or all 48 bytes (requirement 4).
(define (entry-name b off)
  (define raw (subbytes b off (+ off name-size)))
  (define nul (for/first ([i (in-range name-size)] #:when (zero? (bytes-ref raw i))) i))
  (subbytes raw 0 (or nul name-size)))

;; Return the named vector as a Racket vector. type must match the stored type.
(define (get-test-vector name type)
  (define b (force blob))
  (define fmt (hash-ref formats type (lambda () (error 'get-test-vector "unknown type ~a for ~a" type name))))
  (define-values (code esize decode) (apply values fmt))
  (define wanted (string->bytes/utf-8 name))
  (define count-entries (u32 b 16))
  (define idx
    (for/first ([i (in-range count-entries)]
                #:when (equal? (entry-name b (+ header-size (* entry-size i))) wanted))
      (+ header-size (* entry-size i))))
  (unless idx (error 'get-test-vector "test vector not found: ~a" name))
  ;; requirement 5: no silent conversion
  (unless (= (u32 b (+ idx 48)) code)
    (error 'get-test-vector "test vector type mismatch: ~a (stored type code ~a, requested ~a)"
           name (u32 b (+ idx 48)) type))
  (define count (u32 b (+ idx 52)))
  (define offset (u32 b (+ idx 56)))
  ;; requirement 6: Racket integers do not overflow
  (unless (<= (+ offset (* count esize)) (bytes-length b))
    (error 'get-test-vector "test vector out of bounds: ~a" name))
  (for/vector #:length count ([i (in-range count)])
    (decode b (+ offset (* i esize)))))
