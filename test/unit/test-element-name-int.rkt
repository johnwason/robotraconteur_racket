#lang racket/base
;; Element names that hold integers (map{int32} keys, pipe endpoint indexes)
;; come from the service and are parsed strictly, as decimal int32 values.
;; With string->number, a 14-byte name such as "#e1e1000000000" made the
;; client compute 10^(10^9) exactly (minutes of CPU on the reader thread, all
;; requests timing out), and names like "1/2" or "+inf.0" became keys.
(require rackunit "fake-service.rkt" "../../robotraconteur/message.rkt"
         "../../robotraconteur/pack.rkt" "../../robotraconteur/robdef.rkt"
         "../../robotraconteur/client.rkt")

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

(define huge "#e1e100000000")

(define (unpack-map . names)
  (unpack-elem (make-type-registry) "" (parse-type "int32{int32}")
               (make-elem "value" dt-vector
                          (for/list ([n (in-list names)]) (make-elem n dt-int32 (vector 1))))))

(test-case "map{int32} keys are decimal int32 values"
  (check-equal? (unpack-map "0" "-5" "+7" "2147483647" "-2147483648")
                (hash 0 1 -5 1 7 1 2147483647 1 -2147483648 1)))

(test-case "other map{int32} keys are an error"
  (for ([k (in-list (list "1/2" "1.5" "+inf.0" "#x10" "1e3" "2147483648" "-2147483649" "" " 1" "x"))])
    (check-exn #rx"robotraconteur" (lambda () (unpack-map k)) k)))

(test-case "an exact exponent map{int32} key is rejected without computing it"
  (define r (bounded (lambda () (unpack-map huge)) 5))
  (check-pred pair? r "unpack did not return (time or memory limit)")
  (when (pair? r) (check-eq? (car r) 'exn)))

;; The service sends pipe packets and acks with hostile endpoint indexes
;; before answering a property read; the reader thread must keep going.
(define robdef "service experimental.fakepipe\n\nstdver 0.10\n\nobject Obj\n    property double d\n    pipe double p\nend\n")

(define (handler en send!)
  (case (entry-type en)
    [(PropertyGetReq)
     (send! (list (entry 'PipePacket "svc" "p" 0 0 ""
                         (for/list ([n (list huge "1/2" "+inf.0")])
                           (make-elem n dt-dictionary
                                      (list (make-elem "packetnumber" dt-uint32 (vector 1))
                                            (make-elem "packet" dt-double (vector 1.0))))))
                  (entry 'PipePacketRet "svc" "p" 0 0 ""
                         (list (make-elem huge dt-uint32 (vector 1))))))
     (send! (list (entry 'PropertyGetRes "svc" "d" (entry-request-id en) 0 ""
                         (list (make-elem "value" dt-double (vector 2.0))))))]
    [else (void)]))

(test-case "pipe packets and acks with hostile endpoint indexes are dropped"
  (define r
    (bounded
     (lambda ()
       (define obj (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=svc"
                                       (serve-fake robdef "experimental.fakepipe.Obj" handler))
                               #:timeout 10))
       (begin0 (rr-get obj "d") (rr-close obj)))
     20))
  (check-equal? r '(ok . 2.0)))
