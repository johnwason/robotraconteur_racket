#lang racket/base
;; Minimal RFC 6455 WebSocket client used as a byte-stream transport.
;;
;; Robot Raconteur treats the WebSocket as a plain byte stream: binary frame
;; payloads are concatenated and parsed as ordinary "RRAC" messages (see
;; robotraconteurlite tcp_transport.c). ws-connect returns an input and output
;; port pair so the rest of the client is transport agnostic.
;;
;; With #:tls, the TCP connection is wrapped in standard TLS first (wss://).
;; This is ordinary web TLS (certificate chain and hostname checked by the
;; given OpenSSL client context), not Robot Raconteur's own rrs+ STARTTLS.

(require racket/tcp racket/port racket/string file/sha1 net/base64 openssl)

(provide ws-connect
         ws-handshake)

(define rr-subprotocol "robotraconteur.robotraconteur.com")
(define ws-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(define (random-bytes n) (apply bytes (for/list ([i n]) (random 256))))

(define (b64 b) (bytes->string/utf-8 (base64-encode b #"")))

;; Read an HTTP response header block; returns (values status-line headers-hash)
(define (read-http-header in)
  (define status (read-line in 'return-linefeed))
  (when (eof-object? status) (error 'ws-connect "connection closed during WebSocket handshake"))
  (define headers
    (let loop ([h (hash)])
      (define l (read-line in 'return-linefeed))
      (cond
        [(or (eof-object? l) (equal? l "")) h]
        [(regexp-match #px"^([^:]+):\\s*(.*)$" l)
         => (lambda (m) (loop (hash-set h (string-downcase (cadr m)) (string-trim (caddr m)))))]
        [else (loop h)])))
  (values status headers))

;; Perform the client handshake over already-connected raw ports.
;; host-header is "host:port"; path includes any query string ("/?service=x").
(define (ws-handshake raw-in raw-out host-header path)
  (define key (b64 (random-bytes 16)))
  (write-string
   (string-append "GET " path " HTTP/1.1\r\n"
                  "Host: " host-header "\r\n"
                  "Upgrade: websocket\r\n"
                  "Connection: Upgrade\r\n"
                  "Sec-WebSocket-Key: " key "\r\n"
                  "Sec-WebSocket-Protocol: " rr-subprotocol "\r\n"
                  "Sec-WebSocket-Version: 13\r\n\r\n")
   raw-out)
  (flush-output raw-out)
  (define-values (status headers) (read-http-header raw-in))
  (unless (regexp-match? #px"^HTTP/1\\.1 101" status)
    (error 'ws-connect "WebSocket upgrade refused: ~a" status))
  (define expected (b64 (sha1-bytes (string->bytes/utf-8 (string-append key ws-guid)))))
  (unless (equal? (hash-ref headers "sec-websocket-accept" #f) expected)
    (error 'ws-connect "invalid Sec-WebSocket-Accept from server"))
  (define proto (hash-ref headers "sec-websocket-protocol" #f))
  (unless (and proto (member rr-subprotocol (map string-trim (string-split proto ","))))
    (error 'ws-connect "server did not accept the Robot Raconteur WebSocket subprotocol"))
  (wrap-websocket raw-in raw-out))

(define (ws-connect host port path #:tls [tls #f] #:connect [connect tcp-connect])
  (define-values (raw-in raw-out)
    (if tls (ssl-connect host port tls) (connect host port)))
  ;; Host header: IPv6 literals in brackets without the zone; the scheme's
  ;; default port is omitted, as browsers do
  (define host-name
    (if (string-contains? host ":")
        (string-append "[" (car (string-split host "%")) "]")
        host))
  (define host-header
    (if (= port (if tls 443 80)) host-name (format "~a:~a" host-name port)))
  (with-handlers ([(lambda (e) #t)
                   (lambda (e) (close-input-port raw-in) (close-output-port raw-out) (raise e))])
    (ws-handshake raw-in raw-out host-header path)))

;; ---------------------------------------------------------------------------
;; Framing

(define op-cont 0) (define op-text 1) (define op-binary 2)
(define op-close 8) (define op-ping 9) (define op-pong 10)

;; Build one masked (client) frame.
(define (make-frame opcode payload)
  (define len (bytes-length payload))
  (define mask (random-bytes 4))
  (define masked
    (let ([b (bytes-copy payload)])
      (for ([i (in-range len)])
        (bytes-set! b i (bitwise-xor (bytes-ref b i) (bytes-ref mask (modulo i 4)))))
      b))
  (bytes-append
   (bytes (bitwise-ior #x80 opcode))
   (cond
     [(< len 126) (bytes (bitwise-ior #x80 len))]
     [(< len 65536) (bytes-append (bytes (bitwise-ior #x80 126)) (integer->integer-bytes len 2 #f #t))]
     [else (bytes-append (bytes (bitwise-ior #x80 127)) (integer->integer-bytes len 8 #f #t))])
   mask
   masked))

(define (read-exact n in)
  (define b (read-bytes n in))
  (if (or (eof-object? b) (< (bytes-length b) n)) eof b))

;; Returns (values opcode payload) or (values #f #f) on eof.
(define (read-frame in)
  (define h (read-exact 2 in))
  (cond
    [(eof-object? h) (values #f #f)]
    [else
     (define opcode (bitwise-and (bytes-ref h 0) #x0F))
     (define masked? (bitwise-bit-set? (bytes-ref h 1) 7))
     (define len0 (bitwise-and (bytes-ref h 1) #x7F))
     (define len
       (case len0
         [(126) (let ([b (read-exact 2 in)]) (if (eof-object? b) #f (integer-bytes->integer b #f #t)))]
         [(127) (let ([b (read-exact 8 in)]) (if (eof-object? b) #f (integer-bytes->integer b #f #t)))]
         [else len0]))
     (define mask (and len masked? (read-exact 4 in)))
     (define payload (and len (not (eof-object? mask)) (if (zero? len) #"" (read-exact len in))))
     (cond
       [(or (not payload) (eof-object? payload)) (values #f #f)]
       [else
        (when (bytes? mask)
          (for ([i (in-range len)])
            (bytes-set! payload i (bitwise-xor (bytes-ref payload i) (bytes-ref mask (modulo i 4))))))
        (values opcode payload)])]))

;; Wrap raw ports into stream ports carrying WebSocket binary frame payloads.
(define (wrap-websocket raw-in raw-out)
  (define write-lock (make-semaphore 1))
  (define closed? #f)
  (define (send-frame! opcode payload)
    (call-with-semaphore
     write-lock
     (lambda ()
       (unless closed?
         (write-bytes (make-frame opcode payload) raw-out)
         (flush-output raw-out)))))
  (define (close-raw!)
    (unless closed?
      (with-handlers ([exn:fail? void]) (send-frame! op-close (integer->integer-bytes 1000 2 #f #t)))
      (set! closed? #t)
      (with-handlers ([exn:fail? void]) (close-output-port raw-out))
      (with-handlers ([exn:fail? void]) (close-input-port raw-in))))

  ;; incoming: a reader thread decodes frames into a pipe
  (define-values (pipe-in pipe-out) (make-pipe))
  (thread
   (lambda ()
     (let loop ()
       (define-values (op payload)
         (with-handlers ([exn:fail? (lambda (e) (values #f #f))]) (read-frame raw-in)))
       (cond
         [(not op) (close-output-port pipe-out)]
         [(memv op (list op-cont op-text op-binary)) (write-bytes payload pipe-out) (loop)]
         [(= op op-ping)
          (with-handlers ([exn:fail? void]) (send-frame! op-pong payload))
          (loop)]
         [(= op op-pong) (loop)]
         [(= op op-close) (close-raw!) (close-output-port pipe-out)]
         [else (loop)]))))

  ;; outgoing: every write becomes one binary frame
  (define out
    (make-output-port
     'robotraconteur-websocket
     always-evt
     (lambda (bstr start end non-block? breakable?)
       (cond
         [(= start end) 0]
         [else (send-frame! op-binary (subbytes bstr start end)) (- end start)]))
     (lambda () (close-raw!))))

  (values pipe-in out))
