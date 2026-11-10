#lang racket/base
;; Access to the Robot Raconteur C++ test server for the ServiceTest suites.
;;
;; By default the server runs in-process: librobotraconteur_test_server_lib is
;; loaded through the FFI (path from RR_TEST_SERVER_LIB, or the default
;; build/rr-cpp location produced by build_cpp_test_server.sh).
;;
;; If ROBOTRACONTEUR_TEST_SERVER_URL is set (e.g. "rr+tcp://localhost:22222"),
;; an external server such as robotraconteur_test_server is used instead, the
;; same convention as the C++ and Python test harnesses.

(require ffi/unsafe racket/runtime-path racket/string)

(provide test-server-start!
         test-server-url
         test-server-stop!)

(define-runtime-path default-lib
  "../../build/rr-cpp/test/out/lib/librobotraconteur_test_server_lib.so")

(define external-url (getenv "ROBOTRACONTEUR_TEST_SERVER_URL"))

(define lib
  (and (not external-url)
       (ffi-lib (or (getenv "RR_TEST_SERVER_LIB") default-lib))))

(define (lib-fun name type) (get-ffi-obj name lib type))

(define started? #f)

(define (test-server-start! [nodename "racket_test_server"])
  (unless (or external-url started?)
    (define start (lib-fun "robotraconteur_test_server_lib_start"
                           (_fun _bytes _uint32 -> _int32)))
    (define b (string->bytes/utf-8 nodename))
    (unless (zero? (start b (bytes-length b)))
      (error 'test-server-start! "robotraconteur_test_server_lib_start failed"))
    (set! started? #t)))

(define (test-server-url service)
  (cond
    [external-url
     (string-append external-url (if (string-contains? external-url "?") "&" "?")
                    "service=" service)]
    [else
     (test-server-start!)
     (define get-url (lib-fun "robotraconteur_test_server_lib_get_service_url"
                              (_fun _bytes _uint32 _bytes (len : (_ptr io _uint32))
                                    -> (r : _int32) -> (values r len))))
     (define svc (string->bytes/utf-8 service))
     (define buf (make-bytes 1024 0))
     ;; the library strcpy's the URL, including its NUL terminator
     (define-values (r len) (get-url svc (bytes-length svc) buf (sub1 (bytes-length buf))))
     (unless (zero? r) (error 'test-server-url "could not get URL for service ~a" service))
     (bytes->string/utf-8 (subbytes buf 0 len))]))

(define (test-server-stop!)
  (when started?
    (define shutdown (lib-fun "robotraconteur_test_server_lib_shutdown" (_fun -> _int32)))
    (shutdown)
    (set! started? #f)))
