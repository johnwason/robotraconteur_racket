#lang racket/base
;; Interop test against a standard com.robotraconteur.robotics.robot.Robot
;; service: test/loopback_robot.py (AbstractRobot driver whose measured joint
;; position follows the command).
(require rackunit racket/list racket/math
         robotraconteur)

(define url (or (getenv "RR_ROBOT_URL") "rr+tcp://127.0.0.1:59926/?service=robot"))
(define c (rr-connect url))

(define (vec-close? a b [tol 1e-3])
  (and (= (vector-length a) (vector-length b))
       (for/and ([x a] [y b]) (< (abs (- x y)) tol))))

(define state-wire (rr-wire-connect c "robot_state"))
(define (state) (rr-wire-wait-in-value state-wire))
(define (joint-pos) (rr-struct-ref (state) "joint_position"))

;; wait (up to timeout s) for the measured joint position to reach target;
;; returns #t, or the last measured position so a failure shows it
(define (wait-for-position target [timeout 10] #:tol [tol 1e-3])
  (let loop ([t 0.0])
    (define pos (joint-pos))
    (cond [(vec-close? pos target tol) #t]
          [(> t timeout) pos]
          [else (sleep 0.05) (loop (+ t 0.05))])))

(test-case "connect and read standard types"
  (check-equal? (rr-object-type c) "com.robotraconteur.robotics.robot.Robot")
  (check-true (hash-has-key? (rr-service-definitions c) "com.robotraconteur.robotics.robot"))
  (define info (rr-get c "robot_info"))
  (check-equal? (rr-struct-type info) "com.robotraconteur.robotics.robot.RobotInfo")
  (define dev (rr-struct-ref (rr-struct-ref info "device_info") "device"))
  (check-equal? (rr-struct-ref dev "name") "abb_robot")
  (check-equal? (length (rr-struct-ref info "joint_info")) 6)
  (check-equal? (hash-ref (rr-attributes c) "model") "ABB_1200_5_90|9ad3c0ee-ec5e-4057-a297-d340e1484f01")
  ;; members inherited through "implements Device"
  (check-equal? (rr-struct-ref (rr-struct-ref (rr-get c "device_info") "device") "name") "abb_robot")
  (check-equal? (rr-get c "controller_state") 2)     ; motor_on
  (check-equal? (vector-length (joint-pos)) 6))

(test-case "speed_ratio and device clock"
  (rr-set! c "speed_ratio" 1.0)
  (check-equal? (rr-get c "speed_ratio") 1.0)
  (define-values (t ts) (rr-wire-peek-in c "device_clock_now"))
  (check-equal? (rr-struct-type t) "com.robotraconteur.device.clock.DeviceTime"))

(test-case "jog_freespace"
  (rr-set! c "command_mode" 'halt)
  (rr-set! c "command_mode" 'jog)
  (check-equal? (rr-get c "command_mode") 1)
  (define target (vector 0.1 -0.2 0.3 0.0 0.2 -0.1))
  (rr-call c "jog_freespace" target (make-vector 6 1.0) #t)
  (check-equal? (wait-for-position target) #t))

(test-case "execute_trajectory (generator of TrajectoryStatus)"
  (rr-set! c "command_mode" 'halt)
  (rr-set! c "command_mode" 'trajectory)
  (define start (joint-pos))
  (define end (vector 0.5 0.4 -0.3 0.2 -0.1 0.6))
  (define (waypoint pos t)
    (define w (rr-new-structure c "com.robotraconteur.robotics.trajectory.JointTrajectoryWaypoint"))
    (rr-struct-set! w "joint_position" pos)
    (rr-struct-set! w "time_from_start" t)
    w)
  (define traj (rr-new-structure c "com.robotraconteur.robotics.trajectory.JointTrajectory"))
  (rr-struct-set! traj "joint_names"
                  (for/list ([j (rr-struct-ref (rr-get c "robot_info") "joint_info")])
                    (rr-struct-ref (rr-struct-ref j "joint_identifier") "name")))
  ;; AbstractRobot requires >= 5 waypoints at most 100 ms apart: interpolate linearly
  (define n 30)
  (rr-struct-set! traj "waypoints"
                  (for/list ([i (in-range (add1 n))])
                    (define s (/ i n))
                    (waypoint (for/vector ([a start] [b end]) (+ a (* s (- b a))))
                              (* 1.5 s))))
  (define gen (rr-call c "execute_trajectory" traj))
  (define statuses (rr-generator->list gen))
  (check-true (pair? statuses))
  (check-equal? (rr-struct-type (last statuses)) "com.robotraconteur.robotics.trajectory.TrajectoryStatus")
  ;; AbstractRobot samples the trajectory every update period (10 ms), so the
  ;; final setpoint can stop up to one step short of the last waypoint:
  ;; max joint speed * period = (0.6 rad / 1.5 s) * 0.01 s = 0.004 rad.
  (check-equal? (wait-for-position end 3 #:tol 5e-3) #t))

(test-case "streaming position_command wire"
  (rr-set! c "command_mode" 'halt)
  (rr-set! c "command_mode" 'position_command)
  (define cmd-wire (rr-wire-connect c "position_command"))
  (define target (vector -0.3 0.1 0.2 -0.4 0.5 0.0))
  (for ([i (in-range 1 51)])
    (define cmd (rr-new-structure c "com.robotraconteur.robotics.robot.RobotJointCommand"))
    (rr-struct-set! cmd "seqno" i)
    (rr-struct-set! cmd "state_seqno" (rr-struct-ref (state) "seqno"))
    (rr-struct-set! cmd "command" target)
    (rr-wire-set-out-value! cmd-wire cmd)
    (sleep 0.01))
  (check-equal? (wait-for-position target 2) #t)
  (rr-wire-close cmd-wire)
  (rr-set! c "command_mode" 'halt))

(test-case "close"
  (rr-wire-close state-wire)
  (rr-close c))
