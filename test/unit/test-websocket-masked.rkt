#lang racket/base
;; RFC 6455 5.1: the server must not mask frames, and a client closes the
;; connection when it receives a masked frame.
(require rackunit racket/port racket/string file/sha1 net/base64
         "../../robotraconteur/websocket.rkt")

(define ws-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

;; Runs the client handshake against an in-memory server that answers the
;; upgrade and then sends `frames`. Returns the client's input port and the
;; server's output port (kept open, as a stalled server would).
(define (connect-with-frames frames)
  (define-values (c->s-in c->s-out) (make-pipe))
  (define-values (s->c-in s->c-out) (make-pipe))
  (thread
   (lambda ()
     (define key
       (let loop ()
         (define l (read-line c->s-in 'return-linefeed))
         (cond [(regexp-match #px"^Sec-WebSocket-Key: (.*)$" l) => cadr]
               [else (loop)])))
     (define accept
       (bytes->string/utf-8
        (base64-encode (sha1-bytes (string->bytes/utf-8 (string-append key ws-guid))) #"")))
     (write-string (string-append "HTTP/1.1 101 Switching Protocols\r\n"
                                  "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                  "Sec-WebSocket-Accept: " accept "\r\n"
                                  "Sec-WebSocket-Protocol: robotraconteur.robotraconteur.com\r\n\r\n")
                   s->c-out)
     (write-bytes frames s->c-out)
     (flush-output s->c-out)))
  (define-values (in out) (ws-handshake s->c-in c->s-out "localhost:1" "/"))
  (values in s->c-out))

;; a masked frame as a client would send it
(define (masked-frame opcode payload)
  (define mask (bytes 1 2 3 4))
  (bytes-append (bytes (bitwise-ior #x80 opcode) (bitwise-ior #x80 (bytes-length payload))) mask
                (apply bytes (for/list ([b (in-bytes payload)] [i (in-naturals)])
                               (bitwise-xor b (bytes-ref mask (modulo i 4)))))))

(test-case "a masked binary frame from the server closes the connection"
  (define-values (in server-out) (connect-with-frames (masked-frame 2 #"abc")))
  (check-equal? (sync/timeout 5 (read-bytes-evt 3 in)) eof))

(test-case "a masked frame after unmasked data closes the connection after the data"
  (define-values (in server-out)
    (connect-with-frames (bytes-append (bytes #x82 3) #"xyz" (masked-frame 2 #"abc"))))
  (check-equal? (read-bytes 3 in) #"xyz")
  (check-equal? (sync/timeout 5 (read-bytes-evt 3 in)) eof))

(test-case "unmasked frames are delivered"
  (define-values (in server-out) (connect-with-frames (bytes-append (bytes #x82 3) #"abc")))
  (check-equal? (read-bytes 3 in) #"abc"))
