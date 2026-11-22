#lang racket/base
;; Announced URLs are checked against the packet's sender as the C++ core does
;; (IPNodeDiscovery::NodeAnnounceReceived): a LAN host must not be able to
;; announce loopback URLs or addresses outside its own link/subnet.
(require rackunit racket/list)
(require/expose "../../robotraconteur/discovery.rkt"
                (check-announce-sender sockaddr-address sockaddr-in6))

(define (v6 . groups)
  (apply bytes-append (for/list ([g groups]) (integer->integer-bytes g 2 #f #t))))
(define (sender-v6 . groups) (sockaddr-address (sockaddr-in6 (apply v6 groups) 48653 2)))
(define (sender-v4 a b c d)
  (sockaddr-address (sockaddr-in6 (bytes-append (make-bytes 10 0) #"\xff\xff" (bytes a b c d)) 48653 0)))

(define link-sender (sender-v6 #xfe80 0 0 0 0 0 0 #x1234))
(define loop-sender (sender-v6 0 0 0 0 0 0 0 1))
(define id "{11111111-2222-3333-4444-555555555555}")

(define (url host) (string-append "rr+tcp://" host ":48653/?nodeid=11111111-2222-3333-4444-555555555555&service=RobotRaconteurServiceIndex"))
(define (kept urls sender)
  (define r (check-announce-sender (list id "node" urls) sender))
  (if r (third r) '()))

(test-case "link-local URLs from a link-local sender are kept (also with a zone)"
  (check-equal? (kept (list (url "[fe80::1234]")) link-sender) (list (url "[fe80::1234]")))
  (check-equal? (kept (list (url "[fe80::1234%25eth0]")) link-sender) (list (url "[fe80::1234%25eth0]")))
  (check-equal? (kept (list (url "[fec0::5]")) link-sender) (list (url "[fec0::5]"))))

(test-case "loopback URLs are only accepted from a loopback sender"
  (check-equal? (kept (list (url "127.0.0.1") (url "[::1]")) link-sender) '())
  (check-equal? (kept (list (url "[::1]")) loop-sender) (list (url "[::1]")))
  (check-equal? (kept (list (url "127.0.0.1")) (sender-v4 127 0 0 1)) (list (url "127.0.0.1"))))

(test-case "global IPv6, host names and other families are dropped"
  (check-equal? (kept (list (url "[2001:db8::1]")) link-sender) '())
  (check-equal? (kept (list (url "example.com")) link-sender) '())
  (check-equal? (kept (list (url "192.168.1.5")) link-sender) '()))

(test-case "IPv4 URLs must be in the sender's /16"
  (check-equal? (kept (list (url "192.168.7.9")) (sender-v4 192 168 1 5)) (list (url "192.168.7.9")))
  (check-equal? (kept (list (url "10.0.0.1")) (sender-v4 192 168 1 5)) '()))

(test-case "an announcement with no acceptable URL is dropped, others are filtered"
  (check-false (check-announce-sender (list id "node" (list (url "127.0.0.1"))) link-sender))
  (check-equal? (check-announce-sender (list id "node" (list (url "127.0.0.1") (url "[fe80::1234]"))) link-sender)
                (list id "node" (list (url "[fe80::1234]"))))
  (check-false (check-announce-sender #f link-sender)))
