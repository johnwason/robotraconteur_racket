#lang racket/base
;; Port of robotraconteur/test/python/RobotRaconteurTest/ServiceTestClient.py
;; Services: RobotRaconteurTestService and RobotRaconteurTestService_auth
;;           (com.robotraconteur.testing.TestService1.testroot)
;;
;; Not ported: TestMemories (memories are out of scope) and TestAsync (it
;; exercises Python's callback-style async API; the same operations are
;; covered synchronously here).
(require rackunit racket/list racket/async-channel
         robotraconteur "test-server.rkt" "util.rkt")

(define ts1 "com.robotraconteur.testing.TestService1.")

(define (url) (test-server-url "RobotRaconteurTestService"))
(define (auth-url) (test-server-url "RobotRaconteurTestService_auth"))

(define (with-client f)
  (define r (rr-connect (url)))
  (dynamic-wind void (lambda () (f r)) (lambda () (rr-close r))))

(define (teststruct2 r mydat)
  (define s (rr-new-structure r (string-append ts1 "teststruct2")))
  (rr-struct-set! s "mydat" mydat)
  s)

(define (mydat s) (rr-struct-ref s "mydat"))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.ConnectService: attributes are readable

(test-case "connect and attributes"
  (with-client
   (lambda (r)
     (define attrs (rr-attributes r))
     (check-equal? (hash-ref attrs "test") "This is a test attribute")
     ;; varvalue numbers always arrive as arrays (a scalar is an array of one)
     (check-equal? (hash-ref attrs "test2") (vector 42)))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestProperties

(define (test-numeric-properties r)
  (rr-set! r "d1" 3.456)
  (check-equal? (rr-get r "d1") 12.345)
  (for ([p '("d2" "d3" "d4")])
    (rr-set! r p (tv (format "ts1.~a.to_service" p) 'double))
    (check-allclose (rr-get r p) (tv (format "ts1.~a.to_client" p) 'double)))
  (for ([p '("d5" "d6")])
    (rr-set! r p (tv-md (format "ts1.~a.to_service" p) 'double))
    (check-allclose (rr-get r p) (tv-md (format "ts1.~a.to_client" p) 'double)))

  (rr-set! r "s1" 3847.9283)
  (check-allclose (rr-get r "s1") 7.8573)
  (rr-set! r "s2" (tv "ts1.s2.to_service" 'single))

  (rr-set! r "i8_1" 45)
  (check-equal? (rr-get r "i8_1") -66)
  (rr-set! r "i8_2" (tv "ts1.i8_2.to_service" 'int8))
  (check-array-equal (rr-get r "i8_2") (tv "ts1.i8_2.to_client" 'int8))
  (rr-set! r "u8_1" 232)
  (check-equal? (rr-get r "u8_1") 222)
  (rr-set! r "u8_2" (tv "ts1.u8_2.to_service" 'uint8))
  (check-array-equal (rr-get r "u8_2") (tv "ts1.u8_2.to_client" 'uint8))
  (rr-set! r "u8_3" (tv-md "ts1.u8_3.to_service" 'uint8))
  (check-array-equal (rr-get r "u8_3") (tv-md "ts1.u8_3.to_client" 'uint8))

  (for ([p '("i16" "u16" "i32" "u32" "i64" "u64")]
        [type '(int16 uint16 int32 uint32 int64 uint64)]
        [to-service '(2387 54732 -9837284 1550099195 8621740821050813024 1465640522145789825)]
        [to-client '(-13428 60981 898734 547919123 -1357833931563696072 13389861970863644378)])
    (rr-set! r (string-append p "_1") to-service)
    (check-equal? (rr-get r (string-append p "_1")) to-client)
    (rr-set! r (string-append p "_2") (tv (format "ts1.~a_2.to_service" p) type))
    (check-array-equal (rr-get r (string-append p "_2")) (tv (format "ts1.~a_2.to_client" p) type)))

  (rr-set! r "str1" "Hello Server!")
  (check-equal? (rr-get r "str1") "Hello Client!"))

(define (test-struct-properties r)
  (define s1 (rr-get r "struct1"))
  (check-allclose (rr-struct-ref s1 "dat1") (tv "ts1.struct1.dat1.to_client" 'double))
  (check-equal? (rr-struct-ref s1 "str2") "Hello world!")
  (check-equal? (rr-struct-ref s1 "vec3")
                (hash 1 "Hello Client!" 2 "Hello Client, again" 4372 "This is yet another test string"))
  (check-equal? (rr-struct-ref s1 "dict4")
                (hash "teststring1" "Hello Client!" "teststring2" "Hello Client, again"
                      "anotherstr" "This is yet another test string"))
  (check-allclose (mydat (rr-struct-ref s1 "struct1")) (tv "ts1.struct1.struct1_mydat.to_client" 'double))
  (define ds2 (rr-struct-ref s1 "dstruct2"))
  (check-equal? (hash-count ds2) 2)
  (check-allclose (mydat (hash-ref ds2 "test1")) (tv "ts1.struct1.dstruct2_1.to_client" 'double))
  (check-allclose (mydat (hash-ref ds2 "anothertest")) (tv "ts1.struct1.dstruct2_3.to_client" 'double))
  (check-allclose (rr-struct-ref s1 "multidimarray") (tv-md "ts1.struct1.multidimarray.to_client" 'double))
  (check-equal? (rr-struct-ref s1 "var3") "This is a vartype string")

  (define s2 (rr-new-structure r (string-append ts1 "teststruct1")))
  (rr-struct-set! s2 "dat1" (tv "ts1.struct1.dat1.to_service" 'double))
  (rr-struct-set! s2 "str2" "Hello world 2!")
  (rr-struct-set! s2 "vec3" (hash 10 "Hello Server!" 11 "Hello Server, again"
                                  46372 "Test string!" 46373 "Test string again"))
  (rr-struct-set! s2 "dict4" (hash "cteststring1" "Hello Server!" "cteststring2" "Hello Server, again"))
  (rr-struct-set! s2 "list5" (list "Hello Server!" "Hello Server, again"))
  (rr-struct-set! s2 "struct1" (teststruct2 r (tv "ts1.struct1.struct1_mydat.to_service" 'double)))
  (rr-struct-set! s2 "dstruct2"
                  (hash "ctest1" (teststruct2 r (tv "ts1.struct1.dstruct2_1.to_service" 'double))
                        "anothertest" (teststruct2 r (tv "ts1.struct1.dstruct2_2.to_service" 'double))))
  (rr-struct-set! s2 "lstruct3"
                  (list (teststruct2 r (tv "ts1.struct1.dstruct2_1.to_service" 'double))
                        (teststruct2 r (tv "ts1.struct1.dstruct2_2.to_service" 'double))))
  (rr-struct-set! s2 "multidimarray" (tv-md "ts1.struct1.multidimarray.to_service" 'double))
  (rr-struct-set! s2 "var3" (rr-varvalue (tv "ts1.struct1.var3.to_service" 'double) "double[]"))
  (rr-set! r "struct1" s2)

  (rr-set! r "struct2" (teststruct2 r (tv "ts1.struct2.to_service" 'double)))
  (check-allclose (mydat (rr-get r "struct2")) (tv "ts1.struct2.to_client" 'double)))

(define (test-indexed-and-list-properties r)
  (check-equal? (rr-get r "is_d1") (hash 9285 1.643392e-01 74822 1.537133e+09 4 1.369505e-03))
  (rr-set! r "is_d1" (hash 928 4.074501e-07 394820 -4.535303e+05 623 -2.956241e-20))
  (check-equal? (rr-get r "is_d2") (hash "testval1" -1.079664e+16 "testval2" 2.224846e+00))
  (rr-set! r "is_d2" (hash "testval3" 5.242474e+10 "testval4" 2.208636e+08))

  (define is-d3 (rr-get r "is_d3"))
  (check-equal? (hash-count is-d3) 2)
  (check-allclose (hash-ref is-d3 12) (tv "ts1.is_d3.to_client.a" 'double))
  (check-allclose (hash-ref is-d3 832) (tv "ts1.is_d3.to_client.b" 'double))
  (rr-set! r "is_d3" (hash 47 (tv "ts1.is_d3.to_service.a" 'double)
                           324 (tv "ts1.is_d3.to_service.b" 'double)))
  (define is-d4 (rr-get r "is_d4"))
  (check-equal? (hash-count is-d4) 2)
  (check-allclose (hash-ref is-d4 "testval1") (tv "ts1.is_d4.to_client.a" 'double))
  (check-allclose (hash-ref is-d4 "testval2") (tv "ts1.is_d4.to_client.b" 'double))
  (rr-set! r "is_d4" (hash "testval3" (tv "ts1.is_d4.to_service.a" 'double)
                           "testval4" (tv "ts1.is_d4.to_service.b" 'double)))

  (define is-d5 (rr-get r "is_d5"))
  (check-equal? (hash-count is-d5) 1)
  (check-allclose (hash-ref is-d5 564) (tv-md "ts1.is_d5.to_client" 'double))
  (rr-set! r "is_d5" (hash 328 (tv-md "ts1.is_d5.to_service" 'double)))
  (define is-d6 (rr-get r "is_d6"))
  (check-equal? (hash-count is-d6) 1)
  (check-allclose (hash-ref is-d6 "testval1") (tv-md "ts1.is_d6.to_client" 'double))
  (rr-set! r "is_d6" (hash "testval2" (tv-md "ts1.is_d6.to_service" 'double)))

  (check-equal? (rr-get r "is_str1") (hash 23 "Hello server"))
  (rr-set! r "is_str1" (hash 24 "Hello client"))
  (check-equal? (rr-get r "is_str2") (hash "testval1" "Hello server"))
  (rr-set! r "is_str2" (hash "testval2" "Hello client"))

  (check-allclose (mydat (hash-ref (rr-get r "is_struct1") 748)) (tv "ts1.is_struct1.to_client" 'double))
  (rr-set! r "is_struct1" (hash 372 (teststruct2 r (tv "ts1.is_struct1.to_service" 'double))))
  (check-allclose (mydat (hash-ref (rr-get r "is_struct2") "testval1")) (tv "ts1.is_struct2.to_client" 'double))
  (rr-set! r "is_struct2" (hash "testval2" (teststruct2 r (tv "ts1.is_struct2.to_service" 'double))))

  (check-equal? (rr-get r "list_d1") (list 1.643392e-01 1.537133e+09 1.369505e-03))
  (rr-set! r "list_d1" (list 4.074501e-07 -4.535303e+05 -2.956241e-20))

  (check-allclose (rr-struct-ref (rr-get r "struct3") "a1") (tv "ts1.struct3.to_client" 'double))
  (define s3 (rr-new-structure r "com.robotraconteur.testing.TestService2.ostruct2"))
  (rr-struct-set! s3 "a1" (tv "ts1.struct3.to_service" 'double))
  (rr-set! r "struct3" s3)

  (define list-d3 (rr-get r "list_d3"))
  (check-equal? (length list-d3) 2)
  (check-allclose (first list-d3) (tv "ts1.is_d3.to_client.a" 'double))
  (check-allclose (second list-d3) (tv "ts1.is_d3.to_client.b" 'double))
  (rr-set! r "list_d3" (list (tv "ts1.is_d3.to_service.a" 'double) (tv "ts1.is_d3.to_service.b" 'double)))

  (define list-d5 (rr-get r "list_d5"))
  (check-equal? (length list-d5) 1)
  (check-allclose (first list-d5) (tv-md "ts1.is_d5.to_client" 'double))
  (rr-set! r "list_d5" (list (tv-md "ts1.is_d5.to_service" 'double)))

  (check-allclose (mydat (first (rr-get r "list_struct1"))) (tv "ts1.is_struct1.to_client" 'double))
  (rr-set! r "list_struct1" (list (teststruct2 r (tv "ts1.is_struct1.to_service" 'double)))))

(define (test-varvalue-properties r)
  (check-array-equal (rr-get r "var_num") (tv "ts1.var_num.to_client" 'int32))
  (rr-set! r "var_num" (rr-varvalue (tv "ts1.var_num.to_service" 'int32) "int32[]"))
  (check-equal? (rr-get r "var_str") "Hello Client!")
  (rr-set! r "var_str" (rr-varvalue "Hello Server!" "string"))
  (check-allclose (mydat (rr-get r "var_struct")) (tv "ts1.var_struct.to_client" 'double))
  (rr-set! r "var_struct" (rr-varvalue (teststruct2 r (tv "ts1.var_struct.to_service" 'double))
                                       (string-append ts1 "teststruct2")))
  (check-equal? (hash-ref (rr-get r "var_vector") 10) "Hello Client!")
  (rr-set! r "var_vector" (rr-varvalue (hash 11 (rr-varvalue "Hello Server!" "string")) "varvalue{int32}"))
  (check-equal? (hash-ref (rr-get r "var_dictionary") "test1") "Hello Client!")
  (rr-set! r "var_dictionary"
           (rr-varvalue (hash "test2" (rr-varvalue "Hello Server!" "string")) "varvalue{string}"))
  (check-equal? (first (rr-get r "var_list")) "Hello Client!")
  (rr-set! r "var_list" (rr-varvalue (list (rr-varvalue "Hello Server!" "string")) "varvalue{list}"))
  (check-allclose (rr-get r "var_multidimarray") (tv-md "ts1.var_multidimarray.to_client" 'double))
  (rr-set! r "var_multidimarray"
           (rr-varvalue (tv-md "ts1.var_multidimarray.to_service" 'double) "double[*]")))

(test-case "properties"
  (with-client
   (lambda (r)
     (test-numeric-properties r)
     (test-struct-properties r)
     (test-indexed-and-list-properties r)
     (test-varvalue-properties r)
     ;; error passing
     (check-exn exn:fail:robotraconteur? (lambda () (rr-set! r "errtest" 1.0)))
     (check-exn exn:fail:robotraconteur? (lambda () (rr-get r "errtest")))
     (check-equal? (rr-get r "nulltest") 'null)
     (rr-set! r "nulltest" 'null))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestFunctions

(test-case "functions"
  (with-client
   (lambda (r)
     (rr-call r "func1")
     (rr-call r "func2" 10.0 20.34)
     (check-equal? (rr-call r "func3" 2.0 3.45) 5.45)
     (check-equal? (rr-call r "meaning_of_life") 42)
     (check-exn exn:fail:robotraconteur? (lambda () (rr-call r "func_errtest")))
     (check-rr-error 'DataTypeError (lambda () (rr-call r "func_errtest1")))
     (check-exn exn:fail:robotraconteur? (lambda () (rr-call r "func_errtest2")))
     (check-exn exn:fail:robotraconteur? (lambda () (rr-call r "func_errtest3"))))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestEvents

(test-case "events"
  (with-client
   (lambda (r)
     ;; listeners run on the connection's dispatch thread and must not block
     (define ev1 (make-semaphore 0))
     (define ev2 (make-async-channel))
     (rr-add-event-listener! r "ev1" (lambda () (semaphore-post ev1)))
     (rr-add-event-listener! r "ev2" (lambda (d s) (async-channel-put ev2 (list d (vector-ref (mydat s) 0)))))
     (rr-call r "func1")
     (rr-call r "func2" 27.3 98.23)
     (check-not-false (sync/timeout 2 ev1))
     ;; the service fires events 200 ms after the call, so an event from an
     ;; earlier client's func2 may arrive first; like the Python callback,
     ;; wait for the matching one
     (define deadline (+ (current-inexact-milliseconds) 2000))
     (check-equal? (let loop ()
                     (define v (sync/timeout (max 0 (/ (- deadline (current-inexact-milliseconds)) 1000)) ev2))
                     (cond [(not v) #f]
                           [(equal? v (list 27.3 98.23)) v]
                           [else (loop)]))
                   (list 27.3 98.23)))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestObjRefs

(test-case "objrefs"
  (with-client
   (lambda (r)
     (define o1 (rr-objref r "o1"))
     (define o2-10 (rr-objref r "o2" 10))
     (define o2-34 (rr-objref r "o2" 34))
     (define o3-1 (rr-objref r "o3" 1))
     (define o4-myind (rr-objref r "o4" "myind"))
     (define o4-special (rr-objref r "o4" "ind!@#$%^&*().<>     "))
     (define o2-10-o2-1-32 (rr-objref o2-10 "o2_2" 32))
     (define o3-ind1 (rr-objref o2-10-o2-1-32 "o3_1" "ind1"))
     (define o3-ind2 (rr-objref o2-10-o2-1-32 "o3_1" "ind2"))
     (rr-set! o1 "d1" (tv "ts1.client.o_d1a" 'double))
     (rr-set! o2-10 "d1" (tv "ts1.client.o_d1b" 'double))
     (rr-set! o2-34 "d1" (tv "ts1.client.o_d1c" 'double))
     (rr-set! o3-1 "d1" (tv "ts1.client.o_d1d" 'double))
     (rr-set! o4-myind "d1" (tv "ts1.client.o_d1e" 'double))
     (rr-set! o4-special "d1" (tv "ts1.client.o_d1f" 'double))
     (rr-set! o2-10-o2-1-32 "data" "Hello world!")
     (rr-set! o3-ind1 "data2" "Test string 1")
     (rr-set! o3-ind2 "data2" "Test string 2")

     ;; varobject o6 changes type as the service releases and replaces it
     (rr-call r "o6_op" 0)
     (sleep 0.1)
     (define o6-1 (rr-objref r "o6"))
     (check-equal? (rr-object-type o6-1) (string-append ts1 "sub1"))
     (define o6-1-1 (rr-objref o6-1 "o2_1"))
     (rr-set! o6-1 "d1" (vector 0.0))
     (rr-set! o6-1-1 "data" "Hello world!")
     (rr-call r "o6_op" 1)
     (sleep 0.1)
     (check-exn exn:fail:robotraconteur? (lambda () (rr-set! o6-1 "d1" (vector 0.0))))
     (check-exn exn:fail:robotraconteur? (lambda () (rr-set! o6-1-1 "data" "Hello world!")))

     (define o6-2 (rr-objref r "o6"))
     (check-equal? (rr-object-type o6-2) (string-append ts1 "sub2"))
     (rr-set! o6-2 "data" "Hello world!")
     (rr-call r "o6_op" 2)
     (sleep 0.1)
     (check-exn exn:fail:robotraconteur? (lambda () (rr-set! o6-2 "data" "Hello world!")))
     (define o6-3 (rr-objref r "o6"))
     (check-equal? (rr-object-type o6-3) "com.robotraconteur.testing.TestService2.subobj")
     (check-equal? (rr-call o6-3 "add_val" 2.0) 3.0))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestPipes

(test-case "pipes"
  (with-client
   (lambda (r)
     (define e1 (rr-pipe-connect r "p1" -1))
     (define e2 (rr-pipe-connect r "p1" 3432))
     (define e3 (rr-pipe-connect r "p2" -1))
     (check-equal? (rr-pipe-endpoint-index e2) 3432)
     (define got1 (make-semaphore 0))
     (define got2 (make-semaphore 0))
     (define got3 (make-semaphore 0))
     (define acked (make-async-channel))
     (rr-pipe-set-request-ack! e1 #t)
     (rr-pipe-add-listener! e1 (lambda (p) (semaphore-post got1)))
     (rr-pipe-add-listener! e2 (lambda (p) (semaphore-post got2)))
     (rr-pipe-add-listener! e3 (lambda (p) (semaphore-post got3)))
     (rr-pipe-add-ack-listener! e1 (lambda (p pnum) (async-channel-put acked pnum)))
     (define first-pnum (rr-pipe-send e1 (vector 1.0 2.0 3.0 4.0)))
     (rr-pipe-send e1 (vector 5.0 6.0 7.0 8.0))
     (rr-pipe-send e1 (tv "ts1.client.d3" 'double))
     (rr-pipe-send e2 (vector 3.21))
     (rr-pipe-send e2 (vector 4.72))
     (rr-pipe-send e2 (vector 72.34))
     (rr-pipe-send e3 (teststruct2 r (vector 738.29)))
     (rr-pipe-send e3 (teststruct2 r (vector 89.83)))
     (check-not-false (sync/timeout 5 got1))
     (check-not-false (sync/timeout 5 got2))
     (check-not-false (sync/timeout 5 got3))

     ;; the service echoes packets back on the same endpoint
     (check-allclose (rr-pipe-receive e1) (vector 1.0 2.0 3.0 4.0))
     (check-allclose (rr-pipe-receive e1 #:timeout 1) (vector 5.0 6.0 7.0 8.0))
     (check-allclose (rr-pipe-receive e1 #:timeout 1) (tv "ts1.client.d3" 'double))
     (check-allclose (rr-pipe-receive e2) (vector 3.21))
     (check-allclose (rr-pipe-receive e2 #:timeout 1) (vector 4.72))
     (check-allclose (rr-pipe-receive e2 #:timeout 1) (vector 72.34))
     (check-allclose (mydat (rr-pipe-receive e3)) (vector 738.29))
     (check-allclose (mydat (rr-pipe-receive e3 #:timeout 1)) (vector 89.83))
     ;; e1 requested acks; the first packet must be acknowledged
     (check-equal? (sync/timeout 2 acked) first-pnum)
     (sleep 0.5)
     (rr-call r "pipe_check_error")
     (check-eq? (rr-member-direction r "p1") 'both)
     (rr-pipe-close e1)
     (rr-pipe-close e2)
     (rr-pipe-close e3))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestCallbacks

(test-case "callbacks"
  (with-client
   (lambda (r)
     ;; checks run after the call: a failed check inside a callback would be
     ;; reported to the service, not to rackunit
     (define called (make-hash))
     (rr-set-callback! r "cb1" (lambda () (hash-set! called 'cb1 #t)))
     (rr-set-callback! r "cb2" (lambda (d1 d2) (hash-set! called 'cb2 (list d1 d2))))
     (rr-set-callback! r "cb3" (lambda (d1 d2) (hash-set! called 'cb3 #t) (+ d1 d2 3.14)))
     (rr-set-callback! r "cb_meaning_of_life" (lambda () (hash-set! called 'cb4 #t) 42))
     (rr-set-callback! r "cb_errtest" (lambda () (hash-set! called 'cb5 #t) (error "This is a test")))
     (rr-call r "test_callbacks")
     (check-true (hash-ref called 'cb1 #f))
     (check-equal? (hash-ref called 'cb2 #f) (list 739.2 0.392))
     (check-true (hash-ref called 'cb3 #f))
     (check-true (hash-ref called 'cb4 #f))
     (check-true (hash-ref called 'cb5 #f)))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestWires

(test-case "wires"
  (with-client
   (lambda (r)
     (define w1 (rr-wire-connect r "w1"))
     (define w2 (rr-wire-connect r "w2"))
     (define w3 (rr-wire-connect r "w3"))
     (rr-wire-set-in-value-lifespan! w1 10)
     (define changed (make-hash))
     (rr-wire-add-listener! w1 (lambda (v ts) (hash-set! changed 'w1 #t)))
     (rr-wire-add-listener! w2 (lambda (v ts) (hash-set! changed 'w2 #t)))
     (rr-wire-add-listener! w3 (lambda (v ts) (hash-set! changed 'w3 #t)))
     (rr-wire-set-out-value! w1 (vector 0.0))
     (rr-wire-set-out-value! w2 (teststruct2 r (vector 0.0)))
     (rr-wire-set-out-value! w3 (rr-multidim '(1 1) (vector 0)))
     (rr-wire-set-out-value! w1 (tv "ts1.client.d1" 'double))
     (rr-wire-set-out-value! w2 (teststruct2 r (tv "ts1.client.d2" 'double)))
     (rr-wire-set-out-value! w3 (tv-md "ts1.client.i3" 'int32))
     (sleep 0.5)
     ;; the service echoes the out-value back as the in-value
     (check-allclose (rr-wire-in-value w1) (tv "ts1.client.d1" 'double))
     (check-allclose (mydat (rr-wire-in-value w2)) (tv "ts1.client.d2" 'double))
     (check-array-equal (rr-wire-in-value w3) (tv-md "ts1.client.i3" 'int32))
     (check-true (hash-ref changed 'w1 #f))
     (check-true (hash-ref changed 'w2 #f))
     (check-true (hash-ref changed 'w3 #f))

     (define-values (in-ok in-v in-ts) (rr-wire-try-in-value w1))
     (check-true in-ok)
     (check-allclose in-v (tv "ts1.client.d1" 'double))
     (define-values (out-ok out-v out-ts) (rr-wire-try-out-value w1))
     (check-true out-ok)
     (check-allclose out-v (tv "ts1.client.d1" 'double))
     (check-eq? (rr-member-direction r "w1") 'both)

     (rr-wire-set-in-value-lifespan! w1 0.001)
     (sleep 0.01)
     (check-rr-error 'ValueNotSet (lambda () (rr-wire-in-value w1)))
     (rr-wire-close w1)
     (rr-wire-close w2)
     (rr-wire-close w3))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestAuthentication

(define (cred pass) (hash "password" (rr-varvalue pass "string")))

(test-case "authentication"
  (define r1 (rr-connect (auth-url) #:username "testuser1" #:credentials (cred "testpass1")))
  (rr-call r1 "func3" 2.2 3.3)
  (rr-close r1)
  (define r2 (rr-connect (auth-url) #:username "testuser2" #:credentials (cred "testpass2")))
  (rr-call r2 "func3" 2.2 3.3)
  (rr-close r2)
  ;; wrong password
  (check-exn exn:fail:robotraconteur?
             (lambda ()
               (define r3 (rr-connect (auth-url) #:username "testuser2" #:credentials (cred "testpass1")))
               (rr-close r3)))
  ;; no credentials
  (check-exn exn:fail:robotraconteur?
             (lambda ()
               (define r4 (rr-connect (auth-url)))
               (dynamic-wind void (lambda () (rr-call r4 "func3" 2.2 3.3)) (lambda () (rr-close r4))))))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestObjectLock

(define (check-access o o2)
  (rr-set! o "d1" (vector 1.0))
  (rr-set! o2 "data" "Hello world"))

(define (check-no-access o)
  (check-exn exn:fail:robotraconteur? (lambda () (rr-set! o "d1" (vector 1.0)))))

(test-case "object lock"
  (define (login user pass) (rr-connect (auth-url) #:username user #:credentials (cred pass)))
  (define r1 (login "testuser1" "testpass1"))
  (define r2 (login "testuser1" "testpass1"))
  (define r1-o (rr-objref r1 "o1"))
  (define r1-o-o2 (rr-objref r1-o "o2_1"))
  (define r2-o (rr-objref r2 "o1"))
  (define r2-o-o2 (rr-objref r2-o "o2_1"))
  (define r3 (login "testuser2" "testpass2"))
  (define r3-o (rr-objref r3 "o1"))
  (define r3-o-o2 (rr-objref r3-o "o2_1"))
  ;; everything works before locking
  (for ([r (list r1 r2 r3)]) (rr-call r "func3" 2.2 3.3))
  (check-access r1-o r1-o-o2)
  (check-access r2-o r2-o-o2)
  (check-access r3-o r3-o-o2)

  ;; user lock: both testuser1 sessions keep access, testuser2 loses it
  (rr-request-object-lock r1-o 'user)
  (rr-call r1 "func3" 2.2 3.3)
  (check-access r1-o r1-o-o2)
  (rr-call r2 "func3" 2.2 3.3)
  (check-access r2-o r2-o-o2)
  (rr-call r3 "func3" 2.2 3.3)
  (check-no-access r3-o)
  (check-exn exn:fail:robotraconteur? (lambda () (rr-set! r3-o-o2 "data" "Hello world")))

  ;; release restores access
  (rr-release-object-lock r1-o)
  (check-access r1-o r1-o-o2)
  (check-access r2-o r2-o-o2)
  (check-access r3-o r3-o-o2)

  ;; closing the locking session releases the lock; closing the other does not
  (rr-request-object-lock r1-o 'user)
  (check-no-access r3-o)
  (rr-set! r2-o "d1" (vector 1.0))
  (rr-close r2)
  (check-no-access r3-o)
  (rr-close r1)
  (rr-set! r3-o "d1" (vector 1.0))

  ;; client lock: only the locking session has access
  (define r1b (login "testuser1" "testpass1"))
  (define r2b (login "testuser2" "testpass2"))
  (define r1b-o (rr-objref r1b "o1"))
  (define r2b-o (rr-objref r2b "o1"))
  (rr-request-object-lock r1b-o 'client)
  (rr-set! r1b-o "d1" (vector 1.0))
  (check-no-access r2b-o)
  (check-no-access r3-o)

  ;; the superuser can override and release the lock
  (define r5 (login "testsuperuser" "superpass1"))
  (rr-release-object-lock (rr-objref r5 "o1"))
  (rr-set! r2b-o "d1" (vector 1.0))
  (rr-set! r3-o "d1" (vector 1.0))
  (for ([r (list r1b r2b r3 r5)]) (rr-close r)))

;; ---------------------------------------------------------------------------
;; ServiceTestClient.TestMonitorLock
;;
;; The Python version's worker thread rebinds local flags, so its asserts
;; cannot fail. This port checks the intent: a second client blocks in
;; MonitorEnter until the first client exits the monitor.

(test-case "monitor lock"
  (define r1 (rr-connect (url)))
  (define r2 (rr-connect (url)))
  (define r1-o (rr-objref r1 "o1"))
  (define r1-o-o2 (rr-objref r1-o "o2_1"))
  (define r2-o (rr-objref r2 "o1"))
  (define r2-o-o2 (rr-objref r2-o "o2_1"))
  (rr-call r1 "func3" 2.2 3.3)
  (check-access r1-o r1-o-o2)
  (rr-call r2 "func3" 2.2 3.3)
  (check-access r2-o r2-o-o2)

  (define holding? (box #f))      ; main thread holds the monitor
  (define entered (make-channel)) ; worker reports holding? at the time it entered
  (define worker-error (box #f))
  (call-with-rr-monitor-lock
   r1-o
   (lambda ()
     (set-box! holding? #t)
     (thread
      (lambda ()
        (with-handlers ([(lambda (e) #t) (lambda (e) (set-box! worker-error e) (channel-put entered 'error))])
          (rr-call r2 "func3" 2.2 3.3)
          (rr-set! r2-o-o2 "data" "Hello world")
          (rr-monitor-enter r2-o)
          (define seen (unbox holding?))
          (rr-set! r2-o "d1" (vector 0.0))
          (rr-monitor-exit r2-o)
          (channel-put entered seen))))
     (sleep 0.2)
     (rr-call r1 "func3" 2.2 3.3)
     (rr-set! r1-o "d1" (vector 0.0))
     (set-box! holding? #f)))
  (define seen (sync/timeout 10 entered))
  (check-false (unbox worker-error))
  ;; the worker only entered after the main thread released the monitor
  (check-equal? seen #f)
  (rr-close r1)
  (rr-close r2))
