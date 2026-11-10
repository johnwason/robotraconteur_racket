#lang racket/base
;; Robot Raconteur node TLS (the TLS used by rrs+tcp).
;;
;; After a STARTTLS exchange inside the Robot Raconteur stream, the client
;; runs an ordinary TLS handshake on the same TCP connection, but checks the
;; server's certificate with Robot Raconteur's own rules, matching the C++
;; core (OpenSSLAuthContext.cpp):
;;
;;  - the chain must lead to a trusted root: by default the two Robot
;;    Raconteur node roots (rootca.rkt), not the system web PKI;
;;  - every certificate must carry the critical Robot Raconteur extension for
;;    its position: root 1.3.6.1.4.1.45455.1.1.3.1, intermediate ...3.2,
;;    node ...3.3. OpenSSL reports these as "unhandled critical extension",
;;    which is accepted. Any other critical extension, apart from the
;;    standard key usage, key identifier, basic constraints and policy
;;    extensions, fails verification;
;;  - the node certificate's subject must be exactly
;;    "/CN=Robot Raconteur Node {nodeid}" for the NodeID the server named in
;;    its STARTTLS reply.
;;
;; Racket's openssl library does not expose verify callbacks, so this module
;; drives libssl through the FFI (using the libraries the openssl collection
;; already loads), with memory BIOs pumped over the existing TCP ports.

(require ffi/unsafe ffi/unsafe/define racket/string net/base64
         openssl/libssl openssl/libcrypto
         "rootca.rkt")

(provide rr-make-node-tls-context
         rr-node-tls-context?
         tls-connect-ports)

