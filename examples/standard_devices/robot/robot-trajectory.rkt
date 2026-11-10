#lang racket/base
;; Send joint trajectories to the robot in trajectory mode.
;; Port of examples/standard_devices/robot/python/robot_client_trajectory.py
;; from the Robot Raconteur core repository.
;;
;;   racket robot-trajectory.rkt abb|ur [url]
;;
;; The first argument selects the target joint angles for the ABB IRB 1200 or
;; the UR5e. By default connects to the training simulator's UR5e robot.
(require robotraconteur racket/cmdline racket/math)

(define-values (robot-type url)
  (command-line
   #:args (robot-type [u "rr+tcp://localhost:52511?service=robot"])
   (values robot-type u)))

;; Connect to the robot
(define c (rr-connect url))

;; Get the joint names from the robot_info data structure
(define robot-info (rr-get c "robot_info"))
(define joint-names
  (for/list ([j (in-list (rr-struct-ref robot-info "joint_info"))])
    (rr-struct-ref (rr-struct-ref j "joint_identifier") "name")))

;; Retrieve the current robot state and print the current command mode
(let-values ([(s ts) (rr-wire-peek-in c "robot_state")])
  (displayln (rr-struct-ref s "command_mode")))

;; Retrieve the "halt" and "trajectory" values of the RobotCommandMode enum,
;; and the names of the ActionStatusCode values for printing
(define modes (rr-enum-values c "com.robotraconteur.robotics.robot.RobotCommandMode"))
(define halt-mode (cdr (assoc "halt" modes)))
(define trajectory-mode (cdr (assoc "trajectory" modes)))
(define status-names
  (for/hash ([p (rr-enum-values c "com.robotraconteur.action.ActionStatusCode")])
    (values (cdr p) (car p))))

;; Change the robot command mode, first to halt, then to trajectory
(rr-set! c "command_mode" halt-mode)
(sleep 0.1)
(rr-set! c "command_mode" trajectory-mode)

;; Connect to the robot_state wire to get real-time streaming state data
(define state-w (rr-wire-connect c "robot_state"))
;; Wait for the state wire to receive valid data
(define state1 (rr-wire-wait-in-value state-w))

(define (waypoint joint-position time-from-start)
  (define wp (rr-new-structure c "com.robotraconteur.robotics.trajectory.JointTrajectoryWaypoint"))
  (rr-struct-set! wp "joint_position" joint-position)
  (rr-struct-set! wp "time_from_start" time-from-start)
  wp)

(define (trajectory waypoints)
  (define traj (rr-new-structure c "com.robotraconteur.robotics.trajectory.JointTrajectory"))
  (rr-struct-set! traj "joint_names" joint-names)
  (rr-struct-set! traj "waypoints" waypoints)
  traj)

(define (print-status s)
  (printf "TrajectoryStatus: seqno ~a, ~a, waypoint ~a, time ~a\n"
          (rr-struct-ref s "seqno")
          (hash-ref status-names (rr-struct-ref s "action_status"))
          (rr-struct-ref s "current_waypoint")
          (rr-struct-ref s "trajectory_time")))

;; Monitor a trajectory until it finishes
(define (run-to-end gen print-one)
  (let loop ()
    (define st (rr-generator-next gen))
    (unless (eof-object? st)
      (print-one st)
      (loop))))

;; Build waypoints to move the robot from its current position to the
;; specified joint angles over 10 seconds
(define j-start (rr-struct-ref state1 "joint_position"))
(define j-end
  (case robot-type
    [("abb") (vector 0.0 -0.1 0.25 0.0 0.0 0.0)]
    [("ur") (vector 0.0 -1.0 -1.5 0.0 0.0 0.0)]
    [else (raise-user-error 'robot-trajectory "invalid robot type ~s (expected abb or ur)" robot-type)]))

(define move-waypoints
  (for/list ([i (in-range 251)])
    (waypoint (for/vector ([s (in-vector j-start)] [e (in-vector j-end)])
                (+ s (* (- e s) (/ i 250.0))))
              (/ i 25.0))))

(rr-set! c "speed_ratio" 1.0)

;; Execute the trajectory to get the generator, and monitor the motion
(define traj-gen (rr-call c "execute_trajectory" (trajectory move-waypoints)))
(run-to-end traj-gen
            (lambda (st)
              (print-status st)
              (let-values ([(s ts) (rr-wire-peek-in c "robot_state")])
                (printf "#x~a\n" (number->string (rr-struct-ref s "robot_state_flags") 16)))))

;; Execute more trajectories. Trajectories are queued if executed concurrently.
(define wave-waypoints
  (for/list ([i (in-range 251)])
    (define t (/ i 25.0))
    (define amp (* (degrees->radians 15) (sin (* 2 pi (/ t 10.0)))))
    (waypoint (for/vector ([e (in-vector j-end)] [k (in-list '(1 0 0 0 0.5 -1))])
                (+ e (* amp k)))
              t)))

(rr-set! c "speed_ratio" 0.5)
(define traj-gen1 (rr-call c "execute_trajectory" (trajectory wave-waypoints)))

(rr-set! c "speed_ratio" 2.0)
(define traj-gen2 (rr-call c "execute_trajectory" (trajectory wave-waypoints)))

;; The second trajectory waits in the queue until the first one finishes
(displayln (hash-ref status-names (rr-struct-ref (rr-generator-next traj-gen2) "action_status")))

(define (print-action-status st)
  (displayln (hash-ref status-names (rr-struct-ref st "action_status"))))
(run-to-end traj-gen1 print-action-status)
(run-to-end traj-gen2 print-action-status)

(rr-wire-close state-w)
(rr-close c)
