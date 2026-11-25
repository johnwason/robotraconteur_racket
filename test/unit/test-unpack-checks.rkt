#lang racket/base
;; Values unpacked from the service are checked as the C++ core's CastData
;; does: a scalar or enum must have its declared element type and exactly one
;; element, and a multidim array's dims must be uint32 with a product equal
;; to the array length. Bad data raises an error instead of giving a
;; wrong-shaped value or a Racket contract error.
(require rackunit racket/file racket/runtime-path "../../robotraconteur/message.rkt" "../../robotraconteur/pack.rkt"
         "../../robotraconteur/robdef.rkt")

(define-runtime-path robdef-file "../experimental.racket_test.robdef")
(define reg (make-type-registry))
(registry-add-def! reg (parse-robdef (file->string robdef-file)))
(define ns "experimental.racket_test")
(define (unpack type e) (unpack-elem reg ns (parse-type type) e))
(define (num name dt . xs) (make-elem name dt (list->vector xs)))
(define (md dims-dt dims arr-elem)
  (make-elem "value" dt-multidimarray (list (make-elem "dims" dims-dt (list->vector dims)) arr-elem)))
(define rr-error #rx"robotraconteur")

(test-case "valid scalars, enums and multidim arrays unpack"
  (check-equal? (unpack "double" (num "value" dt-double 1.5)) 1.5)
  (check-equal? (unpack "Color" (num "value" dt-int32 16)) 16)
  (check-equal? (unpack "double[*]" (md dt-uint32 '(2 2) (num "array" dt-double 1.0 2.0 3.0 4.0)))
                (rr-multidim '(2 2) (vector 1.0 2.0 3.0 4.0))))

(test-case "a scalar with the wrong element type or count is an error"
  (check-exn rr-error (lambda () (unpack "double" (num "value" dt-int32 1))))
  (check-exn rr-error (lambda () (unpack "double" (num "value" dt-double 1.0 2.0))))
  (check-exn rr-error (lambda () (unpack "double" (num "value" dt-double)))))

(test-case "an enum must be a single int32"
  (check-exn rr-error (lambda () (unpack "Color" (num "value" dt-double 1.5))))
  (check-exn rr-error (lambda () (unpack "Color" (num "value" dt-uint8 1))))
  (check-exn rr-error (lambda () (unpack "Color" (num "value" dt-int32)))))

(test-case "multidim dims must be uint32 and match the array length"
  (check-exn rr-error (lambda () (unpack "double[*]" (md dt-uint32 '(3 3) (num "array" dt-double 1.0 2.0)))))
  (check-exn rr-error (lambda () (unpack "double[*]" (md dt-double '(2.0) (num "array" dt-double 1.0 2.0)))))
  (check-exn rr-error (lambda () (unpack "double[*]" (md dt-uint32 '(2) (num "array" dt-int32 1 2)))))
  (check-exn rr-error (lambda () (unpack "double[*]" (md dt-uint32 '(1) (make-elem "array" dt-string "x"))))))

(test-case "pod and namedarray multidim dims must match the number of items"
  (define pod-item (make-elem "0" dt-pod #:type-name "experimental.racket_test.TestPod"
                              (list (num "a" dt-double 1.0) (num "b" dt-int32 1 2 3))))
  (define pod-md (lambda (dims)
                   (make-elem "value" dt-pod-multidimarray #:type-name "experimental.racket_test.TestPod"
                              (list (make-elem "dims" dt-uint32 (list->vector dims))
                                    (make-elem "array" dt-pod-array #:type-name "experimental.racket_test.TestPod"
                                               (list pod-item))))))
  (check-equal? (rr-multidim-dims (unpack "TestPod[*]" (pod-md '(1 1)))) '(1 1))
  (check-exn rr-error (lambda () (unpack "TestPod[*]" (pod-md '(2 2)))))
  (define na-md (lambda (dims)
                  (make-elem "value" dt-namedarray-multidimarray #:type-name "experimental.racket_test.Vec3"
                             (list (make-elem "dims" dt-uint32 (list->vector dims))
                                   (make-elem "array" dt-namedarray-array #:type-name "experimental.racket_test.Vec3"
                                              (list (num "array" dt-double 1.0 2.0 3.0 4.0 5.0 6.0)))))))
  (check-equal? (rr-multidim-dims (unpack "Vec3[*]" (na-md '(2)))) '(2))
  (check-exn rr-error (lambda () (unpack "Vec3[*]" (na-md '(3))))))
