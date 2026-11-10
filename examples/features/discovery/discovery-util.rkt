#lang racket/base
;; Shared helper for the discovery examples.
(require robotraconteur)

(provide connect-node-service)

;; Connects to service `service-name` on a node found by discovery. A node's
;; URLs point at its service index ("service=RobotRaconteurServiceIndex"), one
;; per network path to the node; each is tried in turn with the service name
;; swapped in, like passing the list of URLs to ConnectService in Python.
(define (connect-node-service node service-name)
  (let loop ([urls (rr-node-info-urls node)] [last-error #f])
    (cond
      [(null? urls)
       (if last-error
           (raise last-error)
           (raise-user-error 'connect-node-service "node has no connection URLs"))]
      [else
       (define url (regexp-replace #rx"service=[^&]*" (car urls)
                                   (string-append "service=" service-name)))
       (with-handlers ([exn:fail? (lambda (e) (loop (cdr urls) e))])
         (rr-connect url))])))
