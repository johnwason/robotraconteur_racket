#lang racket/base
;; Service definitions come from the service. Array dimensions must be
;; decimal integers and pod/namedarray fields numeric, enum, pod or
;; namedarray types; anything else is a definition error when the definition
;; is parsed, instead of contract violations later (make-vector, in-range,
;; *, string-contains?) or, for an exact exponent such as [#e1e1000000000],
;; minutes of bignum computation in parse-robdef.
(require rackunit racket/file racket/runtime-path "../../robotraconteur/robdef.rkt"
         "../../robotraconteur/pack.rkt")

;; Runs thunk in a thread with a time and (where available) memory limit.
;; Returns (cons 'ok value), (cons 'exn exn) or 'limit.
(define (bounded thunk [secs 10])
  (define cust (make-custodian))
  (when (custodian-memory-accounting-available?)
    (custodian-limit-memory cust (* 512 1024 1024) cust))
  (define ch (make-channel))
  (define th (parameterize ([current-custodian cust])
               (thread (lambda ()
                         (channel-put ch (with-handlers ([(lambda (e) #t) (lambda (e) (cons 'exn e))])
                                           (cons 'ok (thunk))))))))
  (define r (sync/timeout secs ch (thread-dead-evt th)))
  (custodian-shutdown-all cust)
  (if (pair? r) r 'limit))

(define (def . lines)
  (apply string-append "service experimental.val\n\nstdver 0.10\n\n"
         (map (lambda (l) (string-append l "\n")) lines)))

;; parse-robdef must raise a plain error (exn:fail, not a contract violation)
(define (check-def-error text)
  (define r (bounded (lambda () (parse-robdef text)) 5))
  (check-pred pair? r (format "parse-robdef did not return: ~a" text))
  (when (pair? r)
    (check-eq? (car r) 'exn (format "accepted: ~a" text))
    (when (eq? (car r) 'exn)
      (check-false (exn:fail:contract? (cdr r)) (exn-message (cdr r)))
      (check-regexp-match #rx"^parse-(type|robdef): " (exn-message (cdr r))))))

(test-case "array dimensions must be non-negative decimal integers"
  (for ([dims (in-list '("-" "x" "-1" "1/2" "1e400" "1.5" "+3" "#x10" "2147483648" "2,x" "2,-1"
                         "2,,3" "x-" "#e1e100000000" "#e1e100000000-" "1,#e1e100000000"))])
    (check-def-error (def "object O" (format "    property double[~a] p" dims) "end"))
    (check-def-error (def "pod P" (format "    field double[~a] p" dims) "end"))))

(test-case "the saved fuzz inputs are definition errors"
  (check-def-error "service o\npod 1\nfield double[-] d\n")
  (check-def-error "service experimental.fz\n\nnamedarray N\n    field double[x] a\nend\n")
  (check-def-error (def "object O" "    function void f(double[#e1e100000000] b)" "end")))

(test-case "pod and namedarray fields must be numeric, enum, pod or namedarray types"
  (for* ([kind (in-list '("pod" "namedarray"))]
         [ty (in-list '("varvalue" "string" "varobject" "double{list}" "double{int32}" "Vec{string}"))])
    (check-def-error (def (format "~a N" kind) (format "    field ~a f" ty) "end"))))

(test-case "valid dimensions and fields still parse"
  (define d (parse-robdef (def "namedarray Vec" "    field double x" "    field double[3] y" "end"
                               "pod P" "    field Vec v" "    field int32[2,3] m" "    field uint8[10-] b"
                               "    field double[0] z" "end"
                               "struct S" "    field string s" "    field varvalue v" "    field double[2147483647-] a" "end")))
  (define-values (pfields) (entrydef-members (hash-ref (servicedef-entries d) "P")))
  (check-equal? (map (lambda (m) (typedef-dims (member-type m))) pfields) '(() (2 3) (10) (0)))
  (check-equal? (typedef-dims (parse-type "double[ 4 , 5 ]")) '(4 5)))

(define-runtime-path robdef-file "../experimental.racket_test.robdef")
(test-case "the test service definition parses"
  (check-equal? (servicedef-name (parse-robdef (file->string robdef-file))) "experimental.racket_test"))
