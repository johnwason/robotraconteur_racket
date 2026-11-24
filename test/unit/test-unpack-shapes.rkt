#lang racket/base
;; Data from the service is checked before use: the type named by a struct,
;; pod array or namedarray array element must be of that kind, nested data
;; must be a list of elements, a namedarray's array must have its numeric type
;; and a multiple of its element count, and pipe dispatch checks indexes,
;; packets and packet numbers. Bad data raises a Robot Raconteur error
;; ("robotraconteur: ...") instead of a Racket contract violation
;; (entrydef-members, string-contains?, in-list, vector-length, quotient by
;; zero, vector-ref).
(require rackunit racket/file racket/runtime-path racket/string "fake-service.rkt"
         "../../robotraconteur/message.rkt" "../../robotraconteur/pack.rkt"
         "../../robotraconteur/robdef.rkt" "../../robotraconteur/client.rkt")

(define-runtime-path robdef-file "../experimental.racket_test.robdef")
(define reg (make-type-registry))
(registry-add-def! reg (parse-robdef (file->string robdef-file)))
(registry-add-def! reg (parse-robdef "service experimental.shapes\n\nstdver 0.10\n\nnamedarray Z\n    field double[0] z\nend\n\nnamedarray E\nend\n"))
(define (q n) (string-append "experimental.racket_test." n))
(define (unpack e) (unpack-elem reg "" #f e))
(define (num name dt . xs) (make-elem name dt (list->vector xs)))
(define (na-array tn . data) (make-elem "value" dt-namedarray-array #:type-name tn data))
(define (pod-array tn . items) (make-elem "value" dt-pod-array #:type-name tn items))

(define (check-rr-error thunk what)
  (define e (with-handlers ([(lambda (e) #t) values]) (thunk) #f))
  (check-true (exn:fail? e) (format "~a: no error" what))
  (when (exn:fail? e)
    (check-false (exn:fail:contract? e) (format "~a: ~a" what (exn-message e)))
    (check-regexp-match #rx"^robotraconteur: " (exn-message e))))

(test-case "valid pod and namedarray arrays unpack"
  (check-equal? (vector-length (unpack (na-array (q "Vec3") (num "array" dt-double 1.0 2.0 3.0 4.0 5.0 6.0)))) 2)
  (check-equal? (rr-struct-ref (vector-ref (unpack (pod-array (q "TestPod")
                                                    (make-elem "0" dt-pod (list (num "a" dt-double 1.0)
                                                                                (num "b" dt-int32 1 2 3)))))
                                           0)
                               "b")
                (vector 1 2 3)))

(test-case "struct, pod and namedarray array elements must name a type of their kind"
  (check-rr-error (lambda () (unpack (na-array (q "Color") (num "array" dt-double 1.0)))) "namedarray of enum")
  (check-rr-error (lambda () (unpack (na-array (q "TestStruct") (num "array" dt-double 1.0)))) "namedarray of struct")
  (check-rr-error (lambda () (unpack (na-array (q "TestPod") (num "array" dt-double 1.0)))) "namedarray of pod")
  (check-rr-error (lambda () (unpack (pod-array (q "Color")))) "pod of enum")
  (check-rr-error (lambda () (unpack (pod-array (q "Vec3")))) "pod of namedarray")
  (check-rr-error (lambda () (unpack (make-elem "value" dt-structure #:type-name (q "Color") '()))) "struct of enum")
  (check-rr-error (lambda () (unpack (make-elem "value" dt-structure #:type-name (q "TestPod") '()))) "struct of pod"))

(test-case "nested data must be a list of elements"
  (check-rr-error (lambda () (unpack (make-elem "value" dt-namedarray-array #:type-name (q "Vec3") (vector 1.0))))
                  "namedarray array data")
  (check-rr-error (lambda () (unpack (make-elem "value" dt-pod-array #:type-name (q "TestPod") (vector 1.0))))
                  "pod array data")
  (check-rr-error (lambda () (unpack (pod-array (q "TestPod") (num "0" dt-double 1.0)))) "pod data")
  (check-rr-error (lambda () (unpack (make-elem "value" dt-structure #:type-name (q "TestStruct") (vector 1.0))))
                  "struct data"))

(test-case "a namedarray array must be numeric, of the namedarray's type, with whole items"
  (check-rr-error (lambda () (unpack (na-array (q "Vec3") (make-elem "array" dt-string "x")))) "string array")
  (check-rr-error (lambda () (unpack (na-array (q "Vec3") (num "array" dt-int32 1 2 3)))) "int32 array")
  (check-rr-error (lambda () (unpack (na-array (q "Vec3") (num "array" dt-double 1.0 2.0 3.0 4.0)))) "4 of 3")
  (check-rr-error (lambda () (unpack (na-array "experimental.shapes.Z" (num "array" dt-double 1.0)))) "no elements")
  (check-rr-error (lambda () (unpack (na-array "experimental.shapes.E" (num "array" dt-double 1.0)))) "no fields"))

(test-case "pod fields must have the number of items of their type"
  (define (pod a b) (pod-array (q "TestPod") (make-elem "0" dt-pod (list a b))))
  (check-rr-error (lambda () (unpack (pod (num "a" dt-double) (num "b" dt-int32 1 2 3)))) "scalar with 0")
  (check-rr-error (lambda () (unpack (pod (num "a" dt-double 1.0) (num "b" dt-int32 1 2)))) "int32[3] with 2"))

;; Pipe dispatch on the reader thread: malformed entries are logged and
;; dropped; the logged error must be a Robot Raconteur error.
(define robdef "service experimental.fakepipe\n\nstdver 0.10\n\nobject Obj\n    property double d\n    pipe double p\nend\n")

(define (handler en send!)
  (case (entry-type en)
    [(PipeConnectReq)
     (send! (list (entry 'PipeConnectRet "svc" "p" (entry-request-id en) 0 ""
                         (list (make-elem "index" dt-int32 (vector 1))))))]
    [(PropertyGetReq)
     (send! (list (entry 'PipeClosed "svc" "p" 0 0 "" (list (make-elem "index" dt-string "x")))
                  (entry 'PipePacket "svc" "p" 0 0 "" (list (num "1" dt-double 1.0)))
                  (entry 'PipePacket "svc" "p" 0 0 ""
                         (list (make-elem "1" dt-dictionary
                                          (list (num "packetnumber" dt-double 1.5)
                                                (num "packet" dt-double 1.0)))))
                  (entry 'PipePacketRet "svc" "p" 0 0 "" (list (make-elem "1" dt-string "x")))))
     (send! (list (entry 'PropertyGetRes "svc" "d" (entry-request-id en) 0 ""
                         (list (num "value" dt-double 2.0)))))]
    [else (void)]))

(test-case "malformed pipe entries give Robot Raconteur errors"
  (define recv (make-log-receiver (current-logger) 'error))
  (define obj (rr-connect (format "rr+tcp://127.0.0.1:~a/?service=svc"
                                  (serve-fake robdef "experimental.fakepipe.Obj" handler))
                          #:timeout 10))
  (rr-pipe-connect obj "p" 1)
  (check-equal? (rr-get obj "d") 2.0)
  (rr-close obj)
  (define logs
    (let loop ([acc '()])
      (define v (sync/timeout 0 recv))
      (if v (loop (cons (vector-ref v 1) acc)) (reverse acc))))
  (define handled (filter (lambda (s) (string-contains? s "error handling Pipe")) logs))
  (check-equal? (length handled) 4 (format "~s" logs))
  (for ([s (in-list handled)])
    (check-regexp-match #rx"error handling Pipe[A-Za-z]+: robotraconteur: " s)))
