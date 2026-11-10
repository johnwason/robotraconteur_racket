#lang racket/base
;; Find a node by "name" on the network, then connect to a service on it.
;; Port of examples/features/discovery/python/find_node_by_name.py from the
;; Robot Raconteur core repository.
;;
;;   racket find-node-by-name.rkt [node-name [service-name]]
;;
;; Robot Raconteur nodes are identified by a "node name" or a "node ID". The
;; node name is human readable and may not be unique; the node ID is a 128-bit
;; UUID that is expected to be unique. Defaults to Reynard the Robot's node
;; and its "reynard" service. Discovery uses IPv6 link-local multicast on the
;; local network (Linux only).
(require robotraconteur racket/cmdline "discovery-util.rkt")

(define-values (node-name service-name)
  (command-line
   #:args ([name "experimental.reynard_the_robot"] [service "reynard"])
   (values name service)))

;; Send discovery requests and collect answers for 3 seconds
(define nodes (rr-find-node-by-name node-name #:timeout 3))

(for ([n nodes])
  (printf "NodeID: ~a\n" (rr-node-info-nodeid n))
  (printf "NodeName: ~a\n" (rr-node-info-nodename n))
  ;; Each URL reaches the node; there is one per network path to it
  (printf "ConnectionURL: ~a\n" (rr-node-info-urls n)))

(when (null? nodes)
  (raise-user-error 'find-node-by-name "no node named ~a found" node-name))

;; Use the node's URLs to connect to a service on it
(define c (connect-node-service (car nodes) service-name))
(rr-call c "say" "Hello from find-node-by-name!")
(rr-close c)
