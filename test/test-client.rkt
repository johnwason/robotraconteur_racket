#lang racket/base
;; Integration tests: Racket client against the Python reference service.
(require rackunit racket/list racket/string
         "../robotraconteur/main.rkt")

(define url (or (getenv "RR_TEST_URL")
                "rr+tcp://127.0.0.1:22222/?service=test"))

(define c (rr-connect url))
(printf "connected: ~a\n" c)

(test-case "service definitions and attributes"
  (check-true (hash-has-key? (rr-service-definitions c) "experimental.racket_test"))
  (check-equal? (rr-object-type c) "experimental.racket_test.TestObject")
  (check-equal? (hash-ref (rr-attributes c) "description") "racket test service"))

(test-case "primitive properties"
  (check-equal? (rr-get c "d1") 1.5)
  (rr-set! c "d1" 2.75)
  (check-equal? (rr-get c "d1") 2.75)
  (check-equal? (rr-get c "i1") -42)
  (rr-set! c "i1" 123456)
  (check-equal? (rr-get c "i1") 123456)
  (check-equal? (rr-get c "s1") "hello from python")
  (rr-set! c "s1" "héllo ünicode")
  (check-equal? (rr-get c "s1") "héllo ünicode")
  (check-equal? (rr-get c "b1") #t)
  (rr-set! c "b1" #f)
  (check-equal? (rr-get c "b1") #f)
  (check-equal? (rr-get c "c1") 1.0-2.0i)
  (rr-set! c "c1" 3.0+4.0i)
  (check-equal? (rr-get c "c1") 3.0+4.0i))

(test-case "array properties"
  (check-equal? (rr-get c "u8arr") (vector 1 2 3))
  (rr-set! c "u8arr" (vector 9 8 7 255))
  (check-equal? (rr-get c "u8arr") (vector 9 8 7 255))
  (check-equal? (rr-get c "darr") (vector 1.0 2.0 3.5))
  (rr-set! c "darr" '(0.5 0.25))
  (check-equal? (rr-get c "darr") (vector 0.5 0.25))
  (check-equal? (rr-get c "dfix") (vector 7.0 8.0 9.0))
  (check-exn exn:fail? (lambda () (rr-set! c "dfix" (vector 1.0 2.0))))
  (define md (rr-get c "md"))
  (check-equal? (rr-multidim-dims md) '(2 3))
  (check-equal? (rr-multidim-array md) (vector 0.0 1.0 2.0 3.0 4.0 5.0))
  (rr-set! c "md" (rr-multidim '(2 2) (vector 1.0 2.0 3.0 4.0)))
  (check-equal? (rr-get c "md") (rr-multidim '(2 2) (vector 1.0 2.0 3.0 4.0))))

(test-case "structures"
  (define st (rr-get c "st"))
  (check-equal? (rr-struct-type st) "experimental.racket_test.TestStruct")
  (check-equal? (rr-struct-ref st "d") 3.25)
  (check-equal? (rr-struct-ref st "darr") (vector 4.0 5.0))
  (check-equal? (rr-struct-ref st "s") "struct string")
  (check-equal? (rr-struct-ref st "imap") (hash "one" 1 "two" 2))
  (check-equal? (rr-struct-ref st "v") "var in struct")
  (define st2 (rr-new-structure c "TestStruct"))
  (rr-struct-set! st2 "d" -1.0)
  (rr-struct-set! st2 "s" "from racket")
  (rr-struct-set! st2 "imap" (hash "z" 26))
  (rr-struct-set! st2 "v" (vector 1.0 2.0))
  (rr-set! c "st" st2)
  (define st3 (rr-get c "st"))
  (check-equal? (rr-struct-ref st3 "d") -1.0)
  (check-equal? (rr-struct-ref st3 "s") "from racket")
  (check-equal? (rr-struct-ref st3 "darr") (vector))
  (check-equal? (rr-struct-ref st3 "imap") (hash "z" 26))
  (check-equal? (rr-struct-ref st3 "v") (vector 1.0 2.0))
  (rr-set! c "st" 'null)
  (check-equal? (rr-get c "st") 'null))

(test-case "maps and lists"
  (check-equal? (rr-get c "dmap") (hash "a" 1.0 "b" 2.0))
  (rr-set! c "dmap" (hash "q" 9.0))
  (check-equal? (rr-get c "dmap") (hash "q" 9.0))
  (check-equal? (rr-get c "smap") (hash 1 "x" 5 "y"))
  (rr-set! c "smap" (hash 7 "seven"))
  (check-equal? (rr-get c "smap") (hash 7 "seven"))
  (check-equal? (rr-get c "slist") '("p" "q" "r"))
  (rr-set! c "slist" '("a"))
  (check-equal? (rr-get c "slist") '("a")))

(test-case "varvalue"
  (check-equal? (rr-get c "var1") (vector 1 2 3))
  (rr-set! c "var1" "a string")
  (check-equal? (rr-get c "var1") "a string")
  (rr-set! c "var1" (rr-varvalue (vector 1 2) "int16[]"))
  (check-equal? (rr-get c "var1") (vector 1 2))
  (rr-set! c "var1" (hash "k" (list 1.0 "two")))
  (check-equal? (rr-get c "var1") (hash "k" (list (vector 1.0) "two"))))

(test-case "enum"
  (check-equal? (rr-get c "color") 16)
  (rr-set! c "color" 'green)
  (check-equal? (rr-get c "color") 2))

(test-case "pods"
  (define p (rr-get c "pod1"))
  (check-equal? (rr-struct-ref p "a") 1.25)
  (check-equal? (rr-struct-ref p "b") (vector 1 2 3))
  (rr-struct-set! p "a" 5.5)
  (rr-set! c "pod1" p)
  (check-equal? (rr-struct-ref (rr-get c "pod1") "a") 5.5)
  (define pa (rr-get c "podarr"))
  (check-equal? (vector-length pa) 2)
  (check-equal? (rr-struct-ref (vector-ref pa 1) "b") (vector 4 5 6))
  (define np (rr-new-structure c "TestPod"))
  (rr-struct-set! np "b" (vector 7 8 9))
  (rr-set! c "podarr" (vector np np np))
  (check-equal? (vector-length (rr-get c "podarr")) 3))

(test-case "namedarrays"
  (define v (rr-get c "vec"))
  (check-equal? (map (lambda (f) (rr-struct-ref v f)) '("x" "y" "z")) '(1.0 2.0 3.0))
  (rr-struct-set! v "z" 30.0)
  (rr-set! c "vec" v)
  (check-equal? (rr-struct-ref (rr-get c "vec") "z") 30.0)
  (define pose (rr-get c "pose"))
  (check-equal? (rr-struct-ref (rr-struct-ref pose "position") "x") 0.5)
  (check-equal? (rr-struct-ref pose "orientation") (vector 1.0 0.0 0.0 0.0))
  (rr-struct-set! (rr-struct-ref pose "position") "y" -4.0)
  (rr-set! c "poses" (vector pose pose))
  (define poses (rr-get c "poses"))
  (check-equal? (vector-length poses) 2)
  (check-equal? (rr-struct-ref (rr-struct-ref (vector-ref poses 1) "position") "y") -4.0))

(test-case "readonly property"
  (check-equal? (rr-get c "readonly_prop") 99.0)
  (check-exn exn:fail:robotraconteur? (lambda () (rr-set! c "readonly_prop" 1.0))))

(test-case "functions"
  (check-equal? (rr-call c "add" 1.0 2.5) 3.5)
  (check-equal? (rr-call c "concat" '("a" "b" "c")) "a-b-c")
  (define st (rr-call c "make_struct" 2.0 "abc"))
  (check-equal? (rr-struct-ref st "darr") (vector 2.0 4.0))
  (check-equal? (rr-struct-ref st "imap") (hash "len" 3))
  (check-equal? (rr-struct-ref st "v") 'null))

(test-case "remote exceptions"
  (define e (with-handlers ([exn:fail:robotraconteur? values])
              (rr-call c "raise_error")))
  (check-pred exn:fail:robotraconteur? e)
  (check-equal? (exn:fail:robotraconteur-error-name e) "RobotRaconteur.InvalidOperation")
  (check-true (string-contains? (exn-message e) "expected test error")))

(test-case "events"
  (define got (make-channel))
  (rr-add-event-listener! c "ev1" (lambda (msg val) (channel-put got (list msg val))))
  (rr-call c "fire_event" "event message")
  (check-equal? (sync/timeout 5 got) (list "event message" 12.5)))

(test-case "callbacks"
  (rr-set-callback! c "cb1" (lambda (a) (* a 10.0)))
  (check-equal? (rr-call c "call_my_callback" 4.0) 1040.0))

(test-case "generators"
  (check-equal? (rr-generator->list (rr-call c "count_to" 4)) '(1.0 2.0 3.0 4.0))
  (define g (rr-call c "count_to" 100))
  (check-equal? (rr-generator-next g) 1.0)
  (rr-generator-close g)
  (check-pred eof-object? (rr-generator-next g))
  (define acc (rr-call c "accumulate"))
  (check-equal? (rr-generator-next acc 1.0) 1.0)
  (check-equal? (rr-generator-next acc 2.5) 3.5)
  (rr-generator-close acc))

(test-case "objrefs"
  (define sub (rr-objref c "sub"))
  (check-equal? (rr-object-type sub) "experimental.racket_test.SubObj")
  (check-equal? (rr-get sub "name") "sub")
  (check-equal? (rr-call sub "add" 2.0 3.0) 5.0)
  (check-equal? (rr-get (rr-objref c "subs" 2) "name") "two")
  (check-equal? (rr-get (rr-objref c "named_subs" "a b") "name") "named a b"))

(test-case "wires"
  (define-values (v ts) (rr-wire-peek-in c "w_in"))
  (check-equal? (vector-length v) 2)
  (check-true (> (car ts) 1600000000))
  (define w (rr-wire-connect c "w_in"))
  (define v1 (rr-wire-wait-in-value w))
  (sleep 0.3)
  (define v2 (rr-wire-wait-in-value w))
  (check-true (> (vector-ref v2 0) (vector-ref v1 0)))
  (define got (make-channel))
  (rr-wire-add-listener! w (lambda (v ts) (channel-put got v)))
  (check-pred vector? (sync/timeout 2 got))
  (rr-wire-close w)
  (rr-wire-poke-out! c "w_out" 42.0)
  (define wo (rr-wire-connect c "w_out"))
  (rr-wire-set-out-value! wo 43.0)
  (sleep 0.2)
  (rr-wire-close wo))

(test-case "pipes"
  (define p (rr-pipe-connect c "p1"))
  (rr-pipe-send p (vector 1.0 2.0))
  (rr-pipe-send p (vector 5.0))
  (check-equal? (rr-pipe-receive p) (vector 2.0 4.0))
  (check-equal? (rr-pipe-receive p) (vector 10.0))
  (rr-pipe-close p))

(test-case "member errors"
  (check-exn exn:fail:robotraconteur? (lambda () (rr-get c "no_such_member")))
  (check-exn exn:fail? (lambda () (rr-call c "add" 1.0))))

(test-case "connection survives idle period (heartbeats)"
  (sleep 7)
  (check-equal? (rr-call c "add" 1.0 1.0) 2.0))

(test-case "close"
  (rr-close c)
  (check-exn exn:fail:robotraconteur? (lambda () (rr-get c "d1"))))
