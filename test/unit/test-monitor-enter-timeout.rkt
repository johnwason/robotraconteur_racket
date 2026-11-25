#lang racket/base
;; When a MonitorEnter request times out on the client (30 s request
;; timeout), the service may still grant the lock afterwards. The client then
;; sends MonitorExit so the session does not keep a lock it does not know
;; about. This test waits for the client's request timeout (about 30 s).
(require rackunit racket/async-channel "fake-service.rkt" "../../robotraconteur/message.rkt"
         "../../robotraconteur/client.rkt")

(define robdef "service experimental.fakemonitor\n\nstdver 0.10\n\nobject Obj\n    property double d\nend\n")

(test-case "a timed-out MonitorEnter is followed by MonitorExit"
  (define ops (make-async-channel))
  ;; the service never answers MonitorEnter (it is still waiting for the lock)
  (define (handler en send!)
    (when (eq? (entry-type en) 'ClientSessionOpReq)
      (async-channel-put ops (entry-member-name en))))
  (define port (serve-fake robdef "experimental.fakemonitor.Obj" handler))
  (define obj (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=svc" port) #:timeout 10))
  (define e (with-handlers ([exn:fail:robotraconteur? values]) (rr-monitor-enter obj 1000)))
  (check-pred exn:fail:robotraconteur? e)
  (check-equal? (and (exn:fail:robotraconteur? e) (exn:fail:robotraconteur-error-name e))
                "RobotRaconteur.RequestTimeout")
  (check-equal? (sync/timeout 5 ops) "MonitorEnter")
  (check-equal? (sync/timeout 5 ops) "MonitorExit")
  (rr-close obj))
