#lang racket/base
;; Find a node by "ID" on the network, then connect to a service on it.
;; Port of examples/features/discovery/python/find_node_by_id.py from the
;; Robot Raconteur core repository.
;;
;;   racket find-node-by-id.rkt node-id [service-name]
;;
;; The node ID is a 128-bit UUID that is expected to be unique, so it differs
;; for every instance of Reynard the Robot; find-node-by-name.rkt prints it.
;; It may be given with or without braces. The service defaults to "reynard".
;; Discovery uses IPv6 link-local multicast on the local network (Linux only).
(require robotraconteur racket/cmdline "discovery-util.rkt")

(define-values (node-id service-name)
  (command-line
   #:args (id [service "reynard"])
   (values id service)))

;; Send discovery requests and collect answers for 3 seconds
(define nodes (rr-find-node-by-id node-id #:timeout 3))

(for ([n nodes])
  (printf "NodeID: ~a\n" (rr-node-info-nodeid n))
  (printf "NodeName: ~a\n" (rr-node-info-nodename n))
  (printf "ConnectionURL: ~a\n" (rr-node-info-urls n)))

(when (null? nodes)
  (raise-user-error 'find-node-by-id "no node with ID ~a found" node-id))

;; Use the node's URLs to connect to a service on it
(define c (connect-node-service (car nodes) service-name))
(rr-call c "say" "Hello from find-node-by-id!")
(rr-close c)
