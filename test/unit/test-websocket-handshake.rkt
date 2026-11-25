#lang racket/base
;; The server's HTTP upgrade response is untrusted: an endless header line or
;; endless header lines must fail the handshake instead of buffering forever.
(require rackunit racket/string "../../robotraconteur/websocket.rkt")

;; Runs ws-handshake against an in-memory server that sends `response` and
;; keeps the connection open. Returns the handshake's exception, 'ok, or
;; 'timeout if it is still running after 10 s.
(define (handshake-result response)
  (define-values (c->s-in c->s-out) (make-pipe))
  (define-values (s->c-in s->c-out) (make-pipe))
  (thread (lambda ()
            (write-bytes response s->c-out)
            (flush-output s->c-out)))
  (define ch (make-channel))
  (define th (thread (lambda ()
                       (channel-put ch (with-handlers ([exn:fail? values])
                                         (ws-handshake s->c-in c->s-out "localhost:1" "/")
                                         'ok)))))
  (begin0 (or (sync/timeout 10 ch) 'timeout)
          (kill-thread th)))

(define (check-fails-with response rx)
  (define r (handshake-result response))
  (check-true (exn:fail? r) (format "handshake result: ~a" r))
  (when (exn:fail? r) (check-regexp-match rx (exn-message r))))

(test-case "an endless header line fails the handshake"
  (check-fails-with (bytes-append #"HTTP/1.1 101 Switching Protocols\r\nX-Long: "
                                  (make-bytes (* 1024 1024) 65))
                    #rx"too long"))

(test-case "an endless status line fails the handshake"
  (check-fails-with (make-bytes (* 1024 1024) 65) #rx"too long"))

(test-case "endless header lines fail the handshake"
  (check-fails-with (apply bytes-append #"HTTP/1.1 101 Switching Protocols\r\n"
                           (for/list ([i 10000]) #"X-Filler: a\r\n"))
                    #rx"too many"))

(test-case "a refused upgrade is still reported"
  (check-fails-with #"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" #rx"refused"))
