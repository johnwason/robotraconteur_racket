#lang racket/base
;; TCP connect that copes with IPv6 link-local addresses without a zone.
;;
;; A link-local address (fe80::/10) is only meaningful together with an
;; interface (the zone, "fe80::1%eth0"). URLs from users, logs or other nodes
;; usually carry no zone, and the connect then fails (EINVAL on Linux). Like
;; the C++ core's TcpConnector (TcpTransport.cpp: "Link local address with no
;; scope id, we need to try them all"), rr-tcp-connect tries the address on
;; every local interface with a link-local address, all at once, and keeps
;; the first connection. Racing matters: on a wrong interface the SYN goes
;; unanswered and the attempt only fails when the TCP connect times out.
(require racket/tcp racket/list racket/string)

(provide rr-tcp-connect
         link-local-interfaces
         zoneless-link-local?)

;; Interfaces with an IPv6 link-local address, except loopback:
;; list of (cons ifindex name). Linux (/proc/net/if_inet6); '() elsewhere.
(define (link-local-interfaces)
  (define f "/proc/net/if_inet6")
  (if (file-exists? f)
      (remove-duplicates
       (for*/list ([line (in-list (call-with-input-file f (lambda (in) (for/list ([l (in-lines in)]) l))))]
                   [fs (in-value (string-split line))]
                   #:when (and (= (length fs) 6)
                               (string-prefix? (car fs) "fe80")
                               (not (equal? (list-ref fs 5) "lo"))))
         (cons (string->number (cadr fs) 16) (list-ref fs 5))))
      '()))

;; fe80::/10 without a "%zone"
(define (zoneless-link-local? host)
  (and (regexp-match? #px"^(?i:fe[89ab][0-9a-f]):" host)
       (not (string-contains? host "%"))))

;; Like tcp-connect, but a zoneless link-local host is tried on every
;; link-local interface in parallel. Returns (values in out).
(define (rr-tcp-connect host port)
  (cond
    [(not (zoneless-link-local? host)) (tcp-connect host port)]
    [else
     (define zones (map cdr (link-local-interfaces)))
     (when (null? zones)
       (raise (exn:fail:network
               (format "rr-tcp-connect: no interface with an IPv6 link-local address to reach ~a" host)
               (current-continuation-marks))))
     (race-connect host port zones)]))

(define (race-connect host port zones)
  (define results (make-channel))
  ;; each attempt runs under its own custodian so a losing attempt, possibly
  ;; still waiting for its SYN to be answered, can be shut down
  (define attempts
    (for/list ([z (in-list zones)])
      (define cust (make-custodian))
      (parameterize ([current-custodian cust])
        (thread
         (lambda ()
           (channel-put results
                        (with-handlers ([exn:fail? (lambda (e) (list 'fail z e))])
                          (define-values (in out) (tcp-connect (string-append host "%" z) port))
                          (list 'ok z in out cust))))))
      cust))
  (let loop ([pending (length zones)] [errors '()])
    (cond
      [(zero? pending)
       (raise (exn:fail:network
               (format "rr-tcp-connect: could not connect to ~a port ~a on any interface:~a"
                       host port
                       (apply string-append
                              (for/list ([e (in-list (reverse errors))])
                                (format "\n  %~a: ~a" (car e) (exn-message (cdr e))))))
               (current-continuation-marks)))]
      [else
       (define r (channel-get results))
       (case (car r)
         [(ok)
          (define winner (list-ref r 4))
          ;; closes the other attempts' sockets and ends their threads
          (for ([c (in-list attempts)] #:unless (eq? c winner)) (custodian-shutdown-all c))
          (values (list-ref r 2) (list-ref r 3))]
         [else (loop (sub1 pending) (cons (cons (cadr r) (caddr r)) errors))])])))