;; a missing OpenSSL only fails when an rrs+tcp context is made
(define-ffi-definer define-ssl libssl #:default-make-fail make-not-available)
(define-ffi-definer define-crypto libcrypto #:default-make-fail make-not-available)

;; --- libssl / libcrypto

(define _verify-cb (_fun _int _pointer -> _int))

(define-ssl TLS_client_method (_fun -> _pointer))
(define-ssl SSL_CTX_new (_fun _pointer -> _pointer))
(define-ssl SSL_CTX_free (_fun _pointer -> _void))
(define-ssl SSL_CTX_ctrl (_fun _pointer _int _long _pointer -> _long))
(define-ssl SSL_CTX_set_verify (_fun _pointer _int _verify-cb -> _void))
(define-ssl SSL_CTX_get_cert_store (_fun _pointer -> _pointer))
(define-ssl SSL_new (_fun _pointer -> _pointer))
(define-ssl SSL_free (_fun _pointer -> _void))
(define-ssl SSL_set_bio (_fun _pointer _pointer _pointer -> _void))
(define-ssl SSL_set_connect_state (_fun _pointer -> _void))
(define-ssl SSL_connect (_fun _pointer -> _int))
(define-ssl SSL_read (_fun _pointer _pointer _int -> _int))
(define-ssl SSL_write (_fun _pointer _pointer _int -> _int))
(define-ssl SSL_get_error (_fun _pointer _int -> _int))
(define-ssl SSL_shutdown (_fun _pointer -> _int))
(define-ssl SSL_get_verify_result (_fun _pointer -> _long))
;; OpenSSL 3 renamed SSL_get_peer_certificate (now a macro) to SSL_get1_peer_certificate
(define-ssl SSL_get1_peer_certificate (_fun _pointer -> _pointer)
  #:fail (lambda () (get-ffi-obj "SSL_get_peer_certificate" libssl (_fun _pointer -> _pointer))))

(define-crypto X509_STORE_add_cert (_fun _pointer _pointer -> _int))
(define-crypto d2i_X509 (_fun _pointer (_ptr i _pointer) _long -> _pointer))
(define-crypto X509_free (_fun _pointer -> _void))
(define-crypto X509_get_subject_name (_fun _pointer -> _pointer))
(define-crypto X509_get_issuer_name (_fun _pointer -> _pointer))
(define-crypto X509_NAME_cmp (_fun _pointer _pointer -> _int))
(define-crypto X509_NAME_oneline (_fun _pointer _bytes _int -> _pointer))
(define-crypto X509_get_ext_count (_fun _pointer -> _int))
(define-crypto X509_get_ext (_fun _pointer _int -> _pointer))
(define-crypto X509_EXTENSION_get_critical (_fun _pointer -> _int))
(define-crypto X509_EXTENSION_get_object (_fun _pointer -> _pointer))
(define-crypto OBJ_obj2txt (_fun _bytes _int _pointer _int -> _int))
(define-crypto X509_STORE_CTX_get_error (_fun _pointer -> _int))
(define-crypto X509_STORE_CTX_get_error_depth (_fun _pointer -> _int))
(define-crypto X509_STORE_CTX_get_current_cert (_fun _pointer -> _pointer))
(define-crypto BIO_s_mem (_fun -> _pointer))
(define-crypto BIO_new (_fun _pointer -> _pointer))
(define-crypto BIO_read (_fun _pointer _bytes _int -> _int))
(define-crypto BIO_write (_fun _pointer _bytes _int -> _int))
(define-crypto BIO_ctrl_pending (_fun _pointer -> _size))
(define-crypto ERR_get_error (_fun -> _ulong))
(define-crypto ERR_clear_error (_fun -> _void))
(define-crypto ERR_error_string_n (_fun _ulong _bytes _size -> _void))

(define SSL_VERIFY_PEER 1)
(define SSL_CTRL_SET_MIN_PROTO_VERSION 123)
(define TLS1_2_VERSION #x0303)
(define SSL_ERROR_WANT_READ 2)
(define SSL_ERROR_WANT_WRITE 3)
(define X509_V_OK 0)
(define X509_V_ERR_UNHANDLED_CRITICAL_EXTENSION 34)

;; --- certificate checks (OpenSSLSupport::verify_callback in the C++ core)

(define rr-oid "1.3.6.1.4.1.45455.1.1.3")
;; key usage, subject key id, basic constraints, authority key id, policies
(define standard-critical-oids '("2.5.29.15" "2.5.29.14" "2.5.29.19" "2.5.29.35" "2.5.29.32"))

(define (c-string b)
  (define n (let loop ([i 0]) (if (or (= i (bytes-length b)) (zero? (bytes-ref b i))) i (loop (add1 i)))))
  (bytes->string/utf-8 (subbytes b 0 n) #\?))

(define (oid-text obj)
  (define buf (make-bytes 128 0))
  (OBJ_obj2txt buf 128 obj 1)
  (c-string buf))

(define (name-text name)
  (define buf (make-bytes 512 0))
  (X509_NAME_oneline name buf 512)
  (c-string buf))

;; #t when every critical extension is standard or is the Robot Raconteur
;; extension for this position in the chain, and that extension is present.
(define (rr-extensions-ok? cert expected-oid)
  (let loop ([i 0] [found? #f])
    (cond
      [(= i (X509_get_ext_count cert)) found?]
      [else
       (define e (X509_get_ext cert i))
       (cond
         [(not e) #f]
         [(zero? (X509_EXTENSION_get_critical e)) (loop (add1 i) found?)]
         [else
          (define oid (oid-text (X509_EXTENSION_get_object e)))
          (cond
            [(member oid standard-critical-oids) (loop (add1 i) found?)]
            [(equal? oid expected-oid) (loop (add1 i) #t)]
            [else #f])])])))

(define (verify-callback preverified store-ctx)
  ;; must not raise into OpenSSL
  (with-handlers ([(lambda (e) #t) (lambda (e) 0)])
    (define err (X509_STORE_CTX_get_error store-ctx))
    (define cert (X509_STORE_CTX_get_current_cert store-ctx))
    (cond
      [(and (not (= err X509_V_OK)) (not (= err X509_V_ERR_UNHANDLED_CRITICAL_EXTENSION))) 0]
      [(not cert) 0]
      [else
       (define root? (zero? (X509_NAME_cmp (X509_get_subject_name cert) (X509_get_issuer_name cert))))
       (define depth (X509_STORE_CTX_get_error_depth store-ctx))
       (define expected
         (string-append rr-oid (cond [root? ".1"] [(zero? depth) ".3"] [else ".2"])))
       (if (rr-extensions-ok? cert expected) 1 0)])))

;; --- contexts

(struct rr-node-tls-context (ptr))

(define (pem->der-list text)
  (for/list ([m (regexp-match* #px"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----"
                               text #:match-select cadr)])
    (base64-decode (string->bytes/utf-8 (regexp-replace* #px"\\s+" m "")))))

(define (add-cert! store der who)
  (define p (malloc (bytes-length der) 'raw))
  (memcpy p der (bytes-length der))
  (define x (d2i_X509 #f p (bytes-length der)))
  (free p)
  (unless x (error who "could not parse certificate"))
  (X509_STORE_add_cert store x)
  (X509_free x))

;; A client context for rrs+tcp. Trusts the Robot Raconteur node roots unless
;; #:default-roots? is #f, plus the certificates in each PEM file in
;; #:extra-roots (as ROBOTRACONTEUR_SSL_CERT_FILE does for the C++ core).
(define (rr-make-node-tls-context #:extra-roots [extra-roots '()]
                                  #:default-roots? [default-roots? #t])
  (unless (and libssl libcrypto)
    (error 'rr-make-node-tls-context "OpenSSL is not available"))
  (define ctx (SSL_CTX_new (TLS_client_method)))
  (unless ctx (error 'rr-make-node-tls-context "SSL_CTX_new failed"))
  (SSL_CTX_ctrl ctx SSL_CTRL_SET_MIN_PROTO_VERSION TLS1_2_VERSION #f)
  (SSL_CTX_set_verify ctx SSL_VERIFY_PEER verify-callback)
  (define store (SSL_CTX_get_cert_store ctx))
  (when default-roots?
    (for* ([pem (in-list robotraconteur-root-certificates)]
           [der (in-list (pem->der-list pem))])
      (add-cert! store der 'rr-make-node-tls-context)))
  (for ([f (in-list extra-roots)])
    (define ders (pem->der-list (call-with-input-file f (lambda (in) (read-string (* 16 1024 1024) in)))))
    (when (null? ders) (error 'rr-make-node-tls-context "no certificates in ~a" f))
    (for ([der (in-list ders)]) (add-cert! store der 'rr-make-node-tls-context)))
  (define c (rr-node-tls-context ctx))
  (register-finalizer c (lambda (c) (SSL_CTX_free (rr-node-tls-context-ptr c))))
  c)

;; --- TLS over existing ports

(define (openssl-errors)
  (define msgs
    (let loop ([acc '()])
      (define e (ERR_get_error))
      (if (zero? e)
          (reverse acc)
          (let ([buf (make-bytes 256 0)])
            (ERR_error_string_n e buf 256)
            (loop (cons (c-string buf) acc))))))
  (if (null? msgs) "unknown TLS error" (string-join msgs "; ")))

(define bufsize 16384)

;; Runs the client handshake over raw-in/raw-out (already past STARTTLS) and
;; checks that the node certificate's subject is expected-subject.
;; Returns (values in out) carrying the decrypted stream. Closing `out`
;; shuts TLS down and closes the raw ports. Raises exn:fail on failure.
(define (tls-connect-ports context raw-in raw-out expected-subject)
  (define ssl (SSL_new (rr-node-tls-context-ptr context)))
  (unless ssl (error 'rrs+tcp "SSL_new failed"))
  (define rbio (BIO_new (BIO_s_mem)))
  (define wbio (BIO_new (BIO_s_mem)))
  (SSL_set_bio ssl rbio wbio)
  (SSL_set_connect_state ssl)
  ;; buffers handed to SSL_read/SSL_write must not move during the call
  (define rbuf (malloc bufsize 'raw))
  (define wbuf (malloc bufsize 'raw))
  (define lock (make-semaphore 1))
  (define closed? #f)

  ;; with lock held: send whatever OpenSSL produced
  (define (drain!)
    (let loop ()
      (define n (BIO_ctrl_pending wbio))
      (when (> n 0)
        (define b (make-bytes (min n bufsize)))
        (define r (BIO_read wbio b (bytes-length b)))
        (when (> r 0)
          (write-bytes b raw-out 0 r)
          (loop))))
    (flush-output raw-out))

  ;; without lock: read from the socket into OpenSSL; #f at end of stream
  (define (feed!)
    (define b (make-bytes bufsize))
    (define n (read-bytes-avail! b raw-in))
    (cond
      [(eof-object? n) #f]
      [else (call-with-semaphore lock (lambda () (unless closed? (BIO_write rbio b n))))
            (not closed?)]))

  (define (close-all!)
    (call-with-semaphore
     lock
     (lambda ()
       (unless closed?
         (set! closed? #t)
         (with-handlers ([exn:fail? void])
           (SSL_shutdown ssl)
           (drain!))
         (SSL_free ssl) ; frees the BIOs
         (free rbuf)
         (free wbuf))))
    (with-handlers ([exn:fail? void]) (close-output-port raw-out))
    (with-handlers ([exn:fail? void]) (close-input-port raw-in)))

  (define (fail msg)
    (close-all!)
    (error 'rrs+tcp "~a" msg))

  ;; handshake
  (let loop ()
    (define r+e
      (call-with-semaphore
       lock
       (lambda ()
         (ERR_clear_error)
         (define r (SSL_connect ssl))
         (define e (if (= r 1) 0 (SSL_get_error ssl r)))
         (define msg (and (not (memv e (list 0 SSL_ERROR_WANT_READ SSL_ERROR_WANT_WRITE)))
                          (openssl-errors)))
         (drain!)
         (list r e msg))))
    (define e (cadr r+e))
    (cond
      [(= (car r+e) 1) (void)]
      [(= e SSL_ERROR_WANT_READ)
       (unless (with-handlers ([exn:fail? (lambda (_) #f)]) (feed!))
         (fail "connection closed during TLS handshake"))
       (loop)]
      [(= e SSL_ERROR_WANT_WRITE) (loop)]
      [else (fail (format "TLS handshake failed: ~a" (caddr r+e)))]))

  ;; node certificate (OpenSSLAuthContext::VerifyRemoteNodeCertificate)
  (define vr (SSL_get_verify_result ssl))
  (unless (memv vr (list X509_V_OK X509_V_ERR_UNHANDLED_CRITICAL_EXTENSION))
    (fail (format "server certificate not verified (X509 error ~a)" vr)))
  (define peer (SSL_get1_peer_certificate ssl))
  (unless peer (fail "server sent no certificate"))
  (define subject (name-text (X509_get_subject_name peer)))
  (define leaf-ok? (rr-extensions-ok? peer (string-append rr-oid ".3")))
  (X509_free peer)
  (unless (equal? subject expected-subject)
    (fail (format "server certificate is for ~s, expected ~s" subject expected-subject)))
  (unless leaf-ok?
    (fail "server certificate is not a Robot Raconteur node certificate"))

  ;; incoming: a reader thread decrypts into a pipe
  (define-values (pipe-in pipe-out) (make-pipe))
  (thread
   (lambda ()
     (let loop ()
       (define res
         (with-handlers ([exn:fail? (lambda (_) 'error)])
           (call-with-semaphore
            lock
            (lambda ()
              (cond
                [closed? 'closed]
                [else
                 (define r (SSL_read ssl rbuf bufsize))
                 (define out
                   (if (> r 0)
                       (let ([b (make-bytes r)]) (memcpy b rbuf r) b)
                       (SSL_get_error ssl r)))
                 (drain!)
                 out])))))
       (cond
         [(bytes? res) (write-bytes res pipe-out) (loop)]
         [(eqv? res SSL_ERROR_WANT_READ)
          (if (with-handlers ([exn:fail? (lambda (_) #f)]) (feed!))
              (loop)
              (close-output-port pipe-out))]
         [(eqv? res SSL_ERROR_WANT_WRITE) (loop)]
         [else (close-output-port pipe-out)]))))

  ;; outgoing: encrypt each write
  (define out
    (make-output-port
     'robotraconteur-tls
     always-evt
     (lambda (bstr start end non-block? breakable?)
       (cond
         [(= start end) 0]
         [else
          (call-with-semaphore
           lock
           (lambda ()
             (when closed? (error 'rrs+tcp "connection closed"))
             (let loop ([pos start])
               (when (< pos end)
                 (define n (min bufsize (- end pos)))
                 (memcpy wbuf 0 bstr pos n)
                 (define r (SSL_write ssl wbuf n))
                 (when (<= r 0)
                   (error 'rrs+tcp "TLS write failed: ~a" (openssl-errors)))
                 (loop (+ pos r))))
             (drain!)))
          (- end start)]))
     close-all!))

  (values pipe-in out))
