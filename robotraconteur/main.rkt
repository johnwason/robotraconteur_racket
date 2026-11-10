#lang racket/base
;; Simple Robot Raconteur client for Racket.
(require "client.rkt" "discovery.rkt")
(provide (all-from-out "client.rkt")
         (all-from-out "discovery.rkt"))
