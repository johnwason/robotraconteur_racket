#lang racket/base
;; parse-robdef parses definitions sent by the service (up to the 12 MiB
;; message limit), so it must be linear in the text size. racket/string's
;; string-trim is quadratic in the length of a whitespace run inside the
;; string (a line with 160,000 spaces took 87 s), and imports were collected
;; with append per line (32,000 imports took 2 s, growing quadratically).
;; regexp-replace* and string-split on the whole text are also quadratic in
;; Racket CS (200,000 imports took 79 s). The sizes below take well under a
;; second when parsing is linear, so the 5 s limits leave room for slow
;; runners.
(require rackunit (prefix-in rs: racket/string) "../../robotraconteur/robdef.rkt")
(require/expose "../../robotraconteur/robdef.rkt" (string-trim))

(define (elapsed thunk)
  (define t0 (current-inexact-milliseconds))
  (thunk)
  (/ (- (current-inexact-milliseconds) t0) 1000.0))

(define head "service experimental.lin\n\nstdver 0.10\n\n")

(test-case "trimming matches racket/string's string-trim"
  (for ([s (in-list (list "" " " "a" " a " "\t\n a b \r\f\v" "\v a \f\r" "  x  y  " " a " "　b" "ab"))])
    (check-equal? (string-trim s) (rs:string-trim s) (format "~s" s))))

(test-case "a line with a long whitespace run parses in linear time"
  (define spaces (make-string 60000 #\space))
  (define text (string-append head "object O\n    property double" spaces "d\n"
                              "    property double e" spaces "\nend\n"))
  (define t (elapsed (lambda () (parse-robdef text))))
  (check-true (< t 5.0) (format "took ~a s" t)))

(test-case "many imports parse in linear time, in order"
  (define n 200000)
  (define text (apply string-append head
                      (for/list ([i (in-range n)]) (format "import experimental.imp~a\n" i))))
  (define d #f)
  (define t (elapsed (lambda () (set! d (parse-robdef text)))))
  (check-true (< t 5.0) (format "took ~a s" t))
  (check-equal? (length (servicedef-imports d)) n)
  (check-equal? (car (servicedef-imports d)) "experimental.imp0")
  (check-equal? (list-ref (servicedef-imports d) (sub1 n)) (format "experimental.imp~a" (sub1 n))))

(test-case "an enum with many values parses in linear time"
  (define n 400000)
  (define text (string-append head "enum E\n"
                              (apply string-append
                                     (for/list ([i (in-range n)]) (format "    v~a,\n" i)))
                              "end\n"))
  (define d #f)
  (define t (elapsed (lambda () (set! d (parse-robdef text)))))
  (check-true (< t 5.0) (format "took ~a s" t))
  (define vals (enumdef-values (hash-ref (servicedef-enums d) "E")))
  (check-equal? (length vals) n)
  (check-equal? (car vals) (cons "v0" 0)))
