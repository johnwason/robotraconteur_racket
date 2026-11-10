#lang racket/base
;; Connecting to IPv6 link-local addresses with and without a zone.
;;
;; run_tests.sh creates two tap interfaces in the container's own network
;; namespace and passes the link-local address of one of them. That address
;; is reachable only through its own interface (RR_ZONE_GOOD); on the other
;; (RR_ZONE_BAD) the SYN goes into the tap and is never answered, so a connect
;; there hangs until the TCP timeout. A URL without a zone must still connect
;; promptly: rr-connect races the address on every interface.
;;
;; RR_ZONE_ADDR  fe80:: address of RR_ZONE_GOOD
;; RR_ZONE_PORT  port of a plain test service (rr+tcp and rr+ws)
(require rackunit racket/tcp "../robotraconteur/main.rkt" "../robotraconteur/net.rkt")

(define addr (getenv "RR_ZONE_ADDR"))
(define port (getenv "RR_ZONE_PORT"))
(define good (getenv "RR_ZONE_GOOD"))
(define bad (getenv "RR_ZONE_BAD"))

(define (url scheme zone)
  (format "~a://[~a~a]:~a/?service=test" scheme addr (if zone (string-append "%25" zone) "") port))

;; connects and reads the root object type; returns (values type seconds)
(define (connect-type u)
  (define t0 (current-inexact-milliseconds))
  (define c (rr-connect u))
  (begin0 (values (rr-object-type c) (/ (- (current-inexact-milliseconds) t0) 1000.0))
          (rr-close c)))

(test-case "zoneless link-local detection"
  (check-true (zoneless-link-local? "fe80::1"))
  (check-true (zoneless-link-local? "FE80::1"))
  (check-true (zoneless-link-local? "febf::1"))
  (check-false (zoneless-link-local? "fe80::1%eth0"))
  (check-false (zoneless-link-local? "fec0::1"))
  (check-false (zoneless-link-local? "::1"))
  (check-false (zoneless-link-local? "127.0.0.1"))
  (check-false (zoneless-link-local? "fe80.example.com")))

(test-case "both interfaces are candidates"
  (define names (map cdr (link-local-interfaces)))
  (check-not-false (member good names))
  (check-not-false (member bad names)))

(test-case "explicit zone on the right interface connects"
  (define-values (type secs) (connect-type (url "rr+tcp" good)))
  (check-equal? type "experimental.racket_test.TestObject"))

(test-case "explicit zone on the wrong interface does not connect"
  ;; this is why zones are raced rather than tried in turn
  (define ch (make-channel))
  (define th (thread (lambda ()
                       (channel-put ch (with-handlers ([exn:fail? (lambda (e) 'failed)])
                                         (define-values (i o) (tcp-connect (string-append addr "%" bad)
                                                                           (string->number port)))
                                         (close-output-port o) (close-input-port i)
                                         'connected)))))
  (check-not-equal? (sync/timeout 2 ch) 'connected)
  (kill-thread th))

(test-case "no zone: rr+tcp connects through the right interface without waiting on the wrong one"
  (define-values (type secs) (connect-type (url "rr+tcp" #f)))
  (check-equal? type "experimental.racket_test.TestObject")
  (check-true (< secs 5) (format "took ~a s" secs)))

(test-case "no zone: rr+ws connects too"
  (define-values (type secs) (connect-type (url "rr+ws" #f)))
  (check-equal? type "experimental.racket_test.TestObject")
  (check-true (< secs 5) (format "took ~a s" secs)))

(test-case "no zone: a full session works over the raced connection"
  (define c (rr-connect (url "rr+tcp" #f)))
  (rr-set! c "d1" 4.5)
  (check-equal? (rr-get c "d1") 4.5)
  (check-equal? (rr-call c "add" 2.0 3.0) 5.0)
  (rr-close c))
