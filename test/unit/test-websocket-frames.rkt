#lang racket/base
;; WebSocket frame lengths come from the server. A frame header must not make
;; the client allocate the claimed payload size before the data arrives, and
;; control frames longer than 125 bytes (RFC 6455 5.5) close the connection.
(require rackunit racket/port racket/string file/sha1 net/base64
         "wire-util.rkt" "../../robotraconteur/websocket.rkt")

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

;; frame header with a 64-bit length
(define (header64 opcode len)
  (bytes-append (bytes (bitwise-ior #x80 opcode) 127) (integer->integer-bytes len 8 #f #t)))

(define (check-peak-growth before what)
  (define after (vm-hwm-kb))
  (when (and before after)
    (check-true (< (- after before) (* 128 1024))
                (format "~a: peak memory grew by ~a MB" what (quotient (- after before) 1024)))))

(test-case "oversized ping frame closes the connection without allocating its length"
  (define before (vm-hwm-kb))
  (define-values (in server-out) (connect-with-frames (bytes-append (header64 9 #x40000000)
                                                                    (make-bytes 1000 0))))
  (check-equal? (sync/timeout 5 (read-bytes-evt 1 in)) eof)
  (check-peak-growth before "ping"))

(test-case "a binary frame claiming 1 GiB does not allocate before the data arrives"
  (define before (vm-hwm-kb))
  (define-values (in server-out) (connect-with-frames (bytes-append (header64 2 #x40000000)
                                                                    (make-bytes 1000 0))))
  ;; only 1000 of the claimed bytes arrive; nothing is delivered yet
  (check-false (sync/timeout 1 (read-bytes-evt 1 in)))
  (check-peak-growth before "binary"))

(test-case "ordinary binary frames are delivered"
  (define payload (make-bytes (* 100 1024) 5))
  (define-values (in server-out)
    (connect-with-frames (bytes-append (header64 2 (bytes-length payload)) payload
                                       (bytes #x82 3) #"abc")))
  (check-equal? (read-bytes (bytes-length payload) in) payload)
  (check-equal? (read-bytes 3 in) #"abc"))
