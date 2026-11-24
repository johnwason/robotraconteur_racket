#lang racket/base
;; parse-robdef parses definitions sent by the service (up to the 12 MiB
;; message limit), so it must be linear in the text size. racket/string's
;; string-trim is quadratic in the length of a whitespace run inside the
;; string (a line with 160,000 spaces took 87 s), and imports were collected
;; with append per line (32,000 imports took 2 s, growing quadratically).
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
  (define n 100000)
  (define text (apply string-append head
                      (for/list ([i (in-range n)]) (format "import experimental.imp~a\n" i))))
  (define d #f)
  (define t (elapsed (lambda () (set! d (parse-robdef text)))))
  (check-true (< t 5.0) (format "took ~a s" t))
  (check-equal? (length (servicedef-imports d)) n)
  (check-equal? (car (servicedef-imports d)) "experimental.imp0")
  (check-equal? (list-ref (servicedef-imports d) (sub1 n)) (format "experimental.imp~a" (sub1 n))))
