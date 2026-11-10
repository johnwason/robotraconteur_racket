#lang racket/base
;; Running example programs from tests.
(require racket/port compiler/find-exe)

(provide run/timeout
         run-racket)

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

;; Runs a Racket program file with arguments, capped at `secs` seconds
(define (run-racket secs file . args)
  (apply run/timeout secs (find-exe) (if (path? file) (path->string file) file) args))
