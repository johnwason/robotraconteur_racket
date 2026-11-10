#lang racket/base
;; rrs+tcp (Robot Raconteur node TLS) checks against secure test services
;; that use the throwaway PKI from test/make_test_pki.sh. run_tests.sh starts
;; one server per case:
;;
;; RR_TEST_TLS_ROOT  test root certificate (PEM)
;; RR_RRS_GOOD       "port nodeid" of a server with a correct certificate
;; RR_RRS_WRONGCN    "port nodeid" of a server presenting another node's certificate
;; RR_RRS_NOOID      "port nodeid" of a server whose certificate lacks the node extension
;; RR_RRS_EXTRAEXT   "port nodeid" of a server whose certificate has an unknown
;;                   critical extension
;;
;; The full client suite also runs over rrs+tcp (test-client.rkt).
(require rackunit racket/string "../robotraconteur/main.rkt")

(define root (getenv "RR_TEST_TLS_ROOT"))
(define (server var)
  (define parts (string-split (getenv var)))
  (values (car parts) (cadr parts)))
(define-values (good-port good-id) (server "RR_RRS_GOOD"))

(define test-ctx (rr-make-node-tls-context #:extra-roots (list root)))

(define (url port [extra ""]) (format "rrs+tcp://127.0.0.1:~a/?service=test~a" port extra))

(define (connect-ok? u [ctx test-ctx])
  (define c (rr-connect u #:tls-context ctx))
  (begin0 (rr-object-type c) (rr-close c)))

(define ((fails-with rx) e)
  (and (exn:fail? e) (regexp-match? rx (exn-message e))))

(test-case "connects to a node with a valid certificate chain"
  (check-equal? (connect-ok? (url good-port)) "experimental.racket_test.TestObject"))

(test-case "nodeid in the URL must match the server"
  (check-equal? (connect-ok? (url good-port (string-append "&nodeid=" good-id)))
                "experimental.racket_test.TestObject")
  ;; the server refuses STARTTLS for another node id
  (check-exn exn:fail:robotraconteur?
             (lambda () (connect-ok? (url good-port "&nodeid={99999999-2222-3333-4444-555555555555}")))))

(test-case "only the given roots are trusted"
  (check-equal? (connect-ok? (url good-port)
                             (rr-make-node-tls-context #:extra-roots (list root) #:default-roots? #f))
                "experimental.racket_test.TestObject")
  ;; the default context trusts only the two Robot Raconteur roots
  (check-exn (fails-with #rx"certificate verify failed")
             (lambda () (rr-close (rr-connect (url good-port))))))

(test-case "certificate for a different node is rejected"
  (define-values (port id) (server "RR_RRS_WRONGCN"))
  (check-exn (fails-with #rx"server certificate is for")
             (lambda () (connect-ok? (url port)))))

(test-case "certificate without the node extension is rejected"
  (define-values (port id) (server "RR_RRS_NOOID"))
  (check-exn (fails-with #rx"certificate verify failed")
             (lambda () (connect-ok? (url port)))))

(test-case "certificate with an unknown critical extension is rejected"
  (define-values (port id) (server "RR_RRS_EXTRAEXT"))
  (check-exn (fails-with #rx"certificate verify failed")
             (lambda () (connect-ok? (url port)))))

(test-case "secure server refuses plaintext rr+tcp"
  (check-exn exn:fail?
             (lambda ()
               (rr-close (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=test" good-port))))))
