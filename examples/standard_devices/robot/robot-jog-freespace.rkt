#lang racket/base
;; Command the robot using the jog_freespace function.
;; Port of examples/standard_devices/robot/python/robot_client_jog_freespace.py
;; from the Robot Raconteur core repository.
;;
;;   racket robot-jog-freespace.rkt [--duration seconds] [url]
;;
;; By default connects to the training simulator's UR5e robot and runs until
;; interrupted.
(require robotraconteur racket/cmdline racket/math)

(define duration #f)
(define url
  (command-line
   #:once-each
   [("--duration") secs "Stop after this many seconds (default: run until interrupted)"
                   (set! duration (string->number secs))]
   #:args ([u "rr+tcp://localhost:52511?service=robot"]) u))

;; Connect to the robot driver
(define c (rr-connect url))

;; Retrieve the current robot state and print the current command mode
(define (robot-state) (let-values ([(s ts) (rr-wire-peek-in c "robot_state")]) s))
(displayln (rr-struct-ref (robot-state) "command_mode"))

;; Retrieve the "halt" and "jog" values of the RobotCommandMode enum
(define modes (rr-enum-values c "com.robotraconteur.robotics.robot.RobotCommandMode"))
(define halt-mode (cdr (assoc "halt" modes)))
(define jog-mode (cdr (assoc "jog" modes)))

;; Change the robot command mode, first to halt, then to jog
(rr-set! c "command_mode" halt-mode)
(sleep 0.1)
(rr-set! c "command_mode" jog-mode)

;; Get the starting joint positions
(define start-joint-pos (rr-struct-ref (robot-state) "joint_position"))

(define t-start (current-inexact-milliseconds))
(define (elapsed) (/ (- (current-inexact-milliseconds) t-start) 1000.0))

;; Move the robot in a loop
(let loop ()
  (define t (elapsed))
  (unless (and duration (> t duration))
    ;; Generate a sine wave on the first joint
    (define target
      (for/vector ([p (in-vector start-joint-pos)] [i (in-naturals)])
        (+ p (if (= i 0) (* 0.2 (sin (/ t 5))) 0.0))))
    (rr-call c "jog_freespace" target (make-vector (vector-length target) 1.0) #t)

    ;; Print the current robot_state_flags
    (printf "#x~a\n" (number->string (rr-struct-ref (robot-state) "robot_state_flags") 16))

    ;; Wait for the next loop iteration
    (sleep 0.1)
    (loop)))

(rr-close c)
