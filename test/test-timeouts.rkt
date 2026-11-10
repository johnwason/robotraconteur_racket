#lang racket/base
;; rr-connect gives up promptly instead of waiting minutes.
;;
;; RR_DEAD_HOST    an address whose SYNs are never answered (run_tests.sh
;;                 uses rrtest0's link-local address on the other tap)
;; RR_DEAD_PORT    port to use with it
;; RR_HUNG_PORT    port of test/hung_server.py on 127.0.0.1
;; RR_HUNG_LOG     its log, to check that timed-out connections were closed
;; RR_CLOSED_PORT  a port on 127.0.0.1 with nothing listening
(require rackunit racket/file racket/string robotraconteur)

(define dead-host (getenv "RR_DEAD_HOST"))
(define dead-port (getenv "RR_DEAD_PORT"))
(define hung-port (getenv "RR_HUNG_PORT"))
(define hung-log (getenv "RR_HUNG_LOG"))
(define closed-port (getenv "RR_CLOSED_PORT"))

;; (values exception seconds)
(define (timed-fail thunk)
  (define t0 (current-inexact-milliseconds))
  (define e (with-handlers ([exn:fail? values]) (thunk) #f))
  (values e (/ (- (current-inexact-milliseconds) t0) 1000.0)))

(define (zoned host) ; URL host part, %25-encoding a zone
  (string-append "[" (string-replace host "%" "%25") "]"))

(test-case "unreachable host: TCP connect gives up after about 5 s"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+tcp://~a:~a/?service=test" (zoned dead-host) dead-port)))))
  (check-pred exn:fail? e)
  (check-regexp-match #rx"timed out" (exn-message e))
  (check-true (< 4 secs 7) (format "took ~a s" secs)))

(test-case "zoneless address answering on no interface gives up within the timeout"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+tcp://[fe80::dead:beef]:~a/?service=test" dead-port)))))
  (check-pred exn:fail? e)
  (check-true (< secs 7) (format "took ~a s" secs)))

(test-case "#:timeout shorter than the TCP timeout wins"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+tcp://~a:~a/?service=test" (zoned dead-host) dead-port)
                                       #:timeout 2))))
  (check-pred exn:fail:robotraconteur? e)
  (check-equal? (exn:fail:robotraconteur-error-name e) "RobotRaconteur.ConnectionError")
  (check-regexp-match #rx"timed out after 2 s" (exn-message e))
  (check-true (< 1.5 secs 3.5) (format "took ~a s" secs)))

(test-case "service that accepts but never answers: rr+tcp handshake times out"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=test" hung-port)
                                       #:timeout 3))))
  (check-pred exn:fail:robotraconteur? e)
  (check-true (< 2.5 secs 4.5) (format "took ~a s" secs)))

(test-case "service that accepts but never answers: rr+ws upgrade times out"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+ws://127.0.0.1:~a/?service=test" hung-port)
                                       #:timeout 3))))
  (check-pred exn:fail:robotraconteur? e)
  (check-true (< 2.5 secs 4.5) (format "took ~a s" secs)))

(test-case "default overall timeout is about 10 s"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=test" hung-port)))))
  (check-pred exn:fail:robotraconteur? e)
  (check-true (< 9 secs 12) (format "took ~a s" secs)))

(test-case "timed-out connections are closed"
  (sleep 0.5)
  (define lines (file->lines hung-log))
  (define accepted (length (filter (lambda (l) (string-prefix? l "accept")) lines)))
  (define closed (length (filter (lambda (l) (string-prefix? l "closed")) lines)))
  (check-equal? accepted 3)
  (check-equal? closed accepted))

(test-case "nothing listening: refused immediately"
  (define-values (e secs)
    (timed-fail (lambda () (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=test" closed-port)))))
  (check-pred exn:fail? e)
  (check-true (< secs 1) (format "took ~a s" secs)))
