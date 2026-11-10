#lang racket/base
;; Runs the standard device examples (examples/standard_devices) as programs
;; against loopback devices and checks what they did.
;;
;; RR_EX_ROBOT_URL   test/loopback_robot.py (an ABB IRB 1200 configuration)
;; RR_EX_CAMERA_URL  test/loopback_camera.py (96x48 frames: red, green and blue
;;                   thirds)
(require rackunit racket/class racket/draw racket/file racket/list racket/port
         racket/runtime-path racket/string compiler/find-exe
         robotraconteur
         "../examples/standard_devices/camera/camera-util.rkt")

(define-runtime-path robot-dir "../examples/standard_devices/robot")
(define-runtime-path camera-dir "../examples/standard_devices/camera")

(define robot-url (getenv "RR_EX_ROBOT_URL"))
(define camera-url (getenv "RR_EX_CAMERA_URL"))
(define tmp (make-temporary-directory))

;; Runs a program with stdout and stderr captured; returns (values exit-code
;; output), with exit code 'timeout if it was killed after `secs` seconds.
;; The limit is enforced here rather than with GNU timeout: Racket 8.10 never
;; reaps a `timeout` child (it moves itself to its own process group), so
;; system* waited for ever.
(define (run/timeout secs exe . args)
  (define-values (p out in err) (apply subprocess #f #f 'stdout exe args))
  (close-output-port in)
  (define o (open-output-string))
  (define pump (thread (lambda () (copy-port out o))))
  (define done (sync/timeout secs p))
  (unless done
    (subprocess-kill p #t)
    (subprocess-wait p))
  ;; a grandchild (e.g. Xvfb under xvfb-run) may keep the pipe open
  (unless (sync/timeout 5 pump) (kill-thread pump))
  (close-input-port out)
  (values (if done (subprocess-status p) 'timeout) (get-output-string o)))

;; Runs an example; each run is capped at 90 s so a hang fails the test
;; instead of the whole run.
(define (run-example dir file . args)
  (apply run/timeout 90 (find-exe) (path->string (build-path dir file)) args))

(define-syntax-rule (check-example-ok code output)
  (check-equal? code 0 (format "example failed:\n~a" output)))

;; --- robot

(define (joints)
  (define c (rr-connect robot-url))
  (define-values (s ts) (rr-wire-peek-in c "robot_state"))
  (begin0 (vector->list (rr-struct-ref s "joint_position")) (rr-close c)))

(define (command-mode)
  (define c (rr-connect robot-url))
  (define-values (s ts) (rr-wire-peek-in c "robot_state"))
  (begin0 (rr-struct-ref s "command_mode") (rr-close c)))

(define (close-to? a b tol) (< (abs (- a b)) tol))

(test-case "robot: jog_freespace moves joint 0 only"
  (define before (joints))
  (define-values (code output) (run-example robot-dir "robot-jog-freespace.rkt" "--duration" "3" robot-url))
  (check-example-ok code output)
  (check-regexp-match #rx"#x[0-9a-f]+" output)            ; robot_state_flags printed
  (define after (joints))
  ;; 0.2 sin(t/5) after about 3 s is about 0.11
  (check-true (< 0.05 (- (first after) (first before)) 0.2) (format "~a -> ~a" before after))
  (for ([a (rest after)] [b (rest before)]) (check-true (close-to? a b 1e-3))))

(test-case "robot: position_command streams commands in position mode"
  (define before (joints))
  (define-values (code output) (run-example robot-dir "robot-position-command.rkt" "--duration" "3" robot-url))
  (check-example-ok code output)
  (check-equal? (command-mode) 3)                          ; position_command
  (define after (joints))
  (check-true (<= (abs (- (first after) (first before))) 0.21) (format "~a -> ~a" before after))
  (for ([a (rest after)] [b (rest before)]) (check-true (close-to? a b 1e-3))))

(test-case "robot: trajectories run, queue and finish at the target"
  (define-values (code output) (run-example robot-dir "robot-trajectory.rkt" "abb" robot-url))
  (check-example-ok code output)
  (define lines (string-split output "\n"))
  (check-not-false (member "queued" lines) output)        ; second trajectory waited
  (check-equal? (length (filter (lambda (l) (string-contains? l "complete")) lines)) 3 output)
  ;; the wave trajectories end where the first move ended
  (for ([a (joints)] [b '(0 -0.1 0.25 0 0 0)])
    (check-true (close-to? a b 5e-3) (format "joint ~a, expected ~a" a b))))

;; --- camera

(define (pixel bm x y)
  (define buf (make-bytes 4))
  (send bm get-argb-pixels x y 1 1 buf)
  (list (bytes-ref buf 1) (bytes-ref buf 2) (bytes-ref buf 3)))

;; red, green and blue thirds, as the loopback camera draws them
(define (check-thirds bm)
  (check-equal? (send bm get-width) 96)
  (check-equal? (send bm get-height) 48)
  (check-equal? (pixel bm 10 24) '(255 0 0))
  (check-equal? (pixel bm 48 24) '(0 255 0))
  (check-equal? (pixel bm 85 24) '(0 0 255)))

(test-case "camera: capture_frame converts the raw frame with the right colours"
  (define file (path->string (build-path tmp "raw.png")))
  (define-values (code output) (run-example camera-dir "camera-capture-frame.rkt" "--output" file camera-url))
  (check-example-ok code output)
  (check-regexp-match #rx"captured 96x48 frame" output)
  (check-thirds (read-bitmap file)))

(test-case "camera: capture_frame_compressed saves the compressed data unchanged"
  (define file (path->string (build-path tmp "compressed.png")))
  (define-values (code output)
    (run-example camera-dir "camera-capture-frame-compressed.rkt" "--output" file camera-url))
  (check-example-ok code output)
  (check-regexp-match #rx"captured 96x48 png frame" output)
  (check-equal? (subbytes (file->bytes file) 0 8) #"\211PNG\r\n\32\n")
  (check-thirds (read-bitmap file)))

(test-case "camera: frame_stream and preview_stream receive frames"
  (for ([ex '("camera-image.rkt" "camera-image-preview.rkt")])
    (define file (path->string (build-path tmp (string-append ex ".png"))))
    (define-values (code output) (run-example camera-dir ex "--duration" "2" "--output" file camera-url))
    (check-example-ok code output)
    (define counts (map string->number (regexp-match* #px"(\\d+) frames received" output #:match-select cadr)))
    (check-true (and (pair? counts) (> (last counts) 5)) output)
    (check-thirds (read-bitmap file))))

(test-case "camera: --show opens a window and exits (virtual display)"
  (define xvfb-run (find-executable-path "xvfb-run"))
  (when xvfb-run
    (for ([ex '("camera-image.rkt" "camera-image-preview.rkt")])
      (define-values (code output)
        (run/timeout 60 xvfb-run "-a" (find-exe) (path->string (build-path camera-dir ex))
                     "--show" "--duration" "2" camera-url))
      (check-equal? code 0 (format "~a --show: ~a" ex output)))))

(test-case "camera-util: all supported raw encodings convert correctly"
  ;; a 2x1 image: a red pixel, then a blue one
  (define cam (rr-connect camera-url))
  (define enc (rr-enum-values cam "com.robotraconteur.image.ImageEncoding"))
  (define (image encoding bpp data)
    (define info (rr-new-structure cam "com.robotraconteur.image.ImageInfo"))
    (rr-struct-set! info "width" 2)
    (rr-struct-set! info "height" 1)
    (rr-struct-set! info "step" (* 2 bpp))
    (rr-struct-set! info "encoding" (cdr (assoc encoding enc)))
    (define img (rr-new-structure cam "com.robotraconteur.image.Image"))
    (rr-struct-set! img "image_info" info)
    (rr-struct-set! img "data" (list->vector data))
    img)
  (for ([c (list (list "rgb888" 3 '(255 0 0 0 0 255))
                 (list "bgr888" 3 '(0 0 255 255 0 0))
                 (list "rgba8888" 4 '(255 0 0 255 0 0 255 255))
                 (list "bgra8888" 4 '(0 0 255 255 255 0 0 255)))])
    (define bm (image->bitmap cam (apply image c)))
    (check-equal? (list (pixel bm 0 0) (pixel bm 1 0)) '((255 0 0) (0 0 255)) (car c)))
  (define mono (image->bitmap cam (image "mono8" 1 '(10 200))))
  (check-equal? (list (pixel mono 0 0) (pixel mono 1 0)) '((10 10 10) (200 200 200)))
  (check-exn #rx"unsupported image encoding" (lambda () (image->bitmap cam (image "mono16" 2 '(0 0 0 0)))))
  (rr-close cam))

(delete-directory/files tmp)
