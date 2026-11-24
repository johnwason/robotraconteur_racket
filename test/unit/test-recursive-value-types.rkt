#lang racket/base
;; A pod or namedarray that contains itself (directly, through another pod
;; or namedarray, or through another service definition) is rejected when
;; the definition is added, as in the C++ core. The definitions come from the
;; service; before, namedarray-layout (unpacking a namedarray array),
;; namedarray->flat and new-structure recursed forever on such a type, with
;; memory growing until the process died.
(require rackunit "../../robotraconteur/message.rkt" "../../robotraconteur/pack.rkt"
         "../../robotraconteur/robdef.rkt")

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

(define (def name . lines)
  (parse-robdef (apply string-append "service " name "\n\nstdver 0.10\n\n"
                       (map (lambda (l) (string-append l "\n")) lines))))

;; Adds the definitions, then uses the type the way a client does: a new
;; structure and (for a namedarray) unpacking a namedarray array of it.
(define (add-and-use defs type kind)
  (bounded
   (lambda ()
     (define reg (make-type-registry))
     (for ([d (in-list defs)]) (registry-add-def! reg d))
     (new-structure reg type)
     (when (eq? kind 'namedarray)
       (unpack-elem reg "" #f (make-elem "value" dt-namedarray-array #:type-name type
                                         (list (make-elem "array" dt-double (vector 1.0 2.0))))))
     'used)))

(define (check-rejected r)
  (check-pred pair? r "the definition was used without returning (time or memory limit)")
  (when (pair? r)
    (check-eq? (car r) 'exn (format "~a" r))
    (when (eq? (car r) 'exn)
      (check-regexp-match #rx"contains itself" (exn-message (cdr r))))))

(test-case "a namedarray that contains itself is rejected"
  (check-rejected (add-and-use (list (def "experimental.rec" "namedarray N" "    field double x" "    field N n" "end"))
                               "experimental.rec.N" 'namedarray)))

(test-case "a pod that contains itself is rejected"
  (check-rejected (add-and-use (list (def "experimental.rec" "pod P" "    field double x" "    field P[1] p" "end"))
                               "experimental.rec.P" 'pod)))

(test-case "namedarrays that contain each other are rejected"
  (check-rejected (add-and-use (list (def "experimental.rec" "namedarray A" "    field B b" "end"
                                          "namedarray B" "    field double x" "    field A a" "end"))
                               "experimental.rec.A" 'namedarray)))

(test-case "a cycle through two service definitions is rejected when it closes"
  (define reg (make-type-registry))
  (registry-add-def! reg (def "experimental.reca" "import experimental.recb"
                              "pod P" "    field double x" "    field experimental.recb.Q[2] q" "end"))
  (define b (def "experimental.recb" "import experimental.reca"
                 "pod Q" "    field experimental.reca.P[2] p" "end"))
  (check-exn #rx"contains itself" (lambda () (registry-add-def! reg b)))
  ;; the rejected definition is not kept
  (check-exn #rx"could not resolve" (lambda () (resolve-type reg "" "experimental.recb.Q"))))

(test-case "nested pods and namedarrays without a cycle are accepted"
  (define r (add-and-use (list (def "experimental.rec"
                                    "namedarray V" "    field double x" "    field double y" "end"
                                    "namedarray W" "    field V a" "    field V[2] b" "end"
                                    "pod P" "    field W w" "    field double[2] d" "end"
                                    "pod Q" "    field P[2] p" "    field P p2" "    field W w" "end"))
                         "experimental.rec.Q" 'pod))
  (check-equal? r '(ok . used)))
