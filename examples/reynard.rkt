#lang racket/base
;; Racket port of reynard-the-robot/examples/reynard_robotraconteur_client.py
;;   racket examples/reynard.rkt [url]
(require "../robotraconteur/main.rkt" racket/cmdline racket/math)

(define url
  (command-line #:args ([u "rr+tcp://localhost:29200?service=reynard"]) u))

(define (deg->rad d) (* d (/ pi 180.0)))

(define c (rr-connect url))
(printf "connected: ~a\n" c)

;; Listen for new messages
(rr-add-event-listener! c "new_message" (lambda (msg) (printf "New message: ~a\n" msg)))

;; Read the current state using a wire "peek"
(define-values (state ts) (rr-wire-peek-in c "state"))
(printf "state: ~a\n" state)

;; Teleport the robot
(rr-call c "teleport" 0.1 -0.2)
(printf "robot_position after teleport: ~a\n" (rr-get c "robot_position"))

;; Drive the robot with no timeout, then stop after one second
(rr-call c "drive_robot" 0.5 -0.2 -1.0 #f)
(sleep 1)
(rr-call c "drive_robot" 0.0 0.0 -1.0 #f)
(printf "robot_position after driving: ~a\n" (rr-get c "robot_position"))

;; Set the arm position, then drive it with a timeout and wait
(rr-call c "setf_arm_position" (deg->rad 100) (deg->rad -30) (deg->rad -70))
(rr-call c "drive_arm" (deg->rad 10) (deg->rad -30) (deg->rad -15) 1.5 #t)
(printf "arm position: ~a\n" (rr-call c "getf_arm_position"))

;; Stream state for a moment over a wire connection
(define w (rr-wire-connect c "state"))
(sleep 0.5)
(define s (rr-wire-in-value w))
(printf "streamed state: time=~a robot_position=~a arm_position=~a\n"
        (rr-struct-ref s "time") (rr-struct-ref s "robot_position") (rr-struct-ref s "arm_position"))
(rr-wire-close w)

;; Set the color to red, read it back, then reset it
(rr-set! c "color" (vector 1.0 0.0 0.0))
(printf "Color: ~a\n" (rr-get c "color"))
(sleep 1)
(rr-set! c "color" (vector 0.929 0.49 0.192))

;; Say hello
(rr-call c "say" "Hello, World From Racket!")
(sleep 0.5)
(rr-close c)
