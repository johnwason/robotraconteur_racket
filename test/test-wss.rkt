#lang racket/base
;; rr+wss certificate checks, against the local TLS relay (test/tls_proxy.py).
;;
;; RR_WSS_PORT  relay port (default 22443)
;; RR_TEST_CA   PEM certificate the relay presents; its SAN is DNS:localhost only
;;
;; The full client suite also runs over rr+wss (test-client.rkt with
;; RR_TEST_URL=rr+wss://localhost:...); this file checks that the default
;; context really verifies the certificate chain and the hostname.
(require rackunit robotraconteur)

(define port (or (getenv "RR_WSS_PORT") "22443"))
(define ca (getenv "RR_TEST_CA"))

(define (trusting-context) (rr-make-ssl-context #:trust (list ca)))

(define (url host) (format "rr+wss://~a:~a/?service=test" host port))

;; fails in certificate verification, not e.g. by connection refused
(define (verify-failed? e)
  (and (exn:fail? e) (regexp-match? #rx"certificate verify failed" (exn-message e))))

(test-case "trusted certificate and matching hostname connect"
  (define c (rr-connect (url "localhost") #:ssl-context (trusting-context)))
  (check-equal? (rr-object-type c) "experimental.racket_test.TestObject")
  (rr-close c))

(test-case "default context rejects a certificate outside the system trust store"
  (check-exn verify-failed? (lambda () (rr-close (rr-connect (url "localhost"))))))

(test-case "trusted certificate with the wrong hostname is rejected"
  ;; the certificate names localhost, not 127.0.0.1
  (check-exn verify-failed?
             (lambda () (rr-close (rr-connect (url "127.0.0.1") #:ssl-context (trusting-context))))))
