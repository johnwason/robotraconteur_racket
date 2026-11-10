#lang racket/base
;; Minimal Robot Raconteur service definition (.robdef) parser.
;; It extracts just enough type information for a dynamic client to pack and
;; unpack values: structs, pods, namedarrays, enums, objects and their members.

(require racket/string racket/list racket/match)

(provide (struct-out servicedef)
         (struct-out typedef)
         (struct-out member)
         (struct-out entrydef)
         (struct-out enumdef)
         parse-robdef
         parse-type
         primitive-type?
         numeric-primitive?)

;; name: string ; imports: list of string ; usings: hash alias -> qualified name
;; entries: hash name -> entrydef ; enums: hash name -> enumdef
;; exceptions: list of string ; source: original text
(struct servicedef (name imports usings entries enums exceptions source) #:transparent)

;; kind: 'struct 'pod 'namedarray 'object
;; members: list of member (fields for struct/pod/namedarray)
(struct entrydef (kind name members implements) #:transparent)

;; kind: 'field 'property 'function 'event 'objref 'pipe 'callback 'wire 'memory
;; type: typedef (return type for function/callback, #f for event)
;; params: list of (cons name typedef) for function/event/callback, else '()
;; modifiers: list of string
(struct member (kind name type params modifiers) #:transparent)

;; Type descriptor.
;; base:      symbol for primitive types ('double 'int32 'string 'varvalue ...)
;;            or a string for named types (possibly qualified)
;; array:     #f | 'array | 'multidim
;; dims:      list of dimension lengths (empty when variable), only for arrays
;; varlen?:   #t if the array length is variable ("[]", "[N-]" or "[*]")
;; container: #f | 'map-int | 'map-string | 'list | 'generator
(struct typedef (base array dims varlen? container) #:transparent)

;; values: list of (cons name integer)
(struct enumdef (name values) #:transparent)

(define primitive-names
  '("double" "single" "int8" "uint8" "int16" "uint16" "int32" "uint32"
    "int64" "uint64" "string" "cdouble" "csingle" "bool" "varvalue" "varobject"
    "void"))

(define (primitive-name? s) (and (memf (lambda (x) (equal? x s)) primitive-names) #t))
(define (primitive-type? s) (and (symbol? s) (primitive-name? (symbol->string s)) #t))
(define (numeric-primitive? s)
  (and (symbol? s) (memq s '(double single int8 uint8 int16 uint16 int32 uint32
                              int64 uint64 cdouble csingle bool))
       #t))

;; ---------------------------------------------------------------------------
;; Type parsing

(define type-rx #px"^([A-Za-z_][A-Za-z0-9_.]*)(\\[[^\\]]*\\])?(\\{[^}]*\\})?$")

(define (parse-type str)
  (define s (string-trim str))
  (match (regexp-match type-rx s)
    [#f (error 'parse-type "invalid type: ~a" s)]
    [(list _ base arr cont)
     (define b (if (primitive-name? base) (string->symbol base) base))
     (define-values (array dims varlen?)
       (cond
         [(not arr) (values #f '() #f)]
         [else
          (define inner (string-trim (substring arr 1 (sub1 (string-length arr)))))
          (cond
            [(equal? inner "") (values 'array '() #t)]
            [(equal? inner "*") (values 'multidim '() #t)]
            [(string-contains? inner ",")
             (values 'multidim
                     (map (lambda (x) (string->number (string-trim x)))
                          (string-split inner ","))
                     #f)]
            [(regexp-match #px"^(\\d+)-$" inner)
             => (lambda (m) (values 'array (list (string->number (cadr m))) #t))]
            [else (values 'array (list (string->number inner)) #f)])]))
     (define container
       (and cont
            (match (string-trim (substring cont 1 (sub1 (string-length cont))))
              ["int32" 'map-int]
              ["string" 'map-string]
              ["list" 'list]
              ["generator" 'generator]
              [c (error 'parse-type "invalid container: ~a" c)])))
     (typedef b array dims varlen? container)]))

;; ---------------------------------------------------------------------------
;; Line handling

(define (strip-comment line)
  ;; '#' starts a comment unless inside a string literal (constants)
  (let loop ([i 0] [in-str #f])
    (cond
      [(>= i (string-length line)) line]
      [(char=? (string-ref line i) #\") (loop (add1 i) (not in-str))]
      [(and (not in-str) (char=? (string-ref line i) #\#)) (substring line 0 i)]
      [else (loop (add1 i) in-str)])))

;; split "a, b[2,3] c, d" on top-level commas
(define (split-top-commas s)
  (let loop ([i 0] [depth 0] [start 0] [acc '()])
    (cond
      [(>= i (string-length s))
       (reverse (cons (substring s start) acc))]
      [else
       (define c (string-ref s i))
       (cond
         [(memv c '(#\[ #\{ #\()) (loop (add1 i) (add1 depth) start acc)]
         [(memv c '(#\] #\} #\))) (loop (add1 i) (sub1 depth) start acc)]
         [(and (char=? c #\,) (= depth 0))
          (loop (add1 i) depth (add1 i) (cons (substring s start i) acc))]
         [else (loop (add1 i) depth start acc)])])))

;; "[readonly, nolock]" trailing modifiers (must be separated by whitespace,
;; otherwise it is an array type such as "double[]")
(define (split-modifiers s)
  (match (regexp-match #px"^(.*\\S)\\s+\\[([^\\]]*)\\]\\s*$" s)
    [(list _ body mods) (values body (map string-trim (string-split mods ",")))]
    [_ (values s '())]))

(define (parse-params s)
  (define t (string-trim s))
  (if (equal? t "")
      '()
      (for/list ([p (in-list (split-top-commas t))])
        (match (regexp-match #px"^\\s*(\\S+)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*$" p)
          [(list _ ty nm) (cons nm (parse-type ty))]
          [_ (error 'parse-robdef "invalid parameter: ~a" p)]))))

(define (parse-member line)
  (define-values (body mods) (split-modifiers line))
  (match (regexp-match #px"^(\\w+)\\s+(.*)$" body)
    [(list _ kind rest)
     (case kind
       [("field" "property" "pipe" "wire" "memory" "objref")
        (match (regexp-match #px"^(\\S+)\\s+([A-Za-z_][A-Za-z0-9_]*)$" (string-trim rest))
          [(list _ ty nm) (member (string->symbol kind) nm (parse-type ty) '() mods)]
          [_ (error 'parse-robdef "invalid member: ~a" line)])]
       [("function" "callback")
        (match (regexp-match #px"^(\\S+)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\((.*)\\)$" (string-trim rest))
          [(list _ ty nm ps)
           (member (string->symbol kind) nm (parse-type ty) (parse-params ps) mods)]
          [_ (error 'parse-robdef "invalid member: ~a" line)])]
       [("event")
        (match (regexp-match #px"^([A-Za-z_][A-Za-z0-9_]*)\\s*\\((.*)\\)$" (string-trim rest))
          [(list _ nm ps) (member 'event nm #f (parse-params ps) mods)]
          [_ (error 'parse-robdef "invalid member: ~a" line)])]
       [else #f])]
    [_ #f]))

(define (parse-enum-values text)
  (define-values (vals _)
    (for/fold ([acc '()] [next 0])
              ([part (in-list (string-split text ","))]
               #:unless (equal? (string-trim part) ""))
      (match (regexp-match #px"^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(?:=\\s*([-+]?(?:0x[0-9A-Fa-f]+|\\d+)))?\\s*$" part)
        [(list _ nm #f) (values (cons (cons nm next) acc) (add1 next))]
        [(list _ nm v)
         (define n (if (regexp-match? #px"0x" v)
                       (let ([neg (string-prefix? v "-")])
                         (* (if neg -1 1)
                            (string->number (cadr (regexp-match #px"0x([0-9A-Fa-f]+)" v)) 16)))
                       (string->number v)))
         (values (cons (cons nm n) acc) (add1 n))]
        [_ (error 'parse-robdef "invalid enum value: ~a" part)])))
  (reverse vals))

;; ---------------------------------------------------------------------------
;; Top level

(define (parse-robdef text)
  (define lines
    (for/list ([l (in-list (string-split text "\n"))])
      (string-trim (strip-comment l))))
  (define name #f)
  (define imports '())
  (define usings (make-hash))
  (define entries (make-hash))
  (define enums (make-hash))
  (define exceptions '())
  (let loop ([ls lines])
    (unless (null? ls)
      (define l (car ls))
      (cond
        [(equal? l "") (loop (cdr ls))]
        [(regexp-match #px"^service\\s+(\\S+)$" l)
         => (lambda (m) (set! name (cadr m)) (loop (cdr ls)))]
        [(regexp-match #px"^import\\s+(\\S+)$" l)
         => (lambda (m) (set! imports (append imports (list (cadr m)))) (loop (cdr ls)))]
        [(regexp-match #px"^using\\s+(\\S+)(?:\\s+as\\s+(\\S+))?$" l)
         => (lambda (m)
              (define q (cadr m))
              (define alias (or (caddr m) (last (string-split q "."))))
              (hash-set! usings alias q)
              (loop (cdr ls)))]
        [(regexp-match #px"^exception\\s+(\\S+)$" l)
         => (lambda (m) (set! exceptions (cons (cadr m) exceptions)) (loop (cdr ls)))]
        [(regexp-match #px"^enum\\s+(\\S+)$" l)
         => (lambda (m)
              ;; collect until "end"
              (define-values (body rest)
                (splitf-at (cdr ls) (lambda (x) (not (regexp-match? #px"^end(\\s+enum)?$" x)))))
              (hash-set! enums (cadr m)
                         (enumdef (cadr m) (parse-enum-values (string-join body ","))))
              (loop (if (null? rest) rest (cdr rest))))]
        [(regexp-match #px"^(struct|pod|namedarray|object)\\s+(\\S+)$" l)
         => (lambda (m)
              (define kind (string->symbol (cadr m)))
              (define-values (body rest)
                (splitf-at (cdr ls)
                           (lambda (x) (not (regexp-match? #px"^end(\\s+\\w+)?$" x)))))
              (define implements
                (for/list ([b (in-list body)]
                           #:when (regexp-match? #px"^implements\\s" b))
                  (cadr (regexp-match #px"^implements\\s+(\\S+)" b))))
              (define members
                (for*/list ([b (in-list body)]
                            #:unless (equal? b "")
                            [mm (in-value (parse-member b))]
                            #:when mm)
                  mm))
              (hash-set! entries (caddr m) (entrydef kind (caddr m) members implements))
              (loop (if (null? rest) rest (cdr rest))))]
        [else (loop (cdr ls))])))
  (unless name (error 'parse-robdef "service definition missing service name"))
  (servicedef name imports usings entries enums (reverse exceptions) text))
