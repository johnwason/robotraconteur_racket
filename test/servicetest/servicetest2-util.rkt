#lang racket/base
;; Port of the sequence generator and fill/verify helpers from
;; robotraconteur/test/python/RobotRaconteurTest/ServiceTest2.py
;; (ServiceTest2_test_sequence_gen, ServiceTest2_fill_* / _verify_*).
;;
;; Values follow the Racket client conventions: pods and namedarrays are
;; rr-struct, arrays are vectors, multidim arrays are rr-multidim (column major,
;; matching the Python reshape(..., order="F")).
(require rackunit
         robotraconteur "test-vectors.rkt" "util.rkt")

(provide make-seqgen seq-double! seq-uint32! seq-int8!
         fill-testpod1 verify-testpod1
         fill-testpod2 verify-testpod2
         create-testpod1-array verify-testpod1-array
         create-testpod1-multidimarray verify-testpod1-multidimarray
         fill-teststruct3 verify-teststruct3
         fill-transform verify-transform
         create-transform-array verify-transform-array
         create-transform-multidimarray verify-transform-multidimarray
         ts3)

(define ts3 "com.robotraconteur.testing.TestService3.")

;; --- ServiceTest2_test_sequence_gen (tables from the test vector blob)

(define double-constants (get-test-vector "seq.double_constants" 'double))
(define uint32-constants (get-test-vector "seq.uint32_constants" 'uint32))

(struct seqgen ([counter #:mutable] step))

(define (make-seqgen seed) (seqgen (modulo seed 7823) (+ (modulo seed 17) 7)))

(define (advance! g) (set-seqgen-counter! g (+ (seqgen-counter g) (seqgen-step g))))

(define (seq-double! g)
  (advance! g)
  (vector-ref double-constants (modulo (seqgen-counter g) (vector-length double-constants))))

(define (seq-uint32! g)
  (advance! g)
  (vector-ref uint32-constants (modulo (seqgen-counter g) (vector-length uint32-constants))))

(define (seq-int8! g)
  (advance! g)
  (- (modulo (seqgen-counter g) #xFF) 128))

(define (create-double-array g n) (for/vector ([i n]) (seq-double! g)))
(define (create-int8-array g n) (for/vector ([i n]) (seq-int8! g)))

;; flatten a vector or column-major rr-multidim
(define (flat v) (if (rr-multidim? v) (rr-multidim-array v) v))

;; Pods and namedarrays may arrive as a scalar rr-struct or a one-element vector
(define (one v) (if (vector? v) (begin (check-equal? (vector-length v) 1) (vector-ref v 0)) v))

(define (verify-double-array g a n)
  (define a2 (flat a))
  (check-equal? (vector-length a2) n)
  (for ([d (in-vector a2)]) (check-equal? d (seq-double! g))))

(define (verify-int8-array g a n)
  (check-equal? (vector-length a) n)
  (for ([d (in-vector a)]) (check-equal? d (seq-int8! g))))

(define (md m n items) (rr-multidim (list m n) items))

(define (check-dims v m n)
  (check-pred rr-multidim? v)
  (check-equal? (rr-multidim-dims v) (list m n)))

;; --- transform (namedarray: rotation quaternion q0..q3, translation x y z)

(define (fill-transform r seed)
  (define g (make-seqgen seed))
  (define t (rr-new-structure r (string-append ts3 "transform")))
  (define rot (rr-struct-ref t "rotation"))
  (define tr (rr-struct-ref t "translation"))
  (for ([f '("q0" "q1" "q2" "q3")]) (rr-struct-set! rot f (seq-double! g)))
  (for ([f '("x" "y" "z")]) (rr-struct-set! tr f (seq-double! g)))
  t)

(define (transform->vector t)
  (define rot (rr-struct-ref t "rotation"))
  (define tr (rr-struct-ref t "translation"))
  (for/vector ([v (append (for/list ([f '("q0" "q1" "q2" "q3")]) (rr-struct-ref rot f))
                          (for/list ([f '("x" "y" "z")]) (rr-struct-ref tr f)))])
    v))

(define (verify-transform t seed)
  (define g (make-seqgen seed))
  (check-allclose (transform->vector (one t)) (for/vector ([i 7]) (seq-double! g))))

(define (create-transform-array r n seed)
  (define g (make-seqgen seed))
  (for/vector ([i n]) (fill-transform r (seq-uint32! g))))

(define (verify-transform-array v n seed)
  (define g (make-seqgen seed))
  (check-equal? (vector-length v) n)
  (for ([t (in-vector v)]) (verify-transform t (seq-uint32! g))))

(define (create-transform-multidimarray r m n seed)
  (md m n (create-transform-array r (* m n) seed)))

(define (verify-transform-multidimarray v m n seed)
  (check-dims v m n)
  (verify-transform-array (rr-multidim-array v) (* m n) seed))

;; --- testpod2

(define (fill-testpod2 r seed)
  (define g (make-seqgen seed))
  (define s (rr-new-structure r (string-append ts3 "testpod2")))
  (rr-struct-set! s "i1" (seq-int8! g))
  (rr-struct-set! s "i2" (create-int8-array g 15))
  (rr-struct-set! s "i3" (create-int8-array g (modulo (seq-uint32! g) 15)))
  s)

(define (verify-testpod2 s0 seed)
  (define s (one s0))
  (define g (make-seqgen seed))
  (check-equal? (rr-struct-ref s "i1") (seq-int8! g))
  (verify-int8-array g (rr-struct-ref s "i2") 15)
  (verify-int8-array g (rr-struct-ref s "i3") (modulo (seq-uint32! g) 15)))

(define (create-testpod2-array r g n)
  (for/vector ([i n]) (fill-testpod2 r (seq-uint32! g))))

(define (verify-testpod2-array g v n)
  (check-equal? (vector-length v) n)
  (for ([s (in-vector v)]) (verify-testpod2 s (seq-uint32! g))))

;; --- testpod1

(define (fill-testpod1 r seed)
  (define g (make-seqgen seed))
  (define s (rr-new-structure r (string-append ts3 "testpod1")))
  (rr-struct-set! s "d1" (seq-double! g))
  (rr-struct-set! s "d2" (create-double-array g 6))
  (rr-struct-set! s "d3" (create-double-array g (modulo (seq-uint32! g) 6)))
  (rr-struct-set! s "d4" (md 3 3 (create-double-array g 9)))
  (rr-struct-set! s "s1" (fill-testpod2 r (seq-uint32! g)))
  (rr-struct-set! s "s2" (create-testpod2-array r g 8))
  (rr-struct-set! s "s3" (create-testpod2-array r g (modulo (seq-uint32! g) 9)))
  (rr-struct-set! s "s4" (md 2 4 (create-testpod2-array r g 8)))
  (rr-struct-set! s "t1" (fill-transform r (seq-uint32! g)))
  (rr-struct-set! s "t2" (for/vector ([i 4]) (fill-transform r (seq-uint32! g))))
  (define t3-len (modulo (seq-uint32! g) 15))
  (rr-struct-set! s "t3" (for/vector ([i t3-len]) (fill-transform r (seq-uint32! g))))
  (rr-struct-set! s "t4" (md 2 4 (for/vector ([i 8]) (fill-transform r (seq-uint32! g)))))
  s)

(define (verify-testpod1 s0 seed)
  (define s (one s0))
  (define g (make-seqgen seed))
  (check-equal? (rr-struct-ref s "d1") (seq-double! g))
  (verify-double-array g (rr-struct-ref s "d2") 6)
  (verify-double-array g (rr-struct-ref s "d3") (modulo (seq-uint32! g) 6))
  (verify-double-array g (rr-struct-ref s "d4") 9)
  (verify-testpod2 (rr-struct-ref s "s1") (seq-uint32! g))
  (verify-testpod2-array g (rr-struct-ref s "s2") 8)
  (verify-testpod2-array g (rr-struct-ref s "s3") (modulo (seq-uint32! g) 9))
  (verify-testpod2-array g (flat (rr-struct-ref s "s4")) 8)
  (verify-transform (rr-struct-ref s "t1") (seq-uint32! g))
  (for ([t (in-vector (rr-struct-ref s "t2"))]) (verify-transform t (seq-uint32! g)))
  (define t3-len (modulo (seq-uint32! g) 15))
  (check-equal? (vector-length (rr-struct-ref s "t3")) t3-len)
  (for ([t (in-vector (rr-struct-ref s "t3"))]) (verify-transform t (seq-uint32! g)))
  (for ([t (in-vector (flat (rr-struct-ref s "t4")))]) (verify-transform t (seq-uint32! g))))

(define (create-testpod1-array r n seed)
  (define g (make-seqgen seed))
  (for/vector ([i n]) (fill-testpod1 r (seq-uint32! g))))

(define (verify-testpod1-array v n seed)
  (define g (make-seqgen seed))
  (check-equal? (vector-length v) n)
  (for ([s (in-vector v)]) (verify-testpod1 s (seq-uint32! g))))

(define (create-testpod1-multidimarray r m n seed)
  (md m n (create-testpod1-array r (* m n) seed)))

(define (verify-testpod1-multidimarray v m n seed)
  (check-dims v m n)
  (verify-testpod1-array (rr-multidim-array v) (* m n) seed))

;; --- teststruct3

(define (vv v type) (rr-varvalue v (string-append ts3 type)))

(define (fill-teststruct3 r seed)
  (define o (rr-new-structure r (string-append ts3 "teststruct3")))
  (define g (make-seqgen seed))
  (define (set f v) (rr-struct-set! o f v))
  (set "s1" (fill-testpod1 r (seq-uint32! g)))
  (define s2-seed (seq-uint32! g))
  (set "s2" (create-testpod1-array r (modulo s2-seed 17) s2-seed))
  (set "s3" (create-testpod1-array r 11 (seq-uint32! g)))
  (define s4-seed (seq-uint32! g))
  (set "s4" (create-testpod1-array r (modulo s4-seed 16) s4-seed))
  (set "s5" (create-testpod1-multidimarray r 3 3 (seq-uint32! g)))
  (define s6-seed (seq-uint32! g))
  (set "s6" (create-testpod1-multidimarray r (modulo s6-seed 6) (modulo s6-seed 3) s6-seed))
  (set "s7" (list (fill-testpod1 r (seq-uint32! g))))
  (set "s8" (list (create-testpod1-array r 2 (seq-uint32! g))
                  (create-testpod1-array r 4 (seq-uint32! g))))
  (set "s9" (list (create-testpod1-multidimarray r 2 3 (seq-uint32! g))
                  (create-testpod1-multidimarray r 4 5 (seq-uint32! g))))
  (set "s10" (vv (vector (fill-testpod1 r (seq-uint32! g))) "testpod1[]"))
  (set "s11" (vv (create-testpod1-array r 3 (seq-uint32! g)) "testpod1[]"))
  (set "s12" (vv (create-testpod1-multidimarray r 2 2 (seq-uint32! g)) "testpod1[*]"))
  (set "s13" (vv (list (vector (fill-testpod1 r (seq-uint32! g)))) "testpod1[]{list}"))
  (set "s14" (vv (list (create-testpod1-array r 3 (seq-uint32! g))
                       (create-testpod1-array r 5 (seq-uint32! g)))
                 "testpod1[]{list}"))
  (set "s15" (vv (list (create-testpod1-multidimarray r 7 2 (seq-uint32! g))
                       (create-testpod1-multidimarray r 5 1 (seq-uint32! g)))
                 "testpod1[*]{list}"))
  (set "t1" (fill-transform r (seq-uint32! g)))
  (set "t2" (create-transform-array r 4 (seq-uint32! g)))
  (set "t3" (create-transform-multidimarray r 2 4 (seq-uint32! g)))
  (set "t4" (vv (create-transform-array r 10 (seq-uint32! g)) "transform[]"))
  (set "t5" (vv (create-transform-multidimarray r 6 5 (seq-uint32! g)) "transform[*]"))
  (set "t6" (list (fill-transform r (seq-uint32! g))))
  (set "t7" (list (create-transform-array r 4 (seq-uint32! g))
                  (create-transform-array r 4 (seq-uint32! g))))
  (set "t8" (list (create-transform-multidimarray r 2 4 (seq-uint32! g))
                  (create-transform-multidimarray r 2 4 (seq-uint32! g))))
  (set "t9" (vv (list (fill-transform r (seq-uint32! g))) "transform{list}"))
  (set "t10" (vv (list (create-transform-array r 3 (seq-uint32! g))
                       (create-transform-array r 5 (seq-uint32! g)))
                 "transform[]{list}"))
  (set "t11" (vv (list (create-transform-multidimarray r 7 2 (seq-uint32! g))
                       (create-transform-multidimarray r 5 1 (seq-uint32! g)))
                 "transform[*]{list}"))
  o)

(define (verify-teststruct3 v seed)
  (check-pred rr-struct? v)
  (define g (make-seqgen seed))
  (define (f n) (rr-struct-ref v n))
  (verify-testpod1 (f "s1") (seq-uint32! g))
  (define s2-seed (seq-uint32! g))
  (verify-testpod1-array (f "s2") (modulo s2-seed 17) s2-seed)
  (verify-testpod1-array (f "s3") 11 (seq-uint32! g))
  (define s4-seed (seq-uint32! g))
  (verify-testpod1-array (f "s4") (modulo s4-seed 16) s4-seed)
  (verify-testpod1-multidimarray (f "s5") 3 3 (seq-uint32! g))
  (define s6-seed (seq-uint32! g))
  (verify-testpod1-multidimarray (f "s6") (modulo s6-seed 6) (modulo s6-seed 3) s6-seed)
  (check-equal? (length (f "s7")) 1)
  (verify-testpod1 (car (f "s7")) (seq-uint32! g))
  (check-equal? (length (f "s8")) 2)
  (verify-testpod1-array (car (f "s8")) 2 (seq-uint32! g))
  (verify-testpod1-array (cadr (f "s8")) 4 (seq-uint32! g))
  (check-equal? (length (f "s9")) 2)
  (verify-testpod1-multidimarray (car (f "s9")) 2 3 (seq-uint32! g))
  (verify-testpod1-multidimarray (cadr (f "s9")) 4 5 (seq-uint32! g))
  ;; varvalue fields arrive with their runtime type: pod arrays are vectors
  (verify-testpod1 (vector-ref (f "s10") 0) (seq-uint32! g))
  (verify-testpod1-array (f "s11") 3 (seq-uint32! g))
  (verify-testpod1-multidimarray (f "s12") 2 2 (seq-uint32! g))
  (verify-testpod1 (vector-ref (car (f "s13")) 0) (seq-uint32! g))
  (check-equal? (length (f "s14")) 2)
  (verify-testpod1-array (car (f "s14")) 3 (seq-uint32! g))
  (verify-testpod1-array (cadr (f "s14")) 5 (seq-uint32! g))
  (check-equal? (length (f "s15")) 2)
  (verify-testpod1-multidimarray (car (f "s15")) 7 2 (seq-uint32! g))
  (verify-testpod1-multidimarray (cadr (f "s15")) 5 1 (seq-uint32! g))
  (verify-transform (f "t1") (seq-uint32! g))
  (verify-transform-array (f "t2") 4 (seq-uint32! g))
  (verify-transform-multidimarray (f "t3") 2 4 (seq-uint32! g))
  (verify-transform-array (f "t4") 10 (seq-uint32! g))
  (verify-transform-multidimarray (f "t5") 6 5 (seq-uint32! g))
  (check-equal? (length (f "t6")) 1)
  (verify-transform (car (f "t6")) (seq-uint32! g))
  (check-equal? (length (f "t7")) 2)
  (verify-transform-array (car (f "t7")) 4 (seq-uint32! g))
  (verify-transform-array (cadr (f "t7")) 4 (seq-uint32! g))
  (check-equal? (length (f "t8")) 2)
  (verify-transform-multidimarray (car (f "t8")) 2 4 (seq-uint32! g))
  (verify-transform-multidimarray (cadr (f "t8")) 2 4 (seq-uint32! g))
  (check-equal? (length (f "t9")) 1)
  (verify-transform (car (f "t9")) (seq-uint32! g))
  (check-equal? (length (f "t10")) 2)
  (verify-transform-array (car (f "t10")) 3 (seq-uint32! g))
  (verify-transform-array (cadr (f "t10")) 5 (seq-uint32! g))
  (check-equal? (length (f "t11")) 2)
  (verify-transform-multidimarray (car (f "t11")) 7 2 (seq-uint32! g))
  (verify-transform-multidimarray (cadr (f "t11")) 5 1 (seq-uint32! g)))
