#lang racket/base
;; Minimal example: connect to the test service and use a few members.
;;   racket examples/simple.rkt [url]
(require "../robotraconteur/main.rkt" racket/cmdline)

(define url
  (command-line #:args ([u "rr+tcp://127.0.0.1:22222/?service=test"]) u))

(define obj (rr-connect url))
(printf "connected to ~a\n" obj)
(printf "members: ~a\n" (rr-object-members obj))

(printf "d1 = ~a\n" (rr-get obj "d1"))
(rr-set! obj "d1" 10.5)
(printf "d1 = ~a\n" (rr-get obj "d1"))
(printf "add(2, 3) = ~a\n" (rr-call obj "add" 2.0 3.0))

(rr-add-event-listener! obj "ev1" (lambda (msg val) (printf "event ev1: ~a ~a\n" msg val)))
(rr-call obj "fire_event" "hello")

(printf "count_to(3) -> ~a\n" (rr-generator->list (rr-call obj "count_to" 3)))
(printf "sub.name = ~a\n" (rr-get (rr-objref obj "sub") "name"))

(define-values (v ts) (rr-wire-peek-in obj "w_in"))
(printf "w_in = ~a at ~a\n" v ts)

(sleep 0.2)
(rr-close obj)
