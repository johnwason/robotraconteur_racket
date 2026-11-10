#lang racket/base
;; rr+wss against the public Robot Raconteur WebSocket test server
;; (the same check as robotraconteur/test/extra/tcp_tls/test_ws_https.py).
;; Needs internet access; run with ./run_online_tests.sh.
(require rackunit "../robotraconteur/main.rkt")

(define url (or (getenv "RR_WSS_ONLINE_URL")
                "rr+wss://wstest2.wasontech.com/robotraconteur?service=testobj"))

(test-case "public rr+wss test service"
  (define c (rr-connect url))
  (check-equal? (rr-call c "add_two_numbers" 2.0 4.0) 6.0)
  (rr-close c))
