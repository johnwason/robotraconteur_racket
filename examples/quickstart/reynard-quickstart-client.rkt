#lang racket/base
;; reynard-quickstart-client.rkt
;; The Robot Raconteur quick start client in Racket, using Reynard the Robot
;; as the device. Start Reynard first (python -m reynard_the_robot), then:
;;   racket reynard-quickstart-client.rkt

(require robotraconteur)

;; Connect to the service
(define obj (rr-connect "rr+tcp://localhost:29200?service=reynard"))

;; Call the say function
(rr-call obj "say" "Hello from Racket!")

;; Call the teleport function (meters)
(rr-call obj "teleport" 0.1 -0.2)

(rr-close obj)
