#lang racket/base
;; Helpers for the camera examples, standing in for ImageUtil from the Python
;; companion library and the OpenCV display calls.
;;
;; Images are converted to racket/draw bitmaps. Displaying them needs
;; racket/gui and a display, so it is loaded only when a window is requested;
;; without one the examples save PNG files instead.
(require racket/class racket/draw racket/math robotraconteur)

(provide image->bitmap
         compressed-image->bitmap
         compressed-image-extension
         save-bitmap
         make-image-window
         show-bitmap-until-closed
         stream-frames)

(define (data->bytes v)
  (if (bytes? v)
      v
      (let ([b (make-bytes (vector-length v))])
        (for ([x (in-vector v)] [i (in-naturals)]) (bytes-set! b i x))
        b)))

;; Name of an ImageEncoding value, e.g. 'rgb888
(define (encoding-name cam code)
  (for/first ([p (in-list (rr-enum-values cam "com.robotraconteur.image.ImageEncoding"))]
              #:when (= (cdr p) code))
    (string->symbol (car p))))

;; A com.robotraconteur.image.Image (raw pixels) as a bitmap.
;; Supports rgb888, bgr888, rgba8888, bgra8888 and mono8.
(define (image->bitmap cam img)
  (define info (rr-struct-ref img "image_info"))
  (define w (rr-struct-ref info "width"))
  (define h (rr-struct-ref info "height"))
  (define step (rr-struct-ref info "step"))
  (define enc (encoding-name cam (rr-struct-ref info "encoding")))
  (define data (data->bytes (rr-struct-ref img "data")))
  ;; byte offsets of red, green, blue (and alpha) within a pixel
  (define-values (bpp r g b a)
    (case enc
      [(rgb888) (values 3 0 1 2 #f)]
      [(bgr888) (values 3 2 1 0 #f)]
      [(rgba8888) (values 4 0 1 2 3)]
      [(bgra8888) (values 4 2 1 0 3)]
      [(mono8) (values 1 0 0 0 #f)]
      [else (error 'image->bitmap "unsupported image encoding ~a" enc)]))
  (define argb (make-bytes (* 4 w h)))
  (for* ([y (in-range h)] [x (in-range w)])
    (define src (+ (* y step) (* x bpp)))
    (define dst (* 4 (+ (* y w) x)))
    (bytes-set! argb dst (if a (bytes-ref data (+ src a)) 255))
    (bytes-set! argb (+ dst 1) (bytes-ref data (+ src r)))
    (bytes-set! argb (+ dst 2) (bytes-ref data (+ src g)))
    (bytes-set! argb (+ dst 3) (bytes-ref data (+ src b))))
  (define bm (make-bitmap w h #f))
  (send bm set-argb-pixels 0 0 w h argb)
  bm)

;; A com.robotraconteur.image.CompressedImage (JPEG or PNG data) as a bitmap
(define (compressed-image->bitmap img)
  (read-bitmap (open-input-bytes (data->bytes (rr-struct-ref img "data")))))

;; "jpg" or "png", from the data's signature
(define (compressed-image-extension img)
  (define b (data->bytes (rr-struct-ref img "data")))
  (cond
    [(and (>= (bytes-length b) 3) (equal? (subbytes b 0 3) #"\377\330\377")) "jpg"]
    [(and (>= (bytes-length b) 8) (equal? (subbytes b 0 8) #"\211PNG\r\n\32\n")) "png"]
    [else "bin"]))

(define (save-bitmap bm path)
  (send bm save-file path 'png))

;; A window showing bitmaps. Returns (values show! closed? pause! close!):
;;   (show! bitmap)  replaces the image
;;   (closed?)       #t once the window was closed or a key pressed
;;   (pause! secs)   waits while letting the window draw and handle input; use
;;                   it instead of sleep, which would block the window
;;   (close!)        closes the window; a racket/gui program does not exit
;;                   while a window is still shown
(define (make-image-window title)
  (define frame% (dynamic-require 'racket/gui/base 'frame%))
  (define canvas% (dynamic-require 'racket/gui/base 'canvas%))
  (define queue-callback (dynamic-require 'racket/gui/base 'queue-callback))
  (define sleep/yield (dynamic-require 'racket/gui/base 'sleep/yield))
  (define current #f)
  (define closed? #f)
  (define frame
    (new (class frame%
           (super-new)
           (define/augment (on-close) (set! closed? #t)))
         [label title] [width 960] [height 560]))
  (define canvas
    (new (class canvas%
           (super-new)
           (define/override (on-char e) (set! closed? #t)))
         [parent frame]
         [paint-callback
          (lambda (cv dc)
            (when current
              ;; scale to fit, keeping the aspect ratio
              (define-values (cw ch) (send cv get-client-size))
              (define s (min (/ cw (send current get-width)) (/ ch (send current get-height))))
              (send dc set-scale s s)
              (send dc draw-bitmap current 0 0)))]))
  (send frame show #t)
  (values (lambda (bm)
            (set! current bm)
            (queue-callback (lambda () (send canvas refresh))))
          (lambda () closed?)
          sleep/yield
          (lambda () (send frame show #f))))

;; Shows one bitmap until the window is closed or a key is pressed
(define (show-bitmap-until-closed bm title)
  (define-values (show! closed? pause! close!) (make-image-window title))
  (show! bm)
  (let wait () (unless (closed?) (pause! 0.05) (wait)))
  (close!))

;; Shared loop of the streaming examples. Connects `pipe-name`, starts
;; streaming, and converts the newest frame with `convert` (cam frame -> bitmap)
;; about every 50 ms, showing it in a window if `show?` or counting frames
;; otherwise. Stops when the window is closed, or after `duration` seconds
;; (#f = run until interrupted). Returns the last bitmap, or #f.
(define (stream-frames cam pipe-name convert #:show? show? #:duration duration)
  ;; Connect the pipe; the service chooses the endpoint index
  (define p (rr-pipe-connect cam pipe-name))
  ;; The listener only keeps the newest packet: listeners must not block, so
  ;; the (slower) conversion happens in the loop below
  (define newest (box #f))
  (define received (box 0))
  (rr-pipe-add-listener!
   p (lambda (ep)
       (let loop ()
         (define pkt (rr-pipe-try-receive ep))
         (when pkt
           (set-box! newest pkt)
           (set-box! received (add1 (unbox received)))
           (loop)))))
  ;; Start the camera streaming, ignore the error if it is already streaming
  (with-handlers ([exn:fail:robotraconteur?
                   (lambda (e) (printf "start_streaming: ~a\n" (exn-message e)))])
    (rr-call cam "start_streaming"))
  (define-values (show! closed? pause! close!)
    (if show?
        (make-image-window "Image")
        (values void (lambda () #f) sleep void)))
  (define t0 (current-inexact-milliseconds))
  (define (elapsed) (/ (- (current-inexact-milliseconds) t0) 1000.0))
  (define last-bm
    (let loop ([last #f] [last-report 0])
      (cond
        [(or (closed?) (and duration (> (elapsed) duration))) last]
        [else
         (define pkt (unbox newest))
         (set-box! newest #f)
         (define bm (if pkt (convert cam pkt) last))
         (when pkt (show! bm))
         (define report? (and (not show?) (>= (- (elapsed) last-report) 1.0)))
         (when report?
           (printf "~a s: ~a frames received\n" (exact-round (elapsed)) (unbox received)))
         (pause! 0.05)
         (loop bm (if report? (elapsed) last-report))])))
  (close!)
  (rr-pipe-close p)
  (rr-call cam "stop_streaming")
  last-bm)
