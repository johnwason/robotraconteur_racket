# Robot Raconteur client for Racket (experimental)

A small, pure-Racket Robot Raconteur **client**. It talks to standard Robot
Raconteur services over `rr+tcp`, `rrs+tcp` (Robot Raconteur node TLS),
`rr+ws` (WebSocket) or `rr+wss` (WebSocket over standard TLS) using Message
Version 2. It reads the
service definitions from the service at connect time, so you don't need
generated code.

## Layout

| File | Purpose |
|------|---------|
| `robotraconteur/message.rkt` | Message V2 binary codec (header / entries / elements) |
| `robotraconteur/robdef.rkt`  | Minimal `.robdef` parser (structs, pods, namedarrays, enums, objects) |
| `robotraconteur/pack.rkt`    | Converts Racket values to and from message elements, using the type info |
| `robotraconteur/websocket.rkt` | Minimal WebSocket client that exposes the connection as a byte stream (used for `rr+ws` and `rr+wss`) |
| `robotraconteur/tls.rkt`     | Node TLS for `rrs+tcp`: libssl via the FFI, with the core's certificate rules |
| `robotraconteur/rootca.rkt`  | The two Robot Raconteur node root certificates (2015 and 2020) |
| `robotraconteur/client.rkt`  | Transport selection, handshake, request/response, and the member APIs |
| `robotraconteur/main.rkt`    | Public module |
| `test/`                      | Python reference service and the Racket integration tests |
| `test/servicetest/`          | Ports of the Robot Raconteur `ServiceTestClient*.py` tests, the test vector reader and the C++ test server harness |
| `test/data/test_vectors.bin` | Copy of the Robot Raconteur test vector blob (`TEST_VECTORS_FORMAT.md`) |
| `build_cpp_test_server.sh`   | Builds the Robot Raconteur C++ test server inside the container |
| `examples/simple.rkt`        | Short usage example |
| `examples/reynard.rkt`       | Racket port of Reynard the Robot's Python client example |
| `test/loopback_robot.py`     | Loopback `AbstractRobot` driver (standard `com.robotraconteur.robotics.robot.Robot`) |

## Usage

```racket
(require "robotraconteur/main.rkt")
(define obj (rr-connect "rr+tcp://127.0.0.1:22222/?service=test"))
;; or over WebSocket (same server port):
;; (rr-connect "rr+ws://127.0.0.1:22222/?service=test")
;; or over WebSocket with TLS, e.g. behind an HTTPS reverse proxy (default port 443):
;; (rr-connect "rr+wss://wstest2.wasontech.com/robotraconteur?service=testobj")
;; or with Robot Raconteur node TLS (the server needs a node certificate):
;; (rr-connect "rrs+tcp://127.0.0.1:22222/?service=test")
(rr-get obj "d1")                       ; properties
(rr-set! obj "d1" 2.0)
(rr-call obj "add" 1.0 2.0)             ; functions
(rr-add-event-listener! obj "ev1" (λ (msg v) (displayln msg)))
(rr-set-callback! obj "cb1" (λ (a) (* 2 a)))
(rr-generator->list (rr-call obj "count_to" 3))
(rr-get (rr-objref obj "subs" 2) "name") ; objrefs (indexed or not)
(rr-wire-peek-in obj "w_in")            ; wires: peek/poke or connect
(define w (rr-wire-connect obj "w_in")) (rr-wire-wait-in-value w)
(define p (rr-pipe-connect obj "p1"))   ; pipes
(rr-pipe-send p (vector 1.0)) (rr-pipe-receive p)
(rr-close obj)
```

Other operations:

| Area | Functions |
|---|---|
| Connect | `rr-connect` with `#:username` and `#:credentials`; `rr-attributes`; `rr-service-definitions` |
| Types | `rr-new-structure`, `rr-enum-values`, `rr-pack-element` / `rr-unpack-element` |
| Members | `rr-object-members`, `rr-member-direction` (`'both`, `'readonly` or `'writeonly`) |
| Generators | `rr-generator-next` (returns `eof` when finished), `rr-generator-close`, `rr-generator-abort`, `rr-generator->list` |
| Wires | `rr-wire-in-value` (raises `ValueNotSet` if no value has arrived or it has expired), `rr-wire-wait-in-value`, `rr-wire-try-in-value`, `rr-wire-set-in-value-lifespan!`, `rr-wire-set-out-value!`, `rr-wire-try-out-value`, `rr-wire-add-listener!` |
| Pipes | `rr-pipe-connect` (optional endpoint index), `rr-pipe-set-request-ack!`, `rr-pipe-add-listener!`, `rr-pipe-add-ack-listener!`, `rr-pipe-try-receive` |
| Locks | `rr-request-object-lock` (`'user` or `'client`), `rr-release-object-lock`, `rr-monitor-enter` / `rr-monitor-exit`, `call-with-rr-monitor-lock` |

Event, wire and pipe listeners run in order on a single dispatch thread per
connection. A listener must not block: hand work to another thread or use an
async channel.

### How values map

| Robot Raconteur | Racket |
|---|---|
| numeric / bool scalars | numbers, `#t`/`#f`; `cdouble` maps to complex numbers |
| numeric arrays | vectors (lists are also accepted when sending) |
| `T[*]` multidim arrays | `rr-multidim` (dims list, column-major data vector) |
| `string` | string |
| struct, pod, namedarray | `rr-struct` (`rr-struct-ref`, `rr-struct-set!`, `rr-new-structure`) |
| `T{int32}`, `T{string}` | hash |
| `T{list}` | list |
| enum | integer (a symbol naming the value is accepted when sending) |
| `varvalue` | the value's type is detected automatically; wrap it in `(rr-varvalue v "int16[]")` to force a type. Numbers in a received varvalue are always vectors, because the wire does not distinguish a scalar from a one-element array |
| pod/namedarray fields `T[N]`, `T[M,N]` | vector, `rr-multidim` |
| null | `'null` |

