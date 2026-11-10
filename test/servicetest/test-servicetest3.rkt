#lang racket/base
;; Port of robotraconteur/test/python/RobotRaconteurTest/ServiceTestClient3.py
;; Service: RobotRaconteurTestService3 (com.robotraconteur.testing.TestService5)
(require rackunit
         "../../robotraconteur/main.rkt" "test-server.rkt" "util.rkt")

(define (with-client f)
  (define r (rr-connect (test-server-url "RobotRaconteurTestService3")))
  (dynamic-wind void (lambda () (f r)) (lambda () (rr-close r))))

;; ServiceTestClient3.TestProperties
(test-case "properties3"
  (with-client
   (lambda (r)
     (check-equal? (rr-get r "d1") 8.5515)
     (rr-set! r "d1" 3.0819)
     (define e (with-handlers ([exn:fail:robotraconteur? values]) (rr-get r "err") #f))
     (check-pred exn:fail:robotraconteur? e)
     (check-eq? (rr-error-type e) 'InvalidArgument)
     (check-equal? (exn:fail:robotraconteur-error-message e) "Test message 1")
     (check-rr-error 'InvalidOperation (lambda () (rr-set! r "err" 100.0))))))

;; ServiceTestClient3.TestFunctions
(test-case "functions3"
  (with-client
   (lambda (r)
     (rr-call r "f1")
     (rr-call r "f2" 247)
     (check-equal? (rr-call r "f3" 1.0 2.0) 3)
     (check-rr-error 'InvalidOperation (lambda () (rr-call r "err_func")))
     ;; service-defined exception type
     (check-rr-error "com.robotraconteur.testing.TestService5.asynctestexp"
                     (lambda () (rr-call r "err_func2"))))))
