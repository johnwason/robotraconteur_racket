#lang racket/base
;; Runs the quick start client (examples/quickstart/reynard-quickstart-client.rkt)
;; against Reynard the Robot, as the README describes. run_tests.sh starts
;; Reynard (python -m reynard_the_robot) on port 29200.
(require rackunit racket/runtime-path "run-program.rkt")

(define-runtime-path client "../examples/quickstart/reynard-quickstart-client.rkt")

(test-case "quick start client calls say and teleport"
  (define-values (code output) (run-racket 60 client))
  (check-equal? code 0 (format "client failed:\n~a" output)))
