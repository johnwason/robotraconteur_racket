#lang racket/base
;; Show live full-quality images streamed from a standard camera.
;; Port of examples/standard_devices/camera/python/camera_client_image.py
;; from the Robot Raconteur core repository.
;;
;;   racket camera-image.rkt [--show] [--duration seconds] [--output file.png] [url]
;;
;; Frames arrive on the frame_stream pipe. With --show they are displayed in a
;; window (needs a display) until it is closed or a key is pressed; otherwise
;; the example reports how many frames arrived and saves the last one.
(require robotraconteur racket/cmdline "camera-util.rkt")

(define show? #f)
(define duration #f)
(define output #f)
(define url
  (command-line
   #:once-each
   [("--show") "Display the stream in a window" (set! show? #t)]
   [("--duration") secs "Stop after this many seconds" (set! duration (string->number secs))]
   [("--output") file "Save the last frame as PNG to this file" (set! output file)]
   #:args ([u "rr+tcp://localhost:59823?service=camera"]) u))

;; Connect to the camera
(define cam (rr-connect url))

(define last-frame (stream-frames cam "frame_stream" image->bitmap
                                  #:show? show? #:duration duration))

(rr-close cam)

(when (and last-frame (not show?))
  (define file (or output "camera_stream_frame.png"))
  (save-bitmap last-frame file)
  (printf "saved last frame to ~a\n" file))
