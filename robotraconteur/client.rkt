#lang racket/base
;; Robot Raconteur client over the rr+tcp and rr+ws transports using Message Version 2.

(require racket/tcp racket/string racket/list racket/match racket/async-channel
         net/url net/uri-codec
         "message.rkt" "robdef.rkt" "pack.rkt" "websocket.rkt")

(provide rr-connect
         rr-close
         rr-object?
         rr-object-path
         rr-object-type
         rr-object-members
         rr-service-definitions
         rr-attributes
         rr-get
         rr-set!
         rr-call
         rr-objref
         rr-add-event-listener!
         rr-set-callback!
         rr-new-structure
         rr-enum-values
         ;; generators
         rr-generator?
         rr-generator-next
         rr-generator-close
         rr-generator->list
         ;; wires
         rr-wire-peek-in
         rr-wire-peek-out
         rr-wire-poke-out!
         rr-wire-connect
         rr-wire-connection?
         rr-wire-in-value
         rr-wire-in-value-valid?
         rr-wire-set-out-value!
         rr-wire-add-listener!
         rr-wire-close
         ;; pipes
         rr-pipe-connect
         rr-pipe-endpoint?
         rr-pipe-send
         rr-pipe-receive
         rr-pipe-try-receive
         rr-pipe-close
         ;; errors
         (struct-out exn:fail:robotraconteur)
         rr-error-type
         ;; values
         (struct-out rr-struct)
         (struct-out rr-multidim)
         (struct-out rr-varvalue)
         rr-struct-ref
         rr-struct-set!)

(define client-version "1.2.0")
(define request-timeout 30)

