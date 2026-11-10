#lang racket/base
;; Conversion between Racket values and Robot Raconteur message elements,
;; driven by service definition type information.
;;
;; Racket value conventions
;;   null                 'null
;;   numeric scalar       number (bool -> #t/#f, cdouble/csingle -> complex)
;;   numeric array        vector (lists are accepted when packing)
;;   multidim array       rr-multidim (dims = list, array = vector, column major)
;;   string               string
;;   struct/pod/namedarray rr-struct (type = qualified name, fields = mutable hash)
;;   pod/namedarray array vector of rr-struct
;;   enum                 integer (symbols/strings naming a value accepted when packing)
;;   map{int32}/{string}  hash
;;   list                 list
;;   varvalue             any of the above; use rr-varvalue to force a type

(require racket/list racket/string racket/match
         "message.rkt" "robdef.rkt")

(provide (struct-out rr-struct)
         (struct-out rr-multidim)
         (struct-out rr-varvalue)
         (struct-out type-registry)
         make-type-registry
         registry-add-def!
         resolve-type
         pack-elem
         unpack-elem
         new-structure
         rr-struct-ref
         rr-struct-set!)

(struct rr-struct (type fields)
  #:methods gen:custom-write
  [(define (write-proc s port mode)
     (fprintf port "#<rr-struct ~a" (rr-struct-type s))
     (for ([(k v) (in-hash (rr-struct-fields s))])
       (fprintf port " ~a=" k)
       (if mode (write v port) (display v port)))
     (write-string ">" port))])

(define (rr-struct-ref s f) (hash-ref (rr-struct-fields s) f))
(define (rr-struct-set! s f v) (hash-set! (rr-struct-fields s) f v))

(struct rr-multidim (dims array) #:transparent)

;; Explicitly typed varvalue, e.g. (rr-varvalue (vector 1 2) "int16[]")
(struct rr-varvalue (value type) #:transparent)

;; defs: hash service-name -> servicedef
(struct type-registry (defs))

(define (make-type-registry) (type-registry (make-hash)))
(define (registry-add-def! reg d) (hash-set! (type-registry-defs reg) (servicedef-name d) d))

;; ---------------------------------------------------------------------------
;; Name resolution

(define (split-qualified q)
  (define parts (string-split q "."))
  (values (string-join (drop-right parts 1) ".") (last parts)))

;; Resolve a (possibly unqualified) type name relative to service `ns`.
;; Returns (values qualified-name kind def) where kind is one of
;; 'struct 'pod 'namedarray 'object 'enum and def is the entrydef/enumdef.
(define (resolve-type reg ns name)
  (define defs (type-registry-defs reg))
  (define (lookup svc tname)
    (define d (hash-ref defs svc #f))
    (and d
         (cond
           [(hash-ref (servicedef-entries d) tname #f)
            => (lambda (e) (list (string-append svc "." tname) (entrydef-kind e) e))]
           [(hash-ref (servicedef-enums d) tname #f)
            => (lambda (e) (list (string-append svc "." tname) 'enum e))]
           [else #f])))
  (define result
    (cond
      [(string-contains? name ".")
       (define-values (svc tname) (split-qualified name))
       (lookup svc tname)]
      [else
       (define d (hash-ref defs ns #f))
       (or (lookup ns name)
           (and d (hash-ref (servicedef-usings d) name #f)
                (let-values ([(svc tname) (split-qualified (hash-ref (servicedef-usings d) name))])
                  (lookup svc tname))))]))
  (unless result
    (error 'robotraconteur "could not resolve type ~a in service ~a" name ns))
  (apply values result))

(define (qualified-ns q) (let-values ([(svc _) (split-qualified q)]) svc))

;; ---------------------------------------------------------------------------
;; Primitive helpers

(define (prim->dt s)
  (case s
    [(double) dt-double] [(single) dt-single] [(int8) dt-int8] [(uint8) dt-uint8]
    [(int16) dt-int16] [(uint16) dt-uint16] [(int32) dt-int32] [(uint32) dt-uint32]
    [(int64) dt-int64] [(uint64) dt-uint64] [(cdouble) dt-cdouble]
    [(csingle) dt-csingle] [(bool) dt-bool] [(string) dt-string]
    [else (error 'prim->dt "not a primitive: ~a" s)]))

(define (dt->prim t)
  (case t
    [(1) 'double] [(2) 'single] [(3) 'int8] [(4) 'uint8] [(5) 'int16] [(6) 'uint16]
    [(7) 'int32] [(8) 'uint32] [(9) 'int64] [(10) 'uint64] [(12) 'cdouble]
    [(13) 'csingle] [(14) 'bool] [(11) 'string]))

(define (->vector v)
  (cond [(vector? v) v]
        [(list? v) (list->vector v)]
        [else (error 'robotraconteur "expected a vector, got ~e" v)]))

(define (scalar-type td)
  (struct-copy typedef td [array #f] [dims '()] [varlen? #f] [container #f]))
(define (no-container td) (struct-copy typedef td [container #f]))

(define (null-value? v) (eq? v 'null))

(define (check-array-length td n)
  (when (and (eq? (typedef-array td) 'array) (pair? (typedef-dims td)))
    (define len (car (typedef-dims td)))
    (if (typedef-varlen? td)
        (when (> n len) (error 'robotraconteur "array too long (max ~a): ~a" len n))
        (unless (= n len) (error 'robotraconteur "array must have length ~a, got ~a" len n)))))

(define (vector-product l) (for/fold ([p 1]) ([x l]) (* p x)))

;; ---------------------------------------------------------------------------
;; Packing

;; Pack value v of type td into an element named `name`.
;; ns is the service definition namespace that td was declared in.
(define (pack-elem reg ns name td v)
  (define-values (t tn data) (pack-data reg ns td v))
  (elem name t tn "" data))

(define (number-name i) (number->string i))

(define (pack-data reg ns td v)
  (define base (typedef-base td))
  (cond
    [(null-value? v) (values dt-void "" #f)]
    ;; containers
    [(eq? (typedef-container td) 'map-int)
     (unless (hash? v) (error 'robotraconteur "expected a hash for map{int32}: ~e" v))
     (values dt-vector ""
             (for/list ([k (in-list (sort (hash-keys v) <))])
               (pack-elem reg ns (number-name k) (no-container td) (hash-ref v k))))]
    [(eq? (typedef-container td) 'map-string)
     (unless (hash? v) (error 'robotraconteur "expected a hash for map{string}: ~e" v))
     (values dt-dictionary ""
             (for/list ([k (in-list (sort (hash-keys v) string<?))])
               (pack-elem reg ns k (no-container td) (hash-ref v k))))]
    [(eq? (typedef-container td) 'list)
     (define l (if (vector? v) (vector->list v) v))
     (values dt-list ""
             (for/list ([x (in-list l)] [i (in-naturals)])
               (pack-elem reg ns (number-name i) (no-container td) x)))]
    [(eq? base 'varvalue) (pack-var reg ns v)]
    [(eq? base 'string)
     (unless (string? v) (error 'robotraconteur "expected a string: ~e" v))
     (values dt-string "" v)]
    [(numeric-primitive? base)
     (define dt (prim->dt base))
     (case (typedef-array td)
       [(#f) (when (or (vector? v) (list? v))
               (error 'robotraconteur "expected a scalar ~a, got ~e" base v))
             (values dt "" (vector v))]
       [(array) (define vv (->vector v))
                (check-array-length td (vector-length vv))
                (values dt "" vv)]
       [(multidim) (pack-multidim dt v)])]
    [(string? base)
     (define-values (qname kind def) (resolve-type reg ns base))
     (define def-ns (qualified-ns qname))
     (case kind
       [(enum)
        (define n (enum-value def v))
        (values dt-int32 "" (vector n))]
       [(struct)
        (unless (rr-struct? v) (error 'robotraconteur "expected rr-struct for ~a: ~e" qname v))
        (values dt-structure qname (pack-fields reg def-ns def v))]
       [(pod) (pack-pod reg td qname def v)]
       [(namedarray) (pack-namedarray reg td qname def v)]
       [else (error 'robotraconteur "cannot pack value of type ~a" qname)])]
    [else (error 'robotraconteur "cannot pack type ~a" base)]))

(define (pack-multidim dt v)
  (unless (rr-multidim? v) (error 'robotraconteur "expected rr-multidim: ~e" v))
  (define dims (rr-multidim-dims v))
  (define arr (->vector (rr-multidim-array v)))
  (unless (= (vector-product dims) (vector-length arr))
    (error 'robotraconteur "multidim array dims do not match data length"))
  (values dt-multidimarray ""
          (list (elem "dims" dt-uint32 "" "" (list->vector dims))
                (elem "array" dt "" "" arr))))

(define (enum-value def v)
  (cond
    [(exact-integer? v) v]
    [(or (symbol? v) (string? v))
     (define s (if (symbol? v) (symbol->string v) v))
     (cond [(assoc s (enumdef-values def)) => cdr]
           [else (error 'robotraconteur "unknown enum value ~a for ~a" s (enumdef-name def))])]
    [else (error 'robotraconteur "invalid enum value ~e" v)]))

(define (pack-fields reg ns def s)
  (for/list ([m (in-list (entrydef-members def))]
             #:when (eq? (member-kind m) 'field))
    (define f (member-name m))
    (pack-elem reg ns f (member-type m)
               (hash-ref (rr-struct-fields s) f
                         (lambda () (error 'robotraconteur "struct missing field ~a" f))))))

;; --- pods

(define (pod-elems-of v)
  (cond [(rr-struct? v) (vector v)]
        [else (->vector v)]))

(define (pack-pod-array reg qname def items)
  (define ns (qualified-ns qname))
  (values dt-pod-array qname
          (for/list ([s (in-vector items)] [i (in-naturals)])
            (elem (number-name i) dt-pod "" ""
                  (for/list ([m (in-list (entrydef-members def))]
                             #:when (eq? (member-kind m) 'field))
                    (pack-pod-field reg ns m (hash-ref (rr-struct-fields s) (member-name m))))))))

;; pod fields: numeric -> always array; nested pod -> pod_array; namedarray -> namedarray_array
(define (pack-pod-field reg ns m v)
  (define td (member-type m))
  (define base (typedef-base td))
  (cond
    [(numeric-primitive? base)
     (elem (member-name m) (prim->dt base) "" ""
           (if (typedef-array td) (->vector v) (vector v)))]
    [else
     (define-values (qname kind def) (resolve-type reg ns base))
     (case kind
       [(pod) (let-values ([(t tn d) (pack-pod-array reg qname def (pod-elems-of v))])
                (elem (member-name m) t tn "" d))]
       [(namedarray) (let-values ([(t tn d) (pack-namedarray-array reg qname def (pod-elems-of v))])
                       (elem (member-name m) t tn "" d))]
       [(enum) (elem (member-name m) dt-int32 "" "" (vector (enum-value def v)))]
       [else (error 'robotraconteur "invalid pod field type ~a" qname)])]))

(define (pack-pod reg td qname def v)
  (case (typedef-array td)
    [(#f) (pack-pod-array reg qname def (vector v))]
    [(array) (define items (->vector v))
             (check-array-length td (vector-length items))
             (pack-pod-array reg qname def items)]
    [(multidim)
     (define-values (t tn d) (pack-pod-array reg qname def (->vector (rr-multidim-array v))))
     (values dt-pod-multidimarray qname
             (list (elem "dims" dt-uint32 "" "" (list->vector (rr-multidim-dims v)))
                   (elem "array" t tn "" d)))]))

;; --- namedarrays

;; returns (values element-primitive-symbol element-count)
(define (namedarray-layout reg qname def)
  (define ns (qualified-ns qname))
  (for/fold ([prim #f] [count 0]) ([m (in-list (entrydef-members def))]
                                   #:when (eq? (member-kind m) 'field))
    (define td (member-type m))
    (define n (if (typedef-array td) (car (typedef-dims td)) 1))
    (cond
      [(numeric-primitive? (typedef-base td)) (values (typedef-base td) (+ count n))]
      [else
       (define-values (q2 k2 d2) (resolve-type reg ns (typedef-base td)))
       (define-values (p2 c2) (namedarray-layout reg q2 d2))
       (values p2 (+ count (* n c2)))])))

(define (namedarray->flat reg qname def s out)
  (define ns (qualified-ns qname))
  (for ([m (in-list (entrydef-members def))] #:when (eq? (member-kind m) 'field))
    (define td (member-type m))
    (define v (hash-ref (rr-struct-fields s) (member-name m)))
    (cond
      [(numeric-primitive? (typedef-base td))
       (if (typedef-array td)
           (for ([x (in-vector (->vector v))]) (set-box! out (cons x (unbox out))))
           (set-box! out (cons v (unbox out))))]
      [else
       (define-values (q2 k2 d2) (resolve-type reg ns (typedef-base td)))
       (if (typedef-array td)
           (for ([x (in-vector (->vector v))]) (namedarray->flat reg q2 d2 x out))
           (namedarray->flat reg q2 d2 v out))])))

(define (pack-namedarray-array reg qname def items)
  (define-values (prim count) (namedarray-layout reg qname def))
  (define out (box '()))
  (for ([s (in-vector items)]) (namedarray->flat reg qname def s out))
  (values dt-namedarray-array qname
          (list (elem "array" (prim->dt prim) "" "" (list->vector (reverse (unbox out)))))))

(define (pack-namedarray reg td qname def v)
  (case (typedef-array td)
    [(#f) (pack-namedarray-array reg qname def (vector v))]
    [(array) (define items (->vector v))
             (check-array-length td (vector-length items))
             (pack-namedarray-array reg qname def items)]
    [(multidim)
     (define-values (t tn d) (pack-namedarray-array reg qname def (->vector (rr-multidim-array v))))
     (values dt-namedarray-multidimarray qname
             (list (elem "dims" dt-uint32 "" "" (list->vector (rr-multidim-dims v)))
                   (elem "array" t tn "" d)))]))

;; --- varvalue

(define (infer-type v)
  (cond
    [(flonum? v) "double"]
    [(boolean? v) "bool"]
    [(exact-integer? v) (if (<= (- (expt 2 31)) v (sub1 (expt 2 31))) "int32" "int64")]
    [(and (number? v) (not (real? v))) "cdouble"]
    [(real? v) "double"]
    [(string? v) "string"]
    [(vector? v)
     (cond
       [(zero? (vector-length v)) "double[]"]
       [(for/and ([x (in-vector v)]) (flonum? x)) "double[]"]
       [(for/and ([x (in-vector v)]) (boolean? x)) "bool[]"]
       [(for/and ([x (in-vector v)]) (exact-integer? x)) "int32[]"]
       [(for/and ([x (in-vector v)]) (real? x)) "double[]"]
       [(for/and ([x (in-vector v)]) (number? x)) "cdouble[]"]
       [(for/and ([x (in-vector v)]) (rr-struct? x))
        (string-append (rr-struct-type (vector-ref v 0)) "[]")]
       [else (error 'robotraconteur "cannot infer varvalue type of ~e" v)])]
    [(rr-multidim? v)
     (string-append (string-trim (infer-type (->vector (rr-multidim-array v))) "[]") "[*]")]
    [(rr-struct? v) (rr-struct-type v)]
    [(hash? v)
     (cond [(for/and ([k (in-hash-keys v)]) (exact-integer? k)) "varvalue{int32}"]
           [(for/and ([k (in-hash-keys v)]) (string? k)) "varvalue{string}"]
           [else (error 'robotraconteur "map keys must be all int32 or all string")])]
    [(list? v) "varvalue{list}"]
    [else (error 'robotraconteur "cannot infer varvalue type of ~e" v)]))

(define (pack-var reg ns v)
  (cond
    [(null-value? v) (values dt-void "" #f)]
    [(rr-varvalue? v)
     (pack-data reg ns (parse-type (rr-varvalue-type v)) (rr-varvalue-value v))]
    [else (pack-data reg ns (parse-type (infer-type v)) v)]))

;; ---------------------------------------------------------------------------
;; Unpacking

;; td may be #f (unknown/varvalue): then unpacking is self-describing.
(define (unpack-elem reg ns td e)
  (define t (elem-type e))
  (define d (elem-data e))
  (define scalar? (and td (not (typedef-container td)) (not (typedef-array td))
                       (not (eq? (typedef-base td) 'varvalue))))
  (define child-td (and td (not (eq? (typedef-base td) 'varvalue)) (no-container td)))
  (cond
    [(= t dt-void) 'null]
    [(= t dt-string) d]
    [(numeric-dt? t)
     (cond
       [(and scalar? (= (vector-length d) 1)) (vector-ref d 0)]
       [else d])]
    [(= t dt-vector)
     (for/hash ([x (in-list d)])
       (values (string->number (elem-name x)) (unpack-elem reg ns child-td x)))]
    [(= t dt-dictionary)
     (for/hash ([x (in-list d)])
       (values (elem-name x) (unpack-elem reg ns child-td x)))]
    [(= t dt-list)
     (for/list ([x (in-list d)]) (unpack-elem reg ns child-td x))]
    [(= t dt-multidimarray)
     (rr-multidim (vector->list (elem-data (find-elem d "dims")))
                  (elem-data (find-elem d "array")))]
    [(= t dt-structure) (unpack-struct reg (elem-type-name e) d)]
    [(= t dt-pod-array)
     (define items (unpack-pod-array reg (elem-type-name e) d))
     (if (and scalar? (= (vector-length items) 1)) (vector-ref items 0) items)]
    [(= t dt-pod-multidimarray)
     (rr-multidim (vector->list (elem-data (find-elem d "dims")))
                  (let ([a (find-elem d "array")])
                    (unpack-pod-array reg (elem-type-name a) (elem-data a))))]
    [(= t dt-namedarray-array)
     (define items (unpack-namedarray-array reg (elem-type-name e) d))
     (if (and scalar? (= (vector-length items) 1)) (vector-ref items 0) items)]
    [(= t dt-namedarray-multidimarray)
     (rr-multidim (vector->list (elem-data (find-elem d "dims")))
                  (let ([a (find-elem d "array")])
                    (unpack-namedarray-array reg (elem-type-name a) (elem-data a))))]
    [else (error 'robotraconteur "cannot unpack data type ~a" t)]))

(define (field-members def)
  (filter (lambda (m) (eq? (member-kind m) 'field)) (entrydef-members def)))

(define (unpack-struct reg qname elems)
  (define-values (q kind def) (resolve-type reg "" qname))
  (define ns (qualified-ns q))
  (define h (make-hash))
  (for ([m (in-list (field-members def))])
    (define e (find-elem* elems (member-name m)))
    (hash-set! h (member-name m) (if e (unpack-elem reg ns (member-type m) e) 'null)))
  (rr-struct q h))

(define (unpack-pod-array reg qname elems)
  (define-values (q kind def) (resolve-type reg "" qname))
  (define ns (qualified-ns q))
  (for/vector ([pe (in-list elems)])
    (define fields (elem-data pe))
    (define h (make-hash))
    (for ([m (in-list (field-members def))])
      (define td (member-type m))
      (define fe (find-elem fields (member-name m)))
      (define v
        (cond
          [(numeric-dt? (elem-type fe))
           (if (typedef-array td) (elem-data fe) (vector-ref (elem-data fe) 0))]
          [(= (elem-type fe) dt-pod-array)
           (define items (unpack-pod-array reg (elem-type-name fe) (elem-data fe)))
           (if (typedef-array td) items (vector-ref items 0))]
          [(= (elem-type fe) dt-namedarray-array)
           (define items (unpack-namedarray-array reg (elem-type-name fe) (elem-data fe)))
           (if (typedef-array td) items (vector-ref items 0))]
          [else (error 'robotraconteur "invalid pod field")]))
      (hash-set! h (member-name m) v))
    (rr-struct q h)))

;; flat: vector, pos: box index -> rr-struct
(define (flat->namedarray reg qname def flat pos)
  (define ns (qualified-ns qname))
  (define (next!) (begin0 (vector-ref flat (unbox pos)) (set-box! pos (add1 (unbox pos)))))
  (define h (make-hash))
  (for ([m (in-list (field-members def))])
    (define td (member-type m))
    (define n (if (typedef-array td) (car (typedef-dims td)) #f))
    (define (one)
      (if (numeric-primitive? (typedef-base td))
          (next!)
          (let-values ([(q2 k2 d2) (resolve-type reg ns (typedef-base td))])
            (flat->namedarray reg q2 d2 flat pos))))
    (hash-set! h (member-name m)
               (if n (for/vector ([i (in-range n)]) (one)) (one))))
  (rr-struct qname h))

(define (unpack-namedarray-array reg qname elems)
  (define-values (q kind def) (resolve-type reg "" qname))
  (define-values (prim count) (namedarray-layout reg q def))
  (define flat (elem-data (find-elem elems "array")))
  (define pos (box 0))
  (for/vector ([i (in-range (quotient (vector-length flat) count))])
    (flat->namedarray reg q def flat pos)))

;; ---------------------------------------------------------------------------
;; Construct a new structure with default field values

(define (default-value reg ns td)
  (define base (typedef-base td))
  (define (zero-of b)
    (case b
      [(double single) 0.0] [(cdouble csingle) 0.0+0.0i] [(bool) #f] [else 0]))
  (cond
    [(typedef-container td) 'null]
    [(eq? base 'string) ""]
    [(eq? base 'varvalue) 'null]
    [(numeric-primitive? base)
     (case (typedef-array td)
       [(#f) (zero-of base)]
       [(array) (if (typedef-varlen? td)
                    (vector)
                    (make-vector (car (typedef-dims td)) (zero-of base)))]
       [(multidim) (if (typedef-varlen? td)
                       (rr-multidim '(0) (vector))
                       (rr-multidim (typedef-dims td)
                                    (make-vector (vector-product (typedef-dims td))
                                                 (zero-of base))))])]
    [else
     (define-values (q kind def) (resolve-type reg ns base))
     (case kind
       [(enum) (cdr (car (enumdef-values def)))]
       [(struct) 'null]
       [(pod namedarray)
        (case (typedef-array td)
          [(#f) (new-structure reg q)]
          [(array) (if (typedef-varlen? td)
                       (vector)
                       (for/vector ([i (in-range (car (typedef-dims td)))])
                         (new-structure reg q)))]
          [else 'null])]
       [else 'null])]))

(define (new-structure reg qname)
  (define-values (q kind def) (resolve-type reg "" qname))
  (unless (memq kind '(struct pod namedarray))
    (error 'robotraconteur "~a is not a struct, pod or namedarray" qname))
  (define ns (qualified-ns q))
  (rr-struct q (make-hash
                (for/list ([m (in-list (field-members def))])
                  (cons (member-name m) (default-value reg ns (member-type m)))))))
