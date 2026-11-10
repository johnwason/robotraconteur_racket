#lang racket/base
;; Robot Raconteur node discovery (TCP transport, IPv6 link-local), client side.
;;
;; Protocol (IPNodeDiscovery in the C++ core's TcpTransport.cpp): nodes listen
;; on UDP port 48653 in the multicast group FF02::BA86 on each interface with
;; an IPv6 link-local address. A client sends
;;
;;   Robot Raconteur Discovery Request Packet\n{request uuid}\n
;;
;; to the group, and every node answers (and also announces periodically) with
;;
;;   Robot Raconteur Node Discovery Packet\n
;;   {nodeid}[,nodename]\n
;;   rr+tcp://[fe80::...]:port/?nodeid=...&service=RobotRaconteurServiceIndex\n
;;   ServiceStateNonce: ...\n
;;
;; The announced link-local address has no zone, so the zone is taken from the
;; interface the packet arrived on. Services are then listed by connecting to
;; the node's RobotRaconteurServiceIndex service and calling
;; GetLocalNodeServices().
;;
;; This is IPv6 only, like the core's default (IPv4 broadcast discovery is off
;; by default in RobotRaconteurNodeSetup). Racket's racket/udp can only join
;; IPv4 multicast groups, so the socket is driven through the C library via
;; the FFI, and waited on with unsafe-fd->evt so other Racket threads run.
;; Linux only (interfaces are read from /proc/net/if_inet6).

(require ffi/unsafe ffi/unsafe/define ffi/unsafe/port racket/list racket/string
         "client.rkt" "pack.rkt")

(provide (struct-out rr-node-info)
         (struct-out rr-service-info)
         rr-find-nodes
         rr-find-node-by-name
         rr-find-node-by-id
         rr-find-service-by-type)

