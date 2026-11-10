#lang racket/base
;; Shared helpers for the ServiceTest ports, mirroring the numpy assertions
;; used by the Python ServiceTestClient*.py files.
(require rackunit racket/list
         robotraconteur "test-vectors.rkt")

(provide tv tv-md
         check-allclose
         check-allclose/rtol
         check-array-equal
         check-rr-error
         rr-error-named?)

;; Shorthand for a test vector
(define (tv name type) (get-test-vector name type))

;; Multidim array from a flat vector and its "<name>.dims" vector (column major,
;; matching numpy order="F" in the Python tests)
(define (tv-md name type)
  (rr-multidim (vector->list (get-test-vector (string-append name ".dims") 'uint32))
               (get-test-vector name type)))

;; Flatten scalars, vectors, lists and multidims to a list of numbers, plus dims
(define (flat+dims x)
  (cond
    [(rr-multidim? x) (values (vector->list (rr-multidim-array x)) (rr-multidim-dims x))]
    [(vector? x) (values (vector->list x) (list (vector-length x)))]
    [(list? x) (values x (list (length x)))]
    [(number? x) (values (list x) '())]
    [else (error 'check-allclose "not numeric: ~e" x)]))

(define (close? a b rtol)
  (cond
    [(and (real? a) (real? b)) (<= (abs (- a b)) (* rtol (abs b)))]
    [(and (number? a) (number? b)) (<= (magnitude (- a b)) (* rtol (magnitude b)))]
    [else (equal? a b)]))

;; numpy.testing.assert_allclose(actual, desired) with rtol=1e-7, atol=0
(define-check (check-allclose actual desired)
  (allclose-check actual desired 1e-7))

(define-check (check-allclose/rtol actual desired rtol)
  (allclose-check actual desired rtol))

(define (allclose-check actual desired rtol)
  (define-values (a ad) (flat+dims actual))
  (define-values (d dd) (flat+dims desired))
  (unless (equal? ad dd)
    (fail-check (format "shape mismatch: ~a vs ~a" ad dd)))
  (for ([x a] [y d] [i (in-naturals)])
    (unless (close? x y rtol)
      (fail-check (format "element ~a: ~a not close to ~a" i x y)))))

;; numpy.testing.assert_array_equal
(define-check (check-array-equal actual desired)
  (define-values (a ad) (flat+dims actual))
  (define-values (d dd) (flat+dims desired))
  (unless (and (equal? ad dd) (equal? a d))
    (fail-check (format "arrays differ:\n  actual  ~a\n  desired ~a" actual desired))))

(define (rr-error-named? name)
  (lambda (e) (and (exn:fail:robotraconteur? e) (equal? (exn:fail:robotraconteur-error-name e) name))))

;; (check-rr-error 'InvalidOperation thunk) or (check-rr-error "full.error.Name" thunk)
(define-check (check-rr-error expected thunk)
  (define e (with-handlers ([exn:fail:robotraconteur? values]) (thunk) #f))
  (cond
    [(not e) (fail-check (format "expected Robot Raconteur error ~a, none raised" expected))]
    [(symbol? expected)
     (unless (eq? (rr-error-type e) expected)
       (fail-check (format "expected ~a, got ~a (~a)" expected (rr-error-type e) (exn-message e))))]
    [else
     (unless (equal? (exn:fail:robotraconteur-error-name e) expected)
       (fail-check (format "expected ~a, got ~a" expected (exn-message e))))]))