Remote errors are raised as `exn:fail:robotraconteur`, with the fields
`error-code`, `error-name` (for example `"RobotRaconteur.InvalidOperation"` or a
service-defined exception name), `error-message`, `error-subname` and
`error-param`. `(rr-error-type e)` gives the code as a symbol, such as
`'ObjectLockedError`.

## Tests

```sh
./run_tests.sh
```

This builds the `rr-racket-dev` image from the `Dockerfile` (Ubuntu 24.04,
Racket, and Python `robotraconteur`) if it isn't already built. It then runs
the Python test service and the Racket tests in one container with
`--network none`, so all traffic stays on the container's loopback. The full
suite runs three times: over `rr+tcp`, over `rr+ws`, and over `rr+wss`
through a local TLS relay (`test/tls_proxy.py`, standing in for a reverse
proxy) with a throwaway self-signed certificate valid for `localhost` only.
`test/test-wss.rkt` then checks that a certificate outside the trust store, and
a trusted certificate used for the wrong hostname, are both rejected.

`rrs+tcp` runs the full suite against a secure service (TLS required) whose
node certificate comes from a throwaway PKI built by `test/make_test_pki.sh`.
That PKI has the same shape as the real one: root, intermediate and node
certificates, each with its critical Robot Raconteur extension. The client is
given the test root explicitly. `test/test-rrs.rkt` then checks the
verification rules against one server per case:

- a certificate naming another node is rejected;
- a certificate without the node extension is rejected;
- a certificate with an unknown critical extension is rejected;
- a chain the default roots don't cover is rejected;
- a `nodeid` in the URL that doesn't match the server fails;
- plaintext `rr+tcp` to the secure server is refused.

`./run_online_tests.sh` needs internet access and is kept separate. It
connects over `rr+wss` to the public test service at `wstest2.wasontech.com`,
the same check as the core's `test/extra/tcp_tls/test_ws_https.py`.

It then runs interop tests against real services:

- **[Reynard the Robot](https://github.com/robotraconteur/reynard-the-robot)**
  (`test/test-reynard.rkt`): teleport, drive, arm control, color, the state
  wire, and remote errors.
- **A loopback robot built on
  [AbstractRobot](https://github.com/robotraconteur/robotraconteur_abstract_robot_python)**
  (`test/loopback_robot.py`, `test/test-robot.rkt`). The driver has no
  hardware: each joint command becomes the measured position. The test reads
  `RobotInfo` and the other standard types (25 service definitions pulled
  from the service) and moves the robot in jog mode, with `execute_trajectory`
  (a generator of `TrajectoryStatus`), and with the streaming
  `position_command` wire. It checks each move against the reported joint
  position.

### ServiceTest ports against the C++ test server

`test/servicetest/` ports Robot Raconteur's own client tests,
`ServiceTestClient.py`, `ServiceTestClient2.py` and `ServiceTestClient3.py`
(on the `test-vectors-blob` branch), to Racket. They run against the
Robot Raconteur C++ test server:

```sh
./build_cpp_test_server.sh   # once; RR_SRC defaults to ~/RobotRaconteur2/robotraconteur
./run_tests.sh
```

The build mounts the checkout read-only and builds into `build/rr-cpp`, with
networking off. The tests load `librobotraconteur_test_server_lib.so` through
Racket's FFI and run the server inside the test process. To use an external
`robotraconteur_test_server` instead, set `ROBOTRACONTEUR_TEST_SERVER_URL`
(for example `rr+tcp://localhost:22222`).

Expected values come from `test/data/test_vectors.bin` through a reader that
follows the blob format's reader requirements (`test-vectors.rkt`).
`run_tests.sh` checks that this copy matches the checkout. Not ported: memory
tests, the Python async API tests, and numpy helpers.

## Limitations

- Client only. Only `rr+tcp`, `rrs+tcp`, `rr+ws` and `rr+wss`: no local or
  intra transports, and no node discovery.
- `rrs+tcp` follows the C++ core:
  - the client sends `STARTTLS` before `CreateConnection`, then runs TLS on
    the same connection;
  - the chain must lead to one of the two embedded Robot Raconteur node roots
    (`rootca.rkt`);
  - each certificate must carry the critical Robot Raconteur extension for its
    position, and no unknown critical extensions;
  - the node certificate must be `CN=Robot Raconteur Node {nodeid}` for the
    node that answered.

  `rr-make-node-tls-context #:extra-roots (list "root.pem")` adds roots
  (`#:default-roots? #f` drops the embedded ones); pass it as `#:tls-context`.
  There are no client certificates, so services that tie users to a client
  NodeID (mutual authentication) can't be used. `rrs+ws` and `rrs+wss` aren't
  supported. `rrs+tcp` needs OpenSSL 1.1 or 3 (the libraries Racket's
  `openssl` collection loads).
- `rr+wss` is plain web TLS: the certificate chain and hostname are checked,
  by default against the system trust store. `rr-make-ssl-context #:trust
  (list "ca.pem")` builds a context that also trusts extra certificates; pass
  it to `rr-connect` as `#:ssl-context`. The WebSocket client sends no
  `Origin` header (servers accept that from non-browser clients) and does not
  follow HTTP redirects.
- Only Message Version 2. Version 4 and string tables are not implemented
  (the client advertises only V2, and servers fall back to it).
- No memories, subscriptions, reconnect, or pipe flow control (acks are sent
  and received, but nothing is throttled).
- The robdef parser is permissive and only extracts type information. It does
  not validate definitions, and constants other than enums are ignored.
