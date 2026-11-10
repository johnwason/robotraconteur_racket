#lang racket/base
;; Capture a single compressed frame from a standard camera and display or save it.
;; Port of examples/standard_devices/camera/python/camera_client_capture_frame_compressed.py
;; from the Robot Raconteur core repository.
;;
;;   racket camera-capture-frame-compressed.rkt [--show] [--output file] [url]
;;
;; By default connects to the training simulator's camera and saves the
;; compressed data as it arrives (camera_frame_compressed.jpg or .png).
;; --show decodes it and displays it in a window instead (needs a display).
(require robotraconteur racket/cmdline racket/class "camera-util.rkt")

(define show? #f)
(define output #f)
(define url
  (command-line
   #:once-each
   [("--show") "Display the frame in a window" (set! show? #t)]
   [("--output") file "Save the compressed data to this file" (set! output file)]
   #:args ([u "rr+tcp://localhost:59823?service=camera"]) u))

;; Connect to the camera
(define cam (rr-connect url))

;; Capture the compressed frame from the camera (JPEG or PNG data)
(define frame (rr-call cam "capture_frame_compressed"))
(rr-close cam)

;; Decode it to a bitmap
(define bm (compressed-image->bitmap frame))
(printf "captured ~ax~a ~a frame, ~a bytes\n" (send bm get-width) (send bm get-height)
        (compressed-image-extension frame) (vector-length (rr-struct-ref frame "data")))

(cond
  [show? (show-bitmap-until-closed bm "Image")]
  [else
   ;; Save the compressed data unchanged
   (define file (or output (string-append "camera_frame_compressed."
                                          (compressed-image-extension frame))))
   (call-with-output-file file #:exists 'replace
     (lambda (out)
       (for ([x (in-vector (rr-struct-ref frame "data"))]) (write-byte x out))))
   (printf "saved ~a\n" file)])