;; nodeid: "{xxxxxxxx-...}" string; urls: list of connection URLs for the
;; node's RobotRaconteurServiceIndex, link-local ones with a %25zone
(struct rr-node-info (nodeid nodename urls) #:transparent)
;; urls: connection URLs for the service itself
(struct rr-service-info (name root-object-type implements attributes nodeid nodename urls)
  #:transparent)

;; --- libc

(define-ffi-definer define-c (ffi-lib #f))
(define-c socket (_fun #:save-errno 'posix _int _int _int -> _int))
(define-c setsockopt (_fun #:save-errno 'posix _int _int _int _bytes _uint32 -> _int))
(define-c bind (_fun #:save-errno 'posix _int _bytes _uint32 -> _int))
(define-c sendto (_fun #:save-errno 'posix _int _bytes _size _int _bytes _uint32 -> _ssize))
(define-c recvfrom (_fun #:save-errno 'posix _int _bytes _size _int _bytes (_ptr io _uint32) -> _ssize))
(define-c close (_fun _int -> _int))
(define-c if_indextoname (_fun _uint _bytes -> _pointer))

;; Linux values
(define AF_INET6 10)
(define SOCK_DGRAM 2)
(define SOL_SOCKET 1)
(define SO_REUSEADDR 2)
(define SO_REUSEPORT 15)
(define IPPROTO_IPV6 41)
(define IPV6_MULTICAST_IF 17)
(define IPV6_MULTICAST_LOOP 19)
(define IPV6_JOIN_GROUP 20)
(define MSG_DONTWAIT #x40)
(define EAGAIN 11)

(define discovery-port 48653)
(define group-ff02 (bytes-append #"\xff\x02" (make-bytes 12 0) #"\xba\x86"))

(define (int-bytes v) (integer->integer-bytes v 4 #t (system-big-endian?)))

(define (sockaddr-in6 addr port scope)
  (bytes-append (integer->integer-bytes AF_INET6 2 #f (system-big-endian?))
                (integer->integer-bytes port 2 #f #t)
                (make-bytes 4 0)
                addr
                (integer->integer-bytes scope 4 #f (system-big-endian?))))

(define (sockaddr-scope sa) (integer-bytes->integer sa #f (system-big-endian?) 24 28))

(define (check who r)
  (when (< r 0)
    (error 'rr-find-nodes "~a failed (errno ~a)" who (saved-errno)))
  r)

(define (index->name idx)
  (define buf (make-bytes 32 0))
  (and (if_indextoname idx buf)
       (bytes->string/utf-8 (car (regexp-split #rx#"\0" buf)))))

;; Interfaces with an IPv6 link-local address, except loopback (the core does
;; not announce on loopback): list of ifindex
(define (link-local-interfaces)
  (define f "/proc/net/if_inet6")
  (unless (file-exists? f)
    (error 'rr-find-nodes "discovery needs IPv6 and Linux (~a not found)" f))
  (remove-duplicates
   (for*/list ([line (in-list (call-with-input-file f (lambda (in) (for/list ([l (in-lines in)]) l))))]
               [fs (in-value (string-split line))]
               #:when (and (= (length fs) 6)
                           (string-prefix? (car fs) "fe80")
                           (not (equal? (list-ref fs 5) "lo"))))
     (string->number (cadr fs) 16))))

(define (random-uuid-string)
  (define b (for/list ([i 16]) (random 256)))
  (define hex (apply string-append (for/list ([x b]) (string-append (if (< x 16) "0" "") (number->string x 16)))))
  (format "{~a-~a-~a-~a-~a}" (substring hex 0 8) (substring hex 8 12) (substring hex 12 16)
          (substring hex 16 20) (substring hex 20 32)))

;; Add the interface zone to a link-local URL host: [fe80::1] -> [fe80::1%25eth0]
(define (add-zone url ifname)
  (if ifname
      (regexp-replace #px"^([^:]+://\\[)(fe80:[0-9a-fA-F:]*)(\\])" url
                      (string-append "\\1\\2%25" ifname "\\3"))
      url))

;; Parse a node announcement; #f if it isn't one.
;; Returns (list nodeid nodename urls)
(define (parse-announce text ifname)
  (define lines (string-split text "\n"))
  (cond
    [(and (pair? lines) (pair? (cdr lines))
          (equal? (car lines) "Robot Raconteur Node Discovery Packet"))
     (define id+name (string-split (cadr lines) "," #:trim? #f))
     (define urls (for/list ([l (in-list (cddr lines))] #:when (regexp-match? #rx"^[a-z+]+://" l))
                    (add-zone l ifname)))
     (list (string-downcase (car id+name))
           (if (pair? (cdr id+name)) (string-join (cdr id+name) ",") "")
           urls)]
    [else #f]))

;; Listen for timeout seconds, sending a discovery request on every link-local
;; interface at the start and about once a second (three times, as the core
;; does). Returns a list of rr-node-info.
(define (discover timeout)
  (define fd (check "socket" (socket AF_INET6 SOCK_DGRAM 0)))
  (define evt #f)
  (dynamic-wind
   void
   (lambda ()
     (setsockopt fd SOL_SOCKET SO_REUSEADDR (int-bytes 1) 4)
     (setsockopt fd SOL_SOCKET SO_REUSEPORT (int-bytes 1) 4)
     (check "bind to UDP port 48653"
            (bind fd (sockaddr-in6 (make-bytes 16 0) discovery-port 0) 28))
     (setsockopt fd IPPROTO_IPV6 IPV6_MULTICAST_LOOP (int-bytes 1) 4)
     (define ifaces
       (for/list ([idx (in-list (link-local-interfaces))]
                  #:when (zero? (setsockopt fd IPPROTO_IPV6 IPV6_JOIN_GROUP
                                            (bytes-append group-ff02 (int-bytes idx)) 20)))
         idx))
     (set! evt (unsafe-fd->evt fd 'read))
     (define request
       (string->bytes/utf-8
        (string-append "Robot Raconteur Discovery Request Packet\n" (random-uuid-string) "\n")))
     (define (send-requests!)
       (for ([idx (in-list ifaces)])
         (setsockopt fd IPPROTO_IPV6 IPV6_MULTICAST_IF (int-bytes idx) 4)
         (sendto fd request (bytes-length request) 0
                 (sockaddr-in6 group-ff02 discovery-port idx) 28)))
     (define nodes (make-hash)) ; nodeid -> (mcons nodename urls)
     (define order '())
     (define buf (make-bytes 4096))
     (define src (make-bytes 28 0))
     (define (drain!)
       (let loop ()
         (define n (recvfrom fd buf (bytes-length buf) MSG_DONTWAIT src 28))
         (when (> n 0)
           (define ann (parse-announce (bytes->string/utf-8 (subbytes buf 0 n) #\?)
                                       (index->name (sockaddr-scope src))))
           (when ann
             (define id (car ann))
             (unless (hash-has-key? nodes id) (set! order (cons id order)))
             (define old (hash-ref nodes id (lambda () (cons (cadr ann) '()))))
             (hash-set! nodes id
                        (cons (if (equal? (car old) "") (cadr ann) (car old))
                              (remove-duplicates (append (cdr old) (caddr ann))))))
           (loop))))
     (define start (current-inexact-milliseconds))
     (define deadline (+ start (* 1000 timeout)))
     (let loop ([next-send start] [sends-left 3])
       (define now (current-inexact-milliseconds))
       (cond
         [(>= now deadline) (void)]
         [(and (> sends-left 0) (>= now next-send))
          (send-requests!)
          (loop (+ now 1000) (sub1 sends-left))]
         [else
          (define wake (if (> sends-left 0) (min next-send deadline) deadline))
          (when (sync/timeout (max 0 (/ (- wake now) 1000.0)) evt)
            (drain!))
          (loop next-send sends-left)]))
     (for/list ([id (in-list (reverse order))])
       (define v (hash-ref nodes id))
       (rr-node-info id (car v) (cdr v))))
   (lambda ()
     (when evt (unsafe-fd->evt fd 'remove))
     (close fd))))

;; --- public API

(define (rr-find-nodes #:timeout [timeout 3])
  (discover timeout))

(define (rr-find-node-by-name name #:timeout [timeout 3])
  (filter (lambda (n) (equal? (rr-node-info-nodename n) name)) (discover timeout)))

(define (rr-find-node-by-id id #:timeout [timeout 3])
  (define want (string-downcase (if (string-prefix? id "{") id (string-append "{" id "}"))))
  (filter (lambda (n) (equal? (rr-node-info-nodeid n) want)) (discover timeout)))

(define (url-scheme-of u) (car (string-split u ":")))

(define (map-values h)
  (if (hash? h) (for/list ([k (in-list (sort (hash-keys h) <))]) (hash-ref h k)) '()))

;; Services whose root object type is `type` or implements it, on every node
;; found within `timeout` seconds. Each node's service index is reached over
;; the first URL with a scheme in `transports` that connects.
(define (rr-find-service-by-type type #:timeout [timeout 3]
                                 #:transports [transports '("rr+tcp" "rrs+tcp")])
  (append*
   (for/list ([n (in-list (discover timeout))])
     (define urls (for*/list ([t (in-list transports)]
                              [u (in-list (rr-node-info-urls n))]
                              #:when (equal? (url-scheme-of u) t))
                    u))
     (define-values (url services)
       (let loop ([us urls])
         (cond
           [(null? us) (values #f '())]
           [else
            (define r
              (with-handlers ([exn:fail? (lambda (e) #f)])
                (define c (rr-connect (car us)))
                (dynamic-wind void
                              (lambda () (rr-call c "GetLocalNodeServices"))
                              (lambda () (rr-close c)))))
            (if r (values (car us) (map-values r)) (loop (cdr us)))])))
     (for*/list ([s (in-list services)]
                 [implements (in-value (map-values (rr-struct-ref s "RootObjectImplements")))]
                 #:when (or (equal? (rr-struct-ref s "RootObjectType") type)
                            (member type implements)))
       (define name (rr-struct-ref s "Name"))
       (rr-service-info name (rr-struct-ref s "RootObjectType") implements
                        (let ([a (rr-struct-ref s "Attributes")]) (if (hash? a) a (hash)))
                        (rr-node-info-nodeid n) (rr-node-info-nodename n)
                        (list (regexp-replace #rx"service=RobotRaconteurServiceIndex" url
                                              (string-append "service=" name))))))))
