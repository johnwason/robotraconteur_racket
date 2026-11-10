#lang racket/base
;; Capture a single frame from a standard camera and display or save it.
;; Port of examples/standard_devices/camera/python/camera_client_capture_frame.py
;; from the Robot Raconteur core repository.
;;
;;   racket camera-capture-frame.rkt [--show] [--output file.png] [url]
;;
;; By default connects to the training simulator's camera and saves the frame
;; to camera_frame.png. --show displays it in a window instead (needs a display).
(require robotraconteur racket/cmdline "camera-util.rkt")

(define show? #f)
(define output #f)
(define url
  (command-line
   #:once-each
   [("--show") "Display the frame in a window" (set! show? #t)]
   [("--output") file "Save the frame as PNG to this file" (set! output file)]
   #:args ([u "rr+tcp://localhost:59823?service=camera"]) u))

;; Connect to the camera
(define cam (rr-connect url))

;; Capture the frame from the camera, returns in raw format
(define raw-frame (rr-call cam "capture_frame"))
(define info (rr-struct-ref raw-frame "image_info"))
(printf "captured ~ax~a frame\n" (rr-struct-ref info "width") (rr-struct-ref info "height"))

;; Convert the raw image to a bitmap
(define bm (image->bitmap cam raw-frame))

(rr-close cam)

(cond
  [show? (show-bitmap-until-closed bm "Image")]
  [else
   (define file (or output "camera_frame.png"))
   (save-bitmap bm file)
   (printf "saved ~a\n" file)])
