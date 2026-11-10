#lang racket/base
;; Interop test against Reynard the Robot (pip package reynard-the-robot).
(require rackunit racket/math robotraconteur)

(define url (or (getenv "RR_REYNARD_URL") "rr+tcp://127.0.0.1:29200?service=reynard"))
(define c (rr-connect url))
(define (deg d) (* d (/ pi 180.0)))
(define (close? a b) (for/and ([x a] [y b]) (< (abs (- x y)) 1e-6)))

(test-case "state wire"
  (define-values (s ts) (rr-wire-peek-in c "state"))
  (check-equal? (rr-struct-type s) "experimental.reynard_the_robot.ReynardState")
  (check-equal? (vector-length (rr-struct-ref s "arm_position")) 3))

(test-case "teleport and drive"
  (rr-call c "teleport" 0.1 -0.2)
  (check-true (close? (rr-get c "robot_position") #(0.1 -0.2)))
  (check-exn exn:fail:robotraconteur? (lambda () (rr-call c "teleport" 5.0 0.0)))
  ;; base speed is capped at 0.1 m/s by Reynard
  (rr-call c "drive_robot" 0.05 0.0 0.5 #t)
  (check-true (< (abs (- (vector-ref (rr-get c "robot_position") 0) 0.125)) 0.01)))

(test-case "arm"
  (rr-call c "setf_arm_position" (deg 100) (deg -30) (deg -70))
  (check-true (close? (rr-call c "getf_arm_position") (vector (deg 100) (deg -30) (deg -70))))
  (rr-call c "drive_arm" (deg 10) 0.0 0.0 1.0 #t)
  (check-true (< (abs (- (vector-ref (rr-call c "getf_arm_position") 0) (deg 110))) (deg 1))))

(test-case "color and say"
  (rr-set! c "color" (vector 1.0 0.0 0.0))
  (check-equal? (rr-get c "color") (vector 1.0 0.0 0.0))
  (rr-call c "say" "Hello from Racket")
  (check-exn exn:fail:robotraconteur? (lambda () (rr-set! c "robot_position" (vector 0.0 0.0)))))

(test-case "close" (rr-close c))
