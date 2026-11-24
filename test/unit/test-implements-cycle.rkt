#lang racket/base
;; Service definitions come from the service. An object that implements
;; itself (directly or through other objects) is rejected with a
;; ServiceDefinitionError, as the C++ core's VerifyObjectImplements does,
;; instead of sending object-members into unbounded recursion (memory grows
;; until the process dies). Objects implemented more than once (a diamond)
;; and through several levels still give their members.
(require rackunit racket/list "../../robotraconteur/robdef.rkt" "../../robotraconteur/pack.rkt"
         "../../robotraconteur/client.rkt")
(require/expose "../../robotraconteur/client.rkt" (object-members))

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

(define (members-of text obj)
  (define reg (make-type-registry))
  (define d (parse-robdef text))
  (registry-add-def! reg d)
  (define-values (q kind def) (resolve-type reg (servicedef-name d) obj))
  (bounded (lambda () (object-members reg (servicedef-name d) def))))

(define (def . lines)
  (apply string-append "service experimental.impl\n\nstdver 0.10\n\n"
         (map (lambda (l) (string-append l "\n")) lines)))

(define (check-definition-error r)
  (check-pred pair? r "object-members did not return (time or memory limit)")
  (when (pair? r)
    (check-eq? (car r) 'exn)
    (check-true (and (exn:fail:robotraconteur? (cdr r))
                     (equal? (exn:fail:robotraconteur-error-name (cdr r))
                             "RobotRaconteur.ServiceDefinitionError"))
                (format "~a" (cdr r)))))

(define (names r)
  (sort (for/list ([m (in-list (cdr r))]) (member-name (if (pair? m) (cdr m) m))) string<?))

(test-case "an object that implements itself is a definition error"
  (check-definition-error
   (members-of (def "object O" "    implements O" "    property double d" "end") "O")))

(test-case "objects that implement each other are a definition error"
  (check-definition-error
   (members-of (def "object A" "    implements B" "    property double a" "end"
                    "object B" "    implements A" "    property double b" "end") "A")))

(test-case "implemented objects give their members once, through several levels"
  (define r (members-of (def "object C" "    property double c" "end"
                             "object B" "    implements C" "    property double b" "end"
                             "object A" "    implements B" "    implements C" "    property double a" "end")
                        "A"))
  (check-equal? (car r) 'ok (format "~a" r))
  (when (eq? (car r) 'ok)
    (check-equal? (names r) '("a" "b" "c"))
    ;; members of implemented objects carry their namespace
    (check-true (for/and ([m (in-list (cdr r))] #:when (pair? m))
                  (and (equal? (car m) "experimental.impl") (member? (cdr m)))))))
