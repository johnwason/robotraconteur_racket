#lang racket/base
;; Runs the discovery examples (examples/features/discovery) as programs.
;;
;; run_tests.sh runs this in the discovery stage, inside the container's own
;; network namespace with tap interfaces standing in for a LAN, while Reynard
;; the Robot runs as a node there. Each example finds Reynard, connects
;; through the discovered URL and calls say(); a failed call fails the
;; program.
(require rackunit racket/runtime-path racket/string robotraconteur "run-program.rkt")

(define-runtime-path dir "../examples/features/discovery")

(define (run file . args) (apply run-racket 60 (build-path dir file) args))

(define-syntax-rule (check-ran code output)
  (check-equal? code 0 (format "example failed:\n~a" output)))

(test-case "find-service-by-type finds Reynard and calls say"
  (define-values (code output) (run "find-service-by-type.rkt"))
  (check-ran code output)
  (check-regexp-match #rx"Name: reynard\n" output)
  (check-regexp-match #rx"RootObjectType: experimental.reynard_the_robot.Reynard\n" output)
  (check-regexp-match #rx"NodeName: experimental.reynard_the_robot\n" output)
  ;; the discovered URL names the reynard service on a link-local address
  (check-regexp-match #px"rr\\+tcp://\\[fe80:[^]]*%25[^]]+\\]:29200/[^)]*service=reynard" output))

(test-case "find-node-by-name lists every path and connects"
  (define-values (code output) (run "find-node-by-name.rkt"))
  (check-ran code output)
  (check-regexp-match #rx"NodeName: experimental.reynard_the_robot\n" output)
  (check-regexp-match #px"NodeID: \\{[0-9a-f-]{36}\\}" output))

(test-case "find-node-by-id finds the same node, with or without braces"
  (define id (rr-node-info-nodeid (car (rr-find-node-by-name "experimental.reynard_the_robot"))))
  (for ([arg (list id (substring id 1 37))])
    (define-values (code output) (run "find-node-by-id.rkt" arg))
    (check-ran code output)
    (check-regexp-match (regexp (regexp-quote (string-append "NodeID: " id))) output)))

(test-case "unknown type or name exits with an error"
  (define-values (code1 output1) (run "find-service-by-type.rkt" "experimental.no_such.Type"))
  (check-not-equal? code1 0)
  (check-regexp-match #rx"no experimental.no_such.Type service found" output1)
  (define-values (code2 output2) (run "find-node-by-name.rkt" "no.such.node"))
  (check-not-equal? code2 0)
  (check-regexp-match #rx"no node named no.such.node found" output2))
