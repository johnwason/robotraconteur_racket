#lang info
;; Package metadata. The package is this directory (a single-collection
;; package providing the `robotraconteur` collection), so the repository's
;; tests and examples stay outside it. Install with
;;
;;   raco pkg install "git+https://github.com/johnwason/robotraconteur_racket?path=robotraconteur"
;;
;; or, from a checkout, raco pkg install --link robotraconteur/

(define collection "robotraconteur")
(define pkg-name "robotraconteur")
(define version "0.1")
(define pkg-desc "Robot Raconteur client: TCP, TLS, WebSocket and discovery")
(define pkg-authors '("John Wason"))
(define license 'Apache-2.0)

(define deps '("base"))
(define build-deps '("scribble-lib" "racket-doc"))

(define scribblings '(("scribblings/robotraconteur.scrbl" () (net-library))))
