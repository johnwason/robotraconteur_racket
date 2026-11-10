#lang racket/base
;; Command the robot in real time using the position_command wire.
;; Port of examples/standard_devices/robot/python/robot_client_position_command.py
;; from the Robot Raconteur core repository.
;;
;;   racket robot-position-command.rkt [--duration seconds] [url]
;;
;; By default connects to the training simulator's UR5e robot and runs until
;; interrupted.
(require robotraconteur racket/cmdline)

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
(let-values ([(s ts) (rr-wire-peek-in c "robot_state")])
  (displayln (rr-struct-ref s "command_mode")))

;; Retrieve the "halt" and "position_command" values of the RobotCommandMode enum
(define modes (rr-enum-values c "com.robotraconteur.robotics.robot.RobotCommandMode"))
(define halt-mode (cdr (assoc "halt" modes)))
(define position-mode (cdr (assoc "position_command" modes)))

;; Change the robot command mode, first to halt, then to position_command
(rr-set! c "command_mode" halt-mode)
(sleep 0.1)
(rr-set! c "command_mode" position-mode)
(sleep 0.1)

;; Connect to the position_command and robot_state wires for real-time data streaming
(define cmd-w (rr-wire-connect c "position_command"))
(define state-w (rr-wire-connect c "robot_state"))
;; Set a lifespan of 0.5 seconds for the robot state. If new packets are not
;; received within 0.5 seconds, rr-wire-in-value raises ValueNotSet.
(rr-wire-set-in-value-lifespan! state-w 0.5)

;; Wait for the state wire to receive valid data, and get the starting joint position
(define init-joint-pos (rr-struct-ref (rr-wire-wait-in-value state-w) "joint_position"))

(define t0 (current-inexact-milliseconds))
(define (elapsed) (/ (- (current-inexact-milliseconds) t0) 1000.0))

;; command_seqno must increase with each position command
(let loop ([command-seqno 2])
  (define t (elapsed))
  (unless (and duration (> t duration))
    ;; Retrieve the current robot state
    (define robot-state (rr-wire-in-value state-w))

    ;; Make sure the robot is still in position mode
    (unless (= (rr-struct-ref robot-state "command_mode") position-mode)
      (error 'robot-position-command "robot is not in position mode"))

    ;; Fill in a RobotJointCommand structure
    (define joint-cmd (rr-new-structure c "com.robotraconteur.robotics.robot.RobotJointCommand"))
    (rr-struct-set! joint-cmd "seqno" command-seqno)            ; strictly increasing
    (rr-struct-set! joint-cmd "state_seqno" (rr-struct-ref robot-state "seqno")) ; failsafe
    ;; The joint command, in this case a sine wave on the first joint
    (rr-struct-set! joint-cmd "command"
                    (for/vector ([p (in-vector init-joint-pos)] [i (in-naturals)])
                      (+ p (if (= i 0) (* 0.2 (sin t)) 0.0))))

    ;; Send the joint command to the robot
    (rr-wire-set-out-value! cmd-w joint-cmd)

    ;; Wait for the next iteration
    (sleep 0.01)
    (loop (add1 command-seqno))))

(rr-wire-close cmd-w)
(rr-wire-close state-w)
(rr-close c)
