#lang racket/base
;; Find a service on the network using discovery by type, then connect to it.
;; Port of examples/features/discovery/python/find_service_by_type.py from the
;; Robot Raconteur core repository.
;;
;;   racket find-service-by-type.rkt [service-type]
;;
;; A "service type" is the fully qualified type of the service's root object.
;; Reynard the Robot's root object is "Reynard" in service definition
;; "experimental.reynard_the_robot", so its type is
;; "experimental.reynard_the_robot.Reynard". Discovery uses IPv6 link-local
;; multicast on the local network (Linux only).
(require robotraconteur racket/cmdline)

;; Root object type to find
(define service-type
  (command-line #:args ([t "experimental.reynard_the_robot.Reynard"]) t))

;; Send discovery requests and collect answers for 3 seconds
(define found (rr-find-service-by-type service-type #:timeout 3))

(for ([s found])
  (printf "Name: ~a\n" (rr-service-info-name s))
  (printf "RootObjectType: ~a\n" (rr-service-info-root-object-type s))
  (printf "RootObjectImplements: ~a\n" (rr-service-info-implements s))
  (printf "ConnectionURL: ~a\n" (rr-service-info-urls s))
  (printf "Attributes: ~a\n" (rr-service-info-attributes s))
  (printf "NodeID: ~a\n" (rr-service-info-nodeid s))
  (printf "NodeName: ~a\n\n" (rr-service-info-nodename s)))

(when (null? found)
  (raise-user-error 'find-service-by-type "no ~a service found" service-type))

;; Use the URL to connect to the service
(define c (rr-connect (car (rr-service-info-urls (car found)))))
(rr-call c "say" "Hello from find-service-by-type!")
(rr-close c)