;; ---------------------------------------------------------------------------
;; Errors
;;
;; error-code    MessageErrorType code (rr-error-type gives it as a symbol)
;; error-name    e.g. "RobotRaconteur.InvalidOperation" or a service-defined
;;               exception such as "com.example.service.my_exception"
;; error-message the remote error string
;; error-subname optional sub-name ("" when absent)
;; error-param   optional varvalue parameter ('null when absent)

(struct exn:fail:robotraconteur exn:fail
  (error-code error-name error-message error-subname error-param)
  #:transparent)

(define (make-rr-exn code name msg [subname ""] [param 'null])
  (exn:fail:robotraconteur (format "~a: ~a" name msg) (current-continuation-marks)
                           code name msg subname param))

(define (raise-rr-error code name msg)
  (raise (make-rr-exn code name msg)))

;; Error type as a symbol, e.g. 'InvalidOperation, 'ObjectLockedError, 'RemoteError
(define (rr-error-type e) (message-error-symbol (exn:fail:robotraconteur-error-code e)))

(define (entry->exn c en)
  (define els (entry-elements en))
  (define (s nm) (let ([e (find-elem* els nm)]) (if e (elem-data e) "")))
  (define param-e (find-elem* els "errorparam"))
  (define param
    (if param-e
        (with-handlers ([exn:fail? (lambda (_) 'null)])
          (unpack-elem (conn-registry c) "" #f param-e))
        'null))
  (make-rr-exn (entry-error en) (s "errorname") (s "errorstring") (s "errorsubname") param))

;; ---------------------------------------------------------------------------
;; Connection state

(struct conn (in out
              write-lock
              local-nodeid
              [remote-nodeid #:mutable]
              [remote-nodename #:mutable]
              local-ep
              [remote-ep #:mutable]
              pending            ; rid -> channel
              pending-lock
              [next-rid #:mutable]
              registry
              event-listeners    ; (cons path member) -> list of procs
              callbacks          ; (cons path member) -> proc
              wires              ; (cons path member) -> wire-connection
              pipes              ; (list path member index) -> pipe-endpoint
              objects            ; path -> rr-object
              dispatch-ch        ; async channel of thunks (event ordering)
              [last-send #:mutable]
              [closed? #:mutable]
              [threads #:mutable]
              [attributes #:mutable]
              service-name)
  #:transparent)

(struct rr-object (conn path type ns def)
  #:methods gen:custom-write
  [(define (write-proc o port mode)
     (fprintf port "#<rr-object ~a ~a>" (rr-object-path o) (rr-object-type o)))])

;; ---------------------------------------------------------------------------
;; Sending / receiving

(define (send-entries! c entries)
  (define m (message (conn-local-nodeid c) (or (conn-remote-nodeid c) (make-bytes 16 0))
                     (conn-local-ep c) (conn-remote-ep c)
                     "" (or (conn-remote-nodename c) "") "" 0 0 entries))
  (send-message! c m))

(define (send-message! c m)
  (when (conn-closed? c) (raise-rr-error 1 "RobotRaconteur.ConnectionError" "connection closed"))
  (define b (message->bytes m))
  (call-with-semaphore
   (conn-write-lock c)
   (lambda ()
     (write-bytes b (conn-out c))
     (flush-output (conn-out c))))
  (set-conn-last-send! c (current-inexact-milliseconds)))

(define (process-request c en)
  (define rid
    (call-with-semaphore
     (conn-pending-lock c)
     (lambda ()
       (define r (conn-next-rid c))
       (set-conn-next-rid! c (if (>= r #xFFFFFFF0) 1 (add1 r)))
       r)))
  (define ch (make-channel))
  (define en2 (struct-copy entry en [request-id rid]))
  (call-with-semaphore (conn-pending-lock c)
                       (lambda () (hash-set! (conn-pending c) rid ch)))
  (dynamic-wind
   void
   (lambda ()
     (send-entries! c (list en2))
     (define res (sync/timeout request-timeout ch))
     (cond
       [(not res) (raise-rr-error 101 "RobotRaconteur.RequestTimeout" "request timed out")]
       [(eq? res 'closed) (raise-rr-error 1 "RobotRaconteur.ConnectionError" "connection closed")]
       [(not (zero? (entry-error res))) (raise (entry->exn c res))]
       [else res]))
   (lambda ()
     (call-with-semaphore (conn-pending-lock c)
                          (lambda () (hash-remove! (conn-pending c) rid))))))

(define response-types
  '(PropertyGetRes PropertySetRes FunctionCallRes GeneratorNextRes ObjectTypeNameRet
    ConnectClientRet ConnectClientCombinedRet DisconnectClientRet GetServiceDescRet
    PipeConnectRet PipeDisconnectRet ClientSessionOpRet WireConnectRet WireDisconnectRet
    MemoryReadRet MemoryWriteRet MemoryGetParamRet WirePeekInValueRet
    WirePeekOutValueRet WirePokeOutValueRet ServiceCheckCapabilityRet))

(define (handle-entry! c hdr en)
  (define t (entry-type en))
  ;; the service's endpoint id is learned from the connect response
  (when (and (memq t '(ConnectClientCombinedRet ConnectClientRet)) (zero? (entry-error en)))
    (set-conn-remote-ep! c (message-sender-ep hdr)))
  (cond
    [(eq? t 'ConnectionTest)
     (send-entries! c (list (entry 'ConnectionTestRet "" "" (entry-request-id en) 0 "" '())))]
    [(memq t '(ConnectionTestRet ClientKeepAliveRet EventRes CallbackCallRet WirePacketRet
               PipeClosedRet))
     (void)]
    [(memq t response-types)
     (define ch (call-with-semaphore (conn-pending-lock c)
                                     (lambda () (hash-ref (conn-pending c) (entry-request-id en) #f))))
     (when ch (thread (lambda () (channel-put ch en))))]
    [(eq? t 'EventReq) (dispatch-event! c en)]
    [(eq? t 'CallbackCallReq) (thread (lambda () (handle-callback! c en)))]
    [(eq? t 'WirePacket) (dispatch-wire-packet! c en)]
    [(eq? t 'WireClosed)
     (define w (hash-ref (conn-wires c) (cons (entry-service-path en) (entry-member-name en)) #f))
     (when w (set-wire-connection-closed?! w #t))]
    [(eq? t 'PipePacket) (dispatch-pipe-packet! c en)]
    [(eq? t 'PipeClosed)
     (define idx (elem-data (find-elem (entry-elements en) "index")))
     (define p (hash-ref (conn-pipes c)
                         (list (entry-service-path en) (entry-member-name en) (vector-ref idx 0)) #f))
     (when p (set-pipe-endpoint-closed?! p #t) (async-channel-put (pipe-endpoint-queue p) eof))]
    [(eq? t 'ServiceClosed) (shutdown! c)]
    [(eq? t 'EndpointCheckCapability)
     (send-entries! c (list (entry 'EndpointCheckCapabilityRet (entry-service-path en)
                                   (entry-member-name en) (entry-request-id en)
                                   (message-error-code 'InvalidOperation) "" '())))]
    [else (void)]))

(define (reader-loop c)
  (let loop ()
    (define m (with-handlers ([exn:fail? (lambda (e) eof)]) (read-message (conn-in c))))
    (cond
      [(eof-object? m) (shutdown! c)]
      [else
       (for ([en (in-list (message-entries m))])
         (with-handlers ([exn:fail? (lambda (e)
                                      (log-error "robotraconteur: error handling ~a: ~a"
                                                 (entry-type en) (exn-message e)))])
           (handle-entry! c m en)))
       (loop)])))

(define (heartbeat-loop c)
  (let loop ([last-keepalive (current-inexact-milliseconds)])
    (sleep 1)
    (unless (conn-closed? c)
      (define now (current-inexact-milliseconds))
      (with-handlers ([exn:fail? (lambda (e) (void))])
        (when (> (- now (conn-last-send c)) 5000)
          (send-entries! c (list (entry 'ConnectionTest "" "" 0 0 "" '())))))
      (cond
        [(> (- now last-keepalive) 60000)
         (with-handlers ([exn:fail? void])
           (send-entries! c (list (entry 'ClientKeepAliveReq (conn-service-name c) "" 0 0 "" '()))))
         (loop now)]
        [else (loop last-keepalive)]))))

(define (dispatch-loop c)
  (let loop ()
    (define th (async-channel-get (conn-dispatch-ch c)))
    (unless (eq? th 'stop)
      (with-handlers ([exn:fail? (lambda (e)
                                   (log-error "robotraconteur: listener error: ~a" (exn-message e)))])
        (th))
      (loop))))

(define (shutdown! c)
  (unless (conn-closed? c)
    (set-conn-closed?! c #t)
    (with-handlers ([exn:fail? void]) (close-output-port (conn-out c)))
    (with-handlers ([exn:fail? void]) (close-input-port (conn-in c)))
    (for ([ch (in-hash-values (conn-pending c))])
      (thread (lambda () (channel-put ch 'closed))))
    (for ([p (in-hash-values (conn-pipes c))])
      (async-channel-put (pipe-endpoint-queue p) eof))
    (async-channel-put (conn-dispatch-ch c) 'stop)))

;; ---------------------------------------------------------------------------
;; URL parsing:
;;   rr+tcp://host:port/?service=name[&nodename=..][&nodeid=..]
;;   rr+ws://host:port/[path]?service=name   (WebSocket, same port as rr+tcp)
;; Returns (values transport host port http-path service nodename nodeid)
;; where transport is 'tcp or 'ws.

(define (parse-rr-url s)
  (define u (string->url s))
  (define transport
    (case (url-scheme u)
      [("rr+tcp" "tcp") 'tcp]
      [("rr+ws") 'ws]
      [else (error 'rr-connect "unsupported URL scheme (expected rr+tcp or rr+ws): ~a" s)]))
  (define q (url-query u))
  (define service (cond [(assq 'service q) => cdr]
                        [else (error 'rr-connect "URL missing service: ~a" s)]))
  (define nodename (cond [(assq 'nodename q) => cdr] [else ""]))
  (define nodeid (cond [(assq 'nodeid q) => (lambda (p) (parse-nodeid (cdr p)))] [else #f]))
  ;; HTTP request target for the WebSocket upgrade: everything after host:port
  (define http-path
    (cond [(regexp-match #px"^[^:]+://[^/?]*(.*)$" s)
           => (lambda (m) (let ([p (cadr m)]) (if (string-prefix? p "/") p (string-append "/" p))))]
          [else "/"]))
  (values transport (url-host u) (or (url-port u) 48653) http-path service nodename nodeid))

(define (parse-nodeid s)
  (define hex (regexp-replace* #px"[{}-]" s ""))
  (unless (= (string-length hex) 32) (error 'rr-connect "invalid node id ~a" s))
  ;; NodeID string form is the UUID byte order
  (apply bytes (for/list ([i (in-range 16)])
                 (string->number (substring hex (* 2 i) (+ 2 (* 2 i))) 16))))

;; ---------------------------------------------------------------------------
;; Connect

(define (random-bytes n) (apply bytes (for/list ([i n]) (random 256))))
(define (random-u32) (+ 1 (random 4294967087)))

(define (rr-connect url #:username [username #f] #:credentials [credentials #f])
  (define-values (transport host port http-path service nodename nodeid) (parse-rr-url url))
  (define-values (in out)
    (case transport
      [(tcp) (tcp-connect host port)]
      [(ws) (ws-connect host port http-path)]))
  (define c (conn in out (make-semaphore 1) (random-bytes 16) nodeid nodename
                  (random-u32) 0 (make-hash) (make-semaphore 1) 1
                  (make-type-registry) (make-hash) (make-hash) (make-hash) (make-hash)
                  (make-hash) (make-async-channel) 0 #f '() (hash) service))
  (with-handlers ([(lambda (e) #t) (lambda (e) (shutdown! c) (raise e))])
    ;; 1. Transport handshake: StreamOp CreateConnection advertising Message V2 only
    (define cc (message (conn-local-nodeid c) (or nodeid (make-bytes 16 0)) 0 0 ""
                        nodename "" 0 0
                        (list (entry 'StreamOp "" "CreateConnection" 0 0 ""
                                     (list (make-elem "capabilities" dt-uint32
                                                      (vector #x02000003)))))))
    (send-message! c cc)
    (define ret (read-message in))
    (when (eof-object? ret) (raise-rr-error 1 "RobotRaconteur.ConnectionError" "connection closed during handshake"))
    (define ren (car (message-entries ret)))
    (unless (and (eq? (entry-type ren) 'StreamOpRet) (equal? (entry-member-name ren) "CreateConnection"))
      (raise-rr-error 2 "RobotRaconteur.ProtocolError" "unexpected handshake response"))
    (unless (memv (entry-error ren) '(0 2)) (raise (entry->exn c ren)))
    (set-conn-remote-nodeid! c (message-sender-nodeid ret))
    (set-conn-remote-nodename! c (message-sender-nodename ret))
    ;; start background threads
    (set-conn-threads! c (list (thread (lambda () (reader-loop c)))
                               (thread (lambda () (heartbeat-loop c)))
                               (thread (lambda () (dispatch-loop c)))))
    ;; 2. ConnectClientCombined: register client, pull service definitions and root type
    (define cred-elems
      (append
       (if username (list (make-elem "username" dt-string username)) '())
       (if credentials
           (list (pack-elem (conn-registry c) "" "credentials"
                            (parse-type "varvalue{string}") credentials))
           '())))
    (define res
      (process-request
       c (entry 'ConnectClientCombined service "" 0 0 ""
                (append (list (make-elem "clientversion" dt-string client-version)
                              (make-elem "returnservicedefs" dt-string "true"))
                        cred-elems))))
    (for ([e (in-list (elem-data (find-elem (entry-elements res) "servicedefs")))])
      (registry-add-def! (conn-registry c) (parse-robdef (elem-data e))))
    (define attrs (find-elem* (entry-elements res) "attributes"))
    (when attrs
      (set-conn-attributes! c (unpack-elem (conn-registry c) "" #f attrs)))
    (define objtype (elem-data (find-elem (entry-elements res) "objecttype")))
    (make-object c service objtype)))

(define (make-object c path qtype)
  (define-values (q kind def) (resolve-type (conn-registry c) "" qtype))
  (define o (rr-object c path q (car (string-split-last q)) def))
  (hash-set! (conn-objects c) path o)
  o)

(define (string-split-last q)
  (define parts (string-split q "."))
  (list (string-join (drop-right parts 1) ".") (last parts)))

(define (rr-close obj)
  (define c (rr-object-conn obj))
  (unless (conn-closed? c)
    (with-handlers ([exn:fail? void])
      (process-request c (entry 'DisconnectClient (conn-service-name c) "" 0 0 ""
                                (list (make-elem "servicename" dt-string (conn-service-name c))))))
    (shutdown! c)))

(define (rr-service-definitions obj)
  (for/hash ([(k v) (in-hash (type-registry-defs (conn-registry (rr-object-conn obj))))])
    (values k (servicedef-source v))))

(define (rr-attributes obj) (conn-attributes (rr-object-conn obj)))

(define (rr-new-structure obj type)
  (define o obj)
  (define-values (q kind def) (resolve-type (conn-registry (rr-object-conn o)) (rr-object-ns o) type))
  (new-structure (conn-registry (rr-object-conn o)) q))

;; Enum values as a list of (name . integer), name a string.
;; type may be qualified or relative to the object's service definition.
(define (rr-enum-values obj type)
  (define-values (q kind def) (resolve-type (conn-registry (rr-object-conn obj)) (rr-object-ns obj) type))
  (unless (eq? kind 'enum) (error 'rr-enum-values "~a is not an enum" q))
  (enumdef-values def))

;; ---------------------------------------------------------------------------
;; Members

;; all members including those of implemented objects
(define (object-members reg ns def)
  (append (entrydef-members def)
          (append*
           (for/list ([imp (in-list (entrydef-implements def))])
             (define-values (q k d) (resolve-type reg ns imp))
             (map (lambda (m) (cons (car (string-split-last q)) m))
                  (object-members reg (car (string-split-last q)) d))))))

;; returns (values member namespace)
(define (find-member obj name [kinds #f])
  (define reg (conn-registry (rr-object-conn obj)))
  (define r
    (for/first ([m (in-list (object-members reg (rr-object-ns obj) (rr-object-def obj)))]
                #:when (equal? (member-name (if (pair? m) (cdr m) m)) name))
      m))
  (unless r
    (raise-rr-error 9 "RobotRaconteur.MemberNotFound"
                    (format "member ~a not found in ~a" name (rr-object-type obj))))
  (define-values (mem ns)
    (if (pair? r) (values (cdr r) (car r)) (values r (rr-object-ns obj))))
  (when (and kinds (not (memq (member-kind mem) kinds)))
    (raise-rr-error 9 "RobotRaconteur.MemberNotFound"
                    (format "member ~a is a ~a, expected ~a" name (member-kind mem) kinds)))
  (values mem ns))

(define (rr-object-members obj)
  (for/list ([m (in-list (object-members (conn-registry (rr-object-conn obj))
                                         (rr-object-ns obj) (rr-object-def obj)))])
    (define mm (if (pair? m) (cdr m) m))
    (cons (member-kind mm) (member-name mm))))

(define (req obj type member . elems)
  (process-request (rr-object-conn obj) (entry type (rr-object-path obj) member 0 0 "" elems)))

(define (reg-of obj) (conn-registry (rr-object-conn obj)))

;; --- properties

(define (check-direction m forbidden code err)
  (when (member-has-modifier? m forbidden)
    (raise-rr-error code err (format "member ~a is ~a" (member-name m) forbidden))))

(define (member-has-modifier? m mod)
  (and (memf (lambda (x) (equal? x mod)) (member-modifiers m)) #t))

(define (rr-get obj name)
  (define-values (m ns) (find-member obj name '(property)))
  (check-direction m "writeonly" 103 "RobotRaconteur.WriteOnlyMember")
  (define res (req obj 'PropertyGetReq name))
  (unpack-elem (reg-of obj) ns (member-type m) (find-elem (entry-elements res) "value")))

(define (rr-set! obj name v)
  (define-values (m ns) (find-member obj name '(property)))
  (check-direction m "readonly" 102 "RobotRaconteur.ReadOnlyMember")
  (req obj 'PropertySetReq name (pack-elem (reg-of obj) ns "value" (member-type m) v))
  (void))

;; --- functions and generators

(struct rr-generator (obj member index ret-type param-type ns [done? #:mutable]))

(define (generator-type? td) (and td (eq? (typedef-container td) 'generator)))
(define (strip-generator td) (struct-copy typedef td [container #f]))

(define (rr-call obj name . args)
  (define-values (m ns) (find-member obj name '(function)))
  (define params (member-params m))
  (define ret-td (member-type m))
  ;; a trailing generator parameter is not sent with the call
  (define gen-param (and (pair? params) (generator-type? (cdr (last params))) (last params)))
  (define call-params (if gen-param (drop-right params 1) params))
  (unless (= (length args) (length call-params))
    (error 'rr-call "~a expects ~a arguments, got ~a" name (length call-params) (length args)))
  (define elems
    (for/list ([p (in-list call-params)] [a (in-list args)])
      (pack-elem (reg-of obj) ns (car p) (cdr p) a)))
  (define res (apply req obj 'FunctionCallReq name elems))
  (cond
    [(or (generator-type? ret-td) gen-param)
     (define idx (vector-ref (elem-data (find-elem (entry-elements res) "index")) 0))
     (rr-generator obj name idx
                   (if (generator-type? ret-td) (strip-generator ret-td) ret-td)
                   (and gen-param (strip-generator (cdr gen-param)))
                   ns #f)]
    [(eq? (typedef-base ret-td) 'void) (void)]
    [else (unpack-elem (reg-of obj) ns ret-td (find-elem (entry-elements res) "return"))]))

;; Returns the next value, or eof when the generator is exhausted.
(define (rr-generator-next g [param 'none])
  (cond
    [(rr-generator-done? g) eof]
    [else
     (define obj (rr-generator-obj g))
     (define elems
       (append (list (make-elem "index" dt-int32 (vector (rr-generator-index g))))
               (if (rr-generator-param-type g)
                   (list (pack-elem (reg-of obj) (rr-generator-ns g) "parameter"
                                    (rr-generator-param-type g) param))
                   '())))
     (with-handlers ([(lambda (e) (and (exn:fail:robotraconteur? e)
                                       (= (exn:fail:robotraconteur-error-code e)
                                          (message-error-code 'StopIteration))))
                      (lambda (e) (set-rr-generator-done?! g #t) eof)])
       (define res (apply req obj 'GeneratorNextReq (rr-generator-member g) elems))
       (define rt (rr-generator-ret-type g))
       (if (eq? (typedef-base rt) 'void)
           (void)
           (unpack-elem (reg-of obj) (rr-generator-ns g) rt
                        (find-elem (entry-elements res) "return"))))]))

(define (rr-generator-close g)
  (unless (rr-generator-done? g)
    (set-rr-generator-done?! g #t)
    (define obj (rr-generator-obj g))
    (with-handlers ([exn:fail:robotraconteur? void])
      (process-request (rr-object-conn obj)
                       (entry 'GeneratorNextReq (rr-object-path obj) (rr-generator-member g) 0
                              (message-error-code 'StopIteration) ""
                              (list (make-elem "errorname" dt-string "RobotRaconteur.StopIteration")
                                    (make-elem "errorstring" dt-string "")
                                    (make-elem "index" dt-int32 (vector (rr-generator-index g)))))))
    (void)))

(define (rr-generator->list g)
  (let loop ([acc '()])
    (define v (rr-generator-next g))
    (if (eof-object? v) (reverse acc) (loop (cons v acc)))))

;; --- objrefs

(define (encode-index s)
  (apply string-append
         (for/list ([ch (in-string s)])
           (if (and (char<? ch #\u80) (or (char-alphabetic? ch) (char-numeric? ch)))
               (string ch)
               (apply string-append
                      (for/list ([b (in-bytes (string->bytes/utf-8 (string ch)))])
                        (string-append "%" (if (< b 16) "0" "")
                                       (number->string b 16))))))))

(define (rr-objref obj name [index #f])
  (find-member obj name '(objref))
  (define c (rr-object-conn obj))
  (define path
    (string-append (rr-object-path obj) "." name
                   (if index
                       (string-append "[" (encode-index (if (number? index)
                                                            (number->string index)
                                                            index)) "]")
                       "")))
  (cond
    [(hash-ref (conn-objects c) path #f) => values]
    [else
     (define res (process-request c (entry 'ObjectTypeName path "" 0 0 ""
                                           (list (make-elem "clientversion" dt-string client-version)))))
     (define t (elem-data (find-elem (entry-elements res) "objecttype")))
     (define svc (car (string-split-last t)))
     (unless (hash-ref (type-registry-defs (conn-registry c)) svc #f)
       (define d (process-request c (entry 'GetServiceDesc path "" 0 0 ""
                                           (list (make-elem "ServiceType" dt-string svc)
                                                 (make-elem "clientversion" dt-string client-version)))))
       (registry-add-def! (conn-registry c)
                          (parse-robdef (elem-data (find-elem (entry-elements d) "servicedef")))))
     (make-object c path t)]))

;; --- events

(define (rr-add-event-listener! obj name proc)
  (find-member obj name '(event))
  (define k (cons (rr-object-path obj) name))
  (hash-update! (conn-event-listeners (rr-object-conn obj)) k
                (lambda (l) (append l (list proc))) '())
  (void))

(define (dispatch-event! c en)
  (define o (hash-ref (conn-objects c) (entry-service-path en) #f))
  (when o
    (define-values (m ns) (find-member o (entry-member-name en) '(event)))
    (define args
      (for/list ([p (in-list (member-params m))])
        (unpack-elem (conn-registry c) ns (cdr p) (find-elem (entry-elements en) (car p)))))
    (define ls (hash-ref (conn-event-listeners c) (cons (entry-service-path en) (entry-member-name en)) '()))
    (for ([l (in-list ls)])
      (async-channel-put (conn-dispatch-ch c) (lambda () (apply l args))))))

;; --- callbacks

(define (rr-set-callback! obj name proc)
  (find-member obj name '(callback))
  (hash-set! (conn-callbacks (rr-object-conn obj)) (cons (rr-object-path obj) name) proc)
  (void))

(define (handle-callback! c en)
  (define path (entry-service-path en))
  (define name (entry-member-name en))
  (define reply
    (with-handlers ([exn:fail?
                     (lambda (e)
                       ;; Robot Raconteur errors keep their type; anything else
                       ;; is reported as a remote OperationFailed
                       (define-values (code ename msg)
                         (if (exn:fail:robotraconteur? e)
                             (values (exn:fail:robotraconteur-error-code e)
                                     (exn:fail:robotraconteur-error-name e)
                                     (exn:fail:robotraconteur-error-message e))
                             (values (message-error-code 'RemoteError)
                                     "RobotRaconteur.OperationFailed" (exn-message e))))
                       (entry 'CallbackCallRet path name (entry-request-id en) code ""
                              (list (make-elem "errorname" dt-string ename)
                                    (make-elem "errorstring" dt-string msg))))])
      (define o (hash-ref (conn-objects c) path))
      (define-values (m ns) (find-member o name '(callback)))
      (define proc (hash-ref (conn-callbacks c) (cons path name)
                             (lambda () (error "callback not set"))))
      (define args
        (for/list ([p (in-list (member-params m))])
          (unpack-elem (conn-registry c) ns (cdr p) (find-elem (entry-elements en) (car p)))))
      (define r (apply proc args))
      (define rt (member-type m))
      (entry 'CallbackCallRet path name (entry-request-id en) 0 ""
             (list (if (eq? (typedef-base rt) 'void)
                       (make-elem "return" dt-int32 (vector 0))
                       (pack-elem (conn-registry c) ns "return" rt r))))))
  (with-handlers ([exn:fail? void]) (send-entries! c (list reply))))

;; --- wires

(define (timespec-elem)
  (define ms (current-inexact-milliseconds))
  (define secs (inexact->exact (floor (/ ms 1000))))
  (define ns (inexact->exact (floor (* (- ms (* secs 1000)) 1e6))))
  (make-elem "packettime" dt-structure #:type-name "RobotRaconteur.TimeSpec"
             (list (make-elem "seconds" dt-int64 (vector secs))
                   (make-elem "nanoseconds" dt-int32 (vector ns)))))

;; returns (cons seconds nanoseconds)
(define (unpack-timespec en)
  (define t (elem-data (find-elem (entry-elements en) "packettime")))
  (cons (vector-ref (elem-data (find-elem t "seconds")) 0)
        (vector-ref (elem-data (find-elem t "nanoseconds")) 0)))

(define (wire-value obj m ns en)
  (unpack-elem (reg-of obj) ns (member-type m) (find-elem (entry-elements en) "packet")))

;; Returns (values value timespec) where timespec is (cons seconds nanoseconds)
(define (rr-wire-peek-in obj name)
  (define-values (m ns) (find-member obj name '(wire)))
  (define res (req obj 'WirePeekInValueReq name))
  (values (wire-value obj m ns res) (unpack-timespec res)))

(define (rr-wire-peek-out obj name)
  (define-values (m ns) (find-member obj name '(wire)))
  (define res (req obj 'WirePeekOutValueReq name))
  (values (wire-value obj m ns res) (unpack-timespec res)))

(define (rr-wire-poke-out! obj name v)
  (define-values (m ns) (find-member obj name '(wire)))
  (req obj 'WirePokeOutValueReq name (timespec-elem)
       (pack-elem (reg-of obj) ns "packet" (member-type m) v))
  (void))

(struct wire-connection (obj member ns [in-value #:mutable] [in-time #:mutable]
                             [listeners #:mutable] [closed? #:mutable]))
(define (rr-wire-connection? x) (wire-connection? x))

(define (rr-wire-connect obj name)
  (define-values (m ns) (find-member obj name '(wire)))
  (define c (rr-object-conn obj))
  (define w (wire-connection obj m ns 'unset #f '() #f))
  (hash-set! (conn-wires c) (cons (rr-object-path obj) name) w)
  (req obj 'WireConnectReq name)
  w)

(define (dispatch-wire-packet! c en)
  (define w (hash-ref (conn-wires c) (cons (entry-service-path en) (entry-member-name en)) #f))
  (when (and w (not (wire-connection-closed? w)))
    (define ts (unpack-timespec en))
    (define old (wire-connection-in-time w))
    ;; drop out-of-order packets
    (when (or (not old) (or (> (car ts) (car old))
                            (and (= (car ts) (car old)) (>= (cdr ts) (cdr old)))))
      (define v (wire-value (wire-connection-obj w) (wire-connection-member w)
                            (wire-connection-ns w) en))
      (set-wire-connection-in-value! w v)
      (set-wire-connection-in-time! w ts)
      (for ([l (in-list (wire-connection-listeners w))])
        (async-channel-put (conn-dispatch-ch c) (lambda () (l v ts)))))))

(define (rr-wire-in-value-valid? w) (not (eq? (wire-connection-in-value w) 'unset)))

;; Waits up to `timeout` seconds for a first value to arrive.
(define (rr-wire-in-value w #:timeout [timeout 5])
  (let loop ([t 0])
    (cond
      [(rr-wire-in-value-valid? w) (wire-connection-in-value w)]
      [(>= t timeout) (raise-rr-error 106 "RobotRaconteur.ValueNotSet" "wire value not set")]
      [else (sleep 0.01) (loop (+ t 0.01))])))

(define (rr-wire-set-out-value! w v)
  (define obj (wire-connection-obj w))
  (define m (wire-connection-member w))
  (send-entries! (rr-object-conn obj)
                 (list (entry 'WirePacket (rr-object-path obj) (member-name m) 0 0 "unreliable\n"
                              (list (timespec-elem)
                                    (pack-elem (reg-of obj) (wire-connection-ns w) "packet"
                                               (member-type m) v))))))

(define (rr-wire-add-listener! w proc)
  (set-wire-connection-listeners! w (append (wire-connection-listeners w) (list proc))))

(define (rr-wire-close w)
  (unless (wire-connection-closed? w)
    (set-wire-connection-closed?! w #t)
    (define obj (wire-connection-obj w))
    (hash-remove! (conn-wires (rr-object-conn obj))
                  (cons (rr-object-path obj) (member-name (wire-connection-member w))))
    (req obj 'WireDisconnectReq (member-name (wire-connection-member w)))
    (void)))

;; --- pipes

(struct pipe-endpoint (obj member ns index queue [next-packet #:mutable] [closed? #:mutable]))
(define (rr-pipe-endpoint? x) (pipe-endpoint? x))

(define (rr-pipe-connect obj name [index -1])
  (define-values (m ns) (find-member obj name '(pipe)))
  (define res (req obj 'PipeConnectReq name (make-elem "index" dt-int32 (vector index))))
  (define idx (vector-ref (elem-data (find-elem (entry-elements res) "index")) 0))
  (define p (pipe-endpoint obj m ns idx (make-async-channel) 1 #f))
  (hash-set! (conn-pipes (rr-object-conn obj)) (list (rr-object-path obj) name idx) p)
  p)

(define (dispatch-pipe-packet! c en)
  (define path (entry-service-path en))
  (define name (entry-member-name en))
  (define acks
    (for*/list ([pe (in-list (entry-elements en))]
                [idx (in-value (string->number (elem-name pe)))]
                [p (in-value (hash-ref (conn-pipes c) (list path name idx) #f))]
                #:when p
                [ack (in-value
                      (let* ([d (elem-data pe)]
                             [pnum (vector-ref (elem-data (find-elem d "packetnumber")) 0)]
                             [v (unpack-elem (conn-registry c) (pipe-endpoint-ns p)
                                             (member-type (pipe-endpoint-member p))
                                             (find-elem d "packet"))])
                        (async-channel-put (pipe-endpoint-queue p) v)
                        (and (find-elem* d "requestack")
                             (make-elem (elem-name pe) dt-uint32 (vector pnum)))))]
                #:when ack)
      ack))
  (unless (null? acks)
    (send-entries! c (list (entry 'PipePacketRet path name 0 0 "" acks)))))

;; Returns the packet number of the sent packet.
(define (rr-pipe-send p v)
  (define obj (pipe-endpoint-obj p))
  (define m (pipe-endpoint-member p))
  (define pnum (pipe-endpoint-next-packet p))
  (set-pipe-endpoint-next-packet! p (add1 pnum))
  (send-entries!
   (rr-object-conn obj)
   (list (entry 'PipePacket (rr-object-path obj) (member-name m) 0 0 ""
                (list (make-elem (number->string (pipe-endpoint-index p)) dt-dictionary
                                 (list (make-elem "packetnumber" dt-uint32 (vector pnum))
                                       (pack-elem (reg-of obj) (pipe-endpoint-ns p) "packet"
                                                  (member-type m) v)))))))
  pnum)

;; Blocks up to timeout seconds; returns eof when the pipe is closed.
(define (rr-pipe-receive p #:timeout [timeout 5])
  (define v (sync/timeout timeout (pipe-endpoint-queue p)))
  (unless v (raise-rr-error 110 "RobotRaconteur.OperationTimeout" "pipe receive timed out"))
  v)

(define (rr-pipe-try-receive p [default #f])
  (or (async-channel-try-get (pipe-endpoint-queue p)) default))

(define (rr-pipe-close p)
  (unless (pipe-endpoint-closed? p)
    (set-pipe-endpoint-closed?! p #t)
    (define obj (pipe-endpoint-obj p))
    (hash-remove! (conn-pipes (rr-object-conn obj))
                  (list (rr-object-path obj) (member-name (pipe-endpoint-member p)) (pipe-endpoint-index p)))
    (req obj 'PipeDisconnectReq (member-name (pipe-endpoint-member p))
         (make-elem "index" dt-int32 (vector (pipe-endpoint-index p))))
    (void)))
