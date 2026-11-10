#lang racket/base
;; Node and service discovery over IPv6 link-local multicast (FF02::BA86).
;;
;; run_tests.sh runs this inside the container's own network namespace with
;; tap interfaces (test/tap_sink.py, names in RR_DISCOVERY_IFACES) standing in
;; for LANs, and two test services (separate nodes, named
;; experimental.racket_test and experimental.racket_test2) listening on the
;; ports in RR_DISCOVERY_PORTS. Each node announces on every interface.
(require rackunit racket/list racket/string "../robotraconteur/main.rkt")

(define ports (string-split (getenv "RR_DISCOVERY_PORTS")))
(define ifaces (string-split (or (getenv "RR_DISCOVERY_IFACES") "rrtest0")))

(define (test-nodes)
  (filter (lambda (n) (string-prefix? (rr-node-info-nodename n) "experimental.racket_test"))
          (rr-find-nodes #:timeout 2)))

(define (url-port u) (cadr (regexp-match #px"\\]:([0-9]+)/" u)))

(define (url-zone u) (cadr (regexp-match #px"%25([^]]+)\\]" u)))

(test-case "finds every node, with a link-local URL per interface"
  (define nodes (test-nodes))
  (check-equal? (length nodes) (length ports))
  (check-equal? (sort (map (lambda (n) (url-port (car (rr-node-info-urls n)))) nodes) string<?)
                (sort ports string<?))
  (for ([n nodes])
    (check-regexp-match #px"^\\{[0-9a-f-]{36}\\}$" (rr-node-info-nodeid n))
    (define urls (rr-node-info-urls n))
    ;; one URL per interface, each scoped to the interface it was heard on
    (check-equal? (sort (map url-zone urls) string<?) (sort ifaces string<?))
    (for ([u urls])
      (check-true (string-contains? u "service=RobotRaconteurServiceIndex") u))))

(test-case "find by node id and by name"
  (define n (car (test-nodes)))
  (define by-id (rr-find-node-by-id (rr-node-info-nodeid n) #:timeout 2))
  (check-equal? (map rr-node-info-nodeid by-id) (list (rr-node-info-nodeid n)))
  ;; the id also matches without braces
  (define bare (substring (rr-node-info-nodeid n) 1 37))
  (check-equal? (length (rr-find-node-by-id bare #:timeout 2)) 1)
  (for ([name '("experimental.racket_test" "experimental.racket_test2")])
    (check-equal? (map rr-node-info-nodename (rr-find-node-by-name name #:timeout 2)) (list name)))
  (check-equal? (rr-find-node-by-name "no.such.node" #:timeout 1) '()))

(test-case "find services by type and connect to them"
  (define svcs (rr-find-service-by-type "experimental.racket_test.TestObject" #:timeout 2))
  (check-equal? (length svcs) (length ports))
  (for ([s svcs])
    (check-equal? (rr-service-info-name s) "test")
    (check-equal? (rr-service-info-root-object-type s) "experimental.racket_test.TestObject")
    (check-equal? (hash-ref (rr-service-info-attributes s) "description") "racket test service")
    (define u (car (rr-service-info-urls s)))
    (check-true (string-contains? u "service=test") u)
    (define c (rr-connect u))
    (check-equal? (rr-object-type c) "experimental.racket_test.TestObject")
    (check-equal? (rr-call c "add" 1.0 2.0) 3.0)
    (rr-close c)))

(test-case "unknown service type finds nothing"
  (check-equal? (rr-find-service-by-type "experimental.no_such.Type" #:timeout 1) '()))
