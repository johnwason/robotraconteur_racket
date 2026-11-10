#lang racket/base
;; Port of robotraconteur/test/python/RobotRaconteurTest/ServiceTestClient2.py
;; Service: RobotRaconteurTestService2 (com.robotraconteur.testing.TestService3.testroot3)
;;
;; Not ported: TestMemories, TestNamedArrayMemories, TestComplexMemories,
;; TestBoolMemories and the memory checks in TestNoLock (memories are out of
;; scope); AsyncTestWirePeekPoke (Python callback-style async API);
;; NamedArrayToArray/ArrayToNamedArray (numpy helpers, not protocol features).
(require rackunit racket/list
         robotraconteur robotraconteur/message
         "test-server.rkt" "util.rkt" "servicetest2-util.rkt")

(define (with-client f)
  (define r (rr-connect (test-server-url "RobotRaconteurTestService2")))
  (dynamic-wind void (lambda () (f r)) (lambda () (rr-close r))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestWirePeekPoke

(test-case "wire peek poke"
  (with-client
   (lambda (r)
     (define-values (v ts) (rr-wire-peek-in r "peekwire"))
     (check-equal? v 56295674)
     (rr-wire-poke-out! r "pokewire" 75738265)
     (define-values (v2 ts2) (rr-wire-peek-out r "pokewire"))
     (check-equal? v2 75738265)
     (define w (rr-wire-connect r "pokewire"))
     (for ([i 3]) (rr-wire-set-out-value! w 8638356))
     (sleep 0.1)
     (define-values (v3 ts3) (rr-wire-peek-out r "pokewire"))
     (check-equal? v3 8638356)
     (rr-wire-close w))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestEnums

(test-case "enums"
  (with-client
   (lambda (r)
     (define testenum1 (rr-enum-values r (string-append ts3 "testenum1")))
     (check-equal? (rr-get r "testenum1_prop") (cdr (assoc "anothervalue" testenum1)))
     (rr-set! r "testenum1_prop" (cdr (assoc "hexval1" testenum1)))
     ;; a symbol naming the value is also accepted
     (rr-set! r "testenum1_prop" 'hexval1))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestPods

;; Pack a value as a message element, serialize it inside a full Message V2,
;; parse it back and unpack it (PackMessageElement/UnpackMessageElement plus
;; the binary round trip).
(define (wire-roundtrip r type v)
  (define e (rr-pack-element r type v))
  (define m (message (make-bytes 16 0) (make-bytes 16 0) 0 0 "" "" "" 0 0
                     (list (entry 'PropertyGetRes "" "" 0 0 "" (list e)))))
  (define m2 (bytes->message (message->bytes m)))
  (rr-unpack-element r type (car (entry-elements (car (message-entries m2))))))

(test-case "pods"
  (with-client
   (lambda (r)
     (define s1 (fill-testpod1 r 563921043))
     (verify-testpod1 s1 563921043)
     (verify-testpod1 (wire-roundtrip r (string-append ts3 "testpod1") s1) 563921043)

     (define s3 (fill-teststruct3 r 858362))
     (verify-teststruct3 (wire-roundtrip r (string-append ts3 "teststruct3") s3) 858362)

     (verify-testpod1 (rr-get r "testpod1_prop") 563921043)
     (rr-set! r "testpod1_prop" (fill-testpod1 r 85932659))
     (verify-testpod1 (rr-call r "testpod1_func2") 95836295)
     (rr-call r "testpod1_func1" (fill-testpod1 r 29546592))
     (rr-set! r "teststruct3_prop" (fill-teststruct3 r 858362)))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestGenerators

(test-case "generators"
  (with-client
   (lambda (r)
     (define expected (for/list ([i 16]) (exact->inexact i)))
     (check-equal? (rr-generator->list (rr-call r "gen_func1")) expected)
     (check-equal? (rr-generator->list (rr-call r "gen_func1")) expected)

     ;; next with a parameter, then abort
     (define g (rr-call r "gen_func4"))
     (for ([i 3]) (rr-generator-next g (vector)))
     (check-pred vector? (rr-generator-next g (vector 2 3 4)))
     (rr-generator-abort g)
     (check-rr-error 'OperationAborted (lambda () (rr-generator-next g (vector))))

     ;; close: the generator is finished
     (define g2 (rr-call r "gen_func4"))
     (rr-generator-next g2 (vector 2 3 4))
     (rr-generator-close g2)
     (check-pred eof-object? (rr-generator-next g2 (vector)))

     (check-equal? (rr-generator->list (rr-call r "gen_func2" "gen_func2_a_param"))
                   (for/list ([i 16]) (vector i)))

     ;; TryNext: rr-generator-next returns eof instead of raising StopIteration
     (define g3 (rr-call r "gen_func4"))
     (for ([i 3]) (check-false (eof-object? (rr-generator-next g3 (vector)))))
     (check-false (eof-object? (rr-generator-next g3 (vector 2 3 4))))
     (rr-generator-abort g3)
     (check-rr-error 'OperationAborted (lambda () (rr-generator-next g3 (vector))))

     (define g4 (rr-call r "gen_func4"))
     (check-false (eof-object? (rr-generator-next g4 (vector 2 3 4))))
     (rr-generator-close g4)
     (check-pred eof-object? (rr-generator-next g4 (vector))))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestNamedArrays

(test-case "named arrays"
  (with-client
   (lambda (r)
     (rr-set! r "testnamedarray1" (rr-struct-ref (fill-transform r 3956378) "translation"))
     (define a1-2 (fill-transform r 74637))
     (rr-struct-set! a1-2 "translation" (rr-get r "testnamedarray1"))
     (verify-transform a1-2 74637)

     (rr-set! r "testnamedarray2" (fill-transform r 827635))
     (verify-transform (rr-get r "testnamedarray2") 1294)

     (rr-set! r "testnamedarray3" (create-transform-array r 6 19274))
     (verify-transform-array (rr-get r "testnamedarray3") 8 837512)

     (rr-set! r "testnamedarray4" (create-transform-multidimarray r 5 2 6385))
     (verify-transform-multidimarray (rr-get r "testnamedarray4") 7 2 66134)

     (rr-set! r "testnamedarray5" (create-transform-multidimarray r 3 2 7732))
     (verify-transform-multidimarray (rr-get r "testnamedarray5") 3 2 773142))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestComplex

;; numpy .view(complex): consecutive (real, imag) pairs
(define (->complex v)
  (for/vector ([i (in-range 0 (vector-length v) 2)])
    (make-rectangular (vector-ref v i) (vector-ref v (add1 i)))))

(define (tv-complex name type) (->complex (tv name type)))
(define (tv-complex-md name type)
  (rr-multidim (vector->list (tv (string-append name ".dims") 'uint32)) (tv-complex name type)))

(test-case "complex"
  (with-client
   (lambda (r)
     (check-equal? (rr-get r "c1") (make-rectangular 5.708705e+01 -2.328294e-03))
     (rr-set! r "c1" (make-rectangular 5.708705e+01 -2.328294e-03))

     (check-allclose (rr-get r "c2") (tv-complex "ts3.c2.to_client" 'double))
     (rr-set! r "c2" (tv-complex "ts3.c2.to_service" 'double))

     (check-allclose (rr-get r "c3") (tv-complex-md "ts3.c3.to_client" 'double))
     (rr-set! r "c3" (tv-complex-md "ts3.c3.to_service" 'double))

     (check-allclose (first (rr-get r "c5")) (tv-complex "ts3.c5.to_client" 'double))
     (rr-set! r "c5" (list (tv-complex "ts3.c5.to_service" 'double)))

     (check-allclose (rr-get r "c7") (make-rectangular -5.527021e-18 -9.848457e+03))
     (rr-set! r "c7" (make-rectangular 9.303345e-12 -3.865684e-05))

     (check-allclose (rr-get r "c8") (tv-complex "ts3.c8.to_client" 'single))
     (rr-set! r "c8" (tv-complex "ts3.c8.to_service" 'single))

     (check-allclose (rr-get r "c9") (tv-complex-md "ts3.c9.to_client" 'single))
     (rr-set! r "c9" (tv-complex-md "ts3.c9.to_service" 'single)))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestNoLock (the service holds an object lock on nolock_test;
;; members marked nolock / nolockread stay usable)

(test-case "nolock"
  (with-client
   (lambda (r)
     (define o5 (rr-objref r "nolock_test"))
     (check-rr-error 'ObjectLockedError (lambda () (rr-get o5 "p1")))
     (rr-get o5 "p2")
     (rr-set! o5 "p2" 0)
     (rr-get o5 "p3")
     (check-rr-error 'ObjectLockedError (lambda () (rr-set! o5 "p3" 0)))
     (check-rr-error 'ObjectLockedError (lambda () (rr-call o5 "f1")))
     (rr-call o5 "f2")
     (check-rr-error 'ObjectLockedError (lambda () (rr-pipe-close (rr-pipe-connect o5 "q1" -1))))
     (rr-pipe-close (rr-pipe-connect o5 "q2" -1))
     (check-rr-error 'ObjectLockedError (lambda () (rr-wire-close (rr-wire-connect o5 "w1"))))
     (rr-wire-close (rr-wire-connect o5 "w2")))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestBools

(define (md dims v) (rr-multidim dims v))

(test-case "bools"
  (with-client
   (lambda (r)
     (rr-set! r "b1" #t)
     (check-true (rr-get r "b1"))
     (rr-set! r "b2" (vector #t #f #f #t #t #t #f #t))
     (check-equal? (rr-get r "b2") (vector #t #f #t #t #f #t #f))
     (rr-set! r "b3" (md '(2 1) (vector #t #f)))
     (check-equal? (rr-get r "b3") (md '(2 2) (vector #f #t #t #f)))
     (rr-set! r "b4" (list #t))
     (check-true (first (rr-get r "b4")))
     (rr-set! r "b5" (list (vector #t #f)))
     (check-equal? (first (rr-get r "b5")) (vector #f #t #f #f))
     (rr-set! r "b6" (list (md '(2 1) (vector #t #f))))
     (check-equal? (first (rr-get r "b6")) (md '(2 2) (vector #f #t #t #f))))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient2.TestExceptionParams

(define (call-error r f)
  (with-handlers ([exn:fail:robotraconteur? values]) (rr-call r f) #f))

(test-case "exception params"
  (with-client
   (lambda (r)
     (define e1 (call-error r "test_exception_params1"))
     (check-pred exn:fail:robotraconteur? e1)
     (check-equal? (exn:fail:robotraconteur-error-name e1) "RobotRaconteur.InvalidOperation")
     (check-equal? (exn:fail:robotraconteur-error-message e1) "test error")
     (check-equal? (exn:fail:robotraconteur-error-subname e1) "my_error")
     (define p1 (exn:fail:robotraconteur-error-param e1))
     (check-equal? (hash-count p1) 2)
     (check-equal? (vector-ref (hash-ref p1 "param1") 0) 10)
     (check-equal? (hash-ref p1 "param2") "20")

     (define e2 (call-error r "test_exception_params2"))
     (check-pred exn:fail:robotraconteur? e2)
     (check-equal? (exn:fail:robotraconteur-error-name e2) (string-append ts3 "test_exception4"))
     (check-equal? (exn:fail:robotraconteur-error-message e2) "test error2")
     (check-equal? (exn:fail:robotraconteur-error-subname e2) "my_error2")
     (define p2 (exn:fail:robotraconteur-error-param e2))
     (check-equal? (hash-count p2) 2)
     (check-equal? (vector-ref (hash-ref p2 "param1") 0) 30)
     (check-equal? (hash-ref p2 "param2") "40"))))
