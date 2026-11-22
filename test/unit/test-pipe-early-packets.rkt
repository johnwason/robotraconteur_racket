#lang racket/base
;; Pipe packets for an endpoint the client has not connected yet are kept for
;; the endpoint only while a connect for that index (or any index) is in
;; progress, as in the C++ core. The index comes from the service, so packets
;; for other indexes must not be kept forever.
(require rackunit "fake-service.rkt" "../../robotraconteur/message.rkt"
         "../../robotraconteur/client.rkt")
(require/expose "../../robotraconteur/client.rkt" (conn-early-pipes rr-object-conn))

(define robdef "service experimental.fakepipe\n\nstdver 0.10\n\nobject Obj\n    property double d\n    pipe double p\nend\n")

(define (packets idxs)
  (entry 'PipePacket "svc" "p" 0 0 ""
         (for/list ([i (in-list idxs)])
           (make-elem (number->string i) dt-dictionary
                      (list (make-elem "packetnumber" dt-uint32 (vector 1))
                            (make-elem "packet" dt-double (vector (exact->inexact i))))))))

;; PropertyGetReq: first send packets for 1000 endpoints nobody connects.
;; PipeConnectReq: send a packet for the new endpoint (index 5, or the
;; requested one) and 100 packets for other indexes, then PipeConnectRet.
(define (handler en send!)
  (case (entry-type en)
    [(PropertyGetReq)
     (send! (list (packets (for/list ([i 1000]) (+ 100 i)))))
     (send! (list (entry 'PropertyGetRes "svc" "d" (entry-request-id en) 0 ""
                         (list (make-elem "value" dt-double (vector 1.0))))))]
    [(PipeConnectReq)
     (define want (vector-ref (elem-data (find-elem (entry-elements en) "index")) 0))
     (define idx (if (= want -1) 5 want))
     (send! (list (packets (list idx))))
     (send! (list (packets (for/list ([i 100]) (+ 2000 i)))))
     (send! (list (entry 'PipeConnectRet "svc" "p" (entry-request-id en) 0 ""
                         (list (make-elem "index" dt-int32 (vector idx))))))]
    [else (void)]))

(define (connect)
  (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=svc" (serve-fake robdef "experimental.fakepipe.Obj" handler))
              #:timeout 10))

(test-case "packets for endpoints nobody is connecting are not kept"
  (define obj (connect))
  ;; the packets arrive before the property value, on the same stream
  (check-equal? (rr-get obj "d") 1.0)
  (check-equal? (hash-count (conn-early-pipes (rr-object-conn obj))) 0)
  (rr-close obj))

(test-case "a packet that arrives before PipeConnectRet is delivered; others are dropped"
  (define obj (connect))
  (define p (rr-pipe-connect obj "p" 7))
  (check-equal? (rr-pipe-endpoint-index p) 7)
  (check-equal? (rr-pipe-receive p #:timeout 5) 7.0)
  (check-equal? (hash-count (conn-early-pipes (rr-object-conn obj))) 0)
  (define p2 (rr-pipe-connect obj "p"))
  (check-equal? (rr-pipe-endpoint-index p2) 5)
  (check-equal? (rr-pipe-receive p2 #:timeout 5) 5.0)
  (check-equal? (hash-count (conn-early-pipes (rr-object-conn obj))) 0)
  (rr-close obj))
