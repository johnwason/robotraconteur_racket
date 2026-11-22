#lang racket/base
;; A minimal fake Robot Raconteur service on loopback TCP for unit tests. It
;; answers the transport handshake, ConnectClientCombined (with the given
;; service definition and root object type), ConnectionTest and
;; DisconnectClient, and passes every other entry to (handler entry send!),
;; where (send! entries) sends entries to the client. Serves one client.
(require racket/tcp "../../robotraconteur/message.rkt")
(provide serve-fake)

(define service-nodeid (make-bytes 16 7))

;; Returns the port number.
(define (serve-fake robdef objtype handler)
  (define l (tcp-listen 0 1 #t "127.0.0.1"))
  (define-values (_a port _b _c) (tcp-addresses l #t))
  (thread
   (lambda ()
     (define-values (in out) (tcp-accept l))
     (tcp-close l)
     (define client-nodeid (make-bytes 16 0))
     (define client-ep 0)
     (define lock (make-semaphore 1))
     (define (send! entries)
       (call-with-semaphore
        lock
        (lambda ()
          (write-bytes (message->bytes (message service-nodeid client-nodeid 1 client-ep "fake" ""
                                                "" 0 0 entries))
                       out)
          (flush-output out))))
     (define (reply en type . elems)
       (send! (list (entry type (entry-service-path en) (entry-member-name en)
                           (entry-request-id en) 0 "" elems))))
     (let loop ()
       (define m (with-handlers ([exn:fail? (lambda (e) eof)]) (read-message in)))
       (unless (eof-object? m)
         (set! client-nodeid (message-sender-nodeid m))
         (set! client-ep (message-sender-ep m))
         (for ([en (in-list (message-entries m))])
           (case (entry-type en)
             [(StreamOp) (reply en 'StreamOpRet)]
             [(ConnectClientCombined)
              (reply en 'ConnectClientCombinedRet
                     (make-elem "servicedefs" dt-list (list (make-elem "0" dt-string robdef)))
                     (make-elem "objecttype" dt-string objtype))]
             [(ConnectionTest) (reply en 'ConnectionTestRet)]
             [(DisconnectClient) (reply en 'DisconnectClientRet)]
             [else (handler en send!)]))
         (loop)))))
  port)
