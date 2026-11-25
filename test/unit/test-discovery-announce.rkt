#lang racket/base
;; Node announcements arrive from anyone on the LAN; like the C++ core
;; (Discovery::NodeAnnouncePacketReceived / NodeDetected), packets with an
;; invalid or all-zero NodeID are ignored, and only URLs naming the
;; announced NodeID are kept.
(require rackunit)
(require/expose (file "../../robotraconteur/discovery.rkt") (parse-announce))

(define id "{7d6f2e4c-1b2a-4c3d-9e8f-0a1b2c3d4e5f}")
(define (announce idline . urls)
  (apply string-append "Robot Raconteur Node Discovery Packet\n" idline "\n"
         (append (for/list ([u urls]) (string-append u "\n")) (list "ServiceStateNonce: abc\n"))))
(define (url nodeid)
  (string-append "rr+tcp://[fe80::1]:48653/?nodeid=" nodeid "&service=RobotRaconteurServiceIndex"))

(test-case "a valid announcement is parsed, with the zone added"
  (check-equal? (parse-announce (announce (string-append id ",mynode") (url id)) "eth0")
                (list id "mynode"
                      (list (string-append "rr+tcp://[fe80::1%25eth0]:48653/?nodeid=" id
                                           "&service=RobotRaconteurServiceIndex")))))

(test-case "the NodeID is normalized to lowercase with braces"
  (define r (parse-announce (announce "7D6F2E4C-1B2A-4C3D-9E8F-0A1B2C3D4E5F" (url id)) #f))
  (check-equal? (car r) id))

(test-case "an all-zero NodeID is ignored"
  (define zero "{00000000-0000-0000-0000-000000000000}")
  (check-false (parse-announce (announce zero (url zero)) #f)))

(test-case "an invalid NodeID is ignored"
  (check-false (parse-announce (announce "not-a-node-id,evil" (url "not-a-node-id")) #f)))

(test-case "URLs for a different node are dropped"
  (define other "{11111111-2222-3333-4444-555555555555}")
  (check-equal? (caddr (parse-announce (announce id (url other) (url id)) #f)) (list (url id)))
  (check-equal? (caddr (parse-announce (announce id "rr+tcp://[fe80::1]:48653/?service=x") #f)) '()))
