#lang racket/base
;; Helpers for the unit tests: build raw Message Version 2 bytes and measure
;; peak memory (Linux VmHWM).
(require racket/file racket/string)
(provide u16 u32 raw-element raw-message vm-hwm-kb)

(define (u16 n) (integer->integer-bytes n 2 #f #f))
(define (u32 n) (integer->integer-bytes n 4 #f #f))

;; An element with the given header fields and raw data bytes; the element
;; size field covers the bytes actually present.
(define (raw-element type count data)
  (define rest (bytes-append (u16 0) (u16 type) (u16 0) (u16 0) (u32 count) data))
  (bytes-append (u32 (+ 4 (bytes-length rest))) rest))

;; A message with one entry (FunctionCallRes) holding the given raw elements.
(define (raw-message . elems)
  (define en-rest (bytes-append (u16 1122) (u16 0) (u16 0) (u16 0) (u32 1) (u16 0) (u16 0)
                                (u16 (length elems)) (apply bytes-append elems)))
  (define en (bytes-append (u32 (+ 4 (bytes-length en-rest))) en-rest))
  (define hdr-tail (bytes-append (make-bytes 32 0) (u32 0) (u32 0) (u16 0) (u16 0) (u16 0)
                                 (u16 1) (u16 0) (u16 0)))
  (define hs (+ 12 (bytes-length hdr-tail)))
  (bytes-append #"RRAC" (u32 (+ hs (bytes-length en))) (u16 2) (u16 hs) hdr-tail en))

;; Peak resident memory of this process in kB, or #f off Linux
(define (vm-hwm-kb)
  (define f "/proc/self/status")
  (and (file-exists? f)
       (for/first ([l (in-list (file->lines f))] #:when (string-prefix? l "VmHWM:"))
         (string->number (cadr (string-split l))))))
