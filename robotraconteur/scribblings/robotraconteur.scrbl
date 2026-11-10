#lang scribble/manual
@(require (for-label racket/base racket/async-channel openssl robotraconteur))

@title{Robot Raconteur Client}
@author{John Wason}

@nested[#:style 'inset]{@bold{This is an AI generation experiment.} The
library, its tests and this documentation were written by Claude (Anthropic's
Claude Opus 5.5, using Claude Code), at the direction of John Wason.}

@defmodule[robotraconteur]

A pure-Racket client for @hyperlink["https://github.com/robotraconteur/robotraconteur"]{Robot
Raconteur}, the communication framework for robotics and automation. It
connects to standard Robot Raconteur services over plain TCP, Robot Raconteur
TLS, WebSocket and secure WebSocket, reads the service definitions from the
service when it connects (no generated code is needed), and can find nodes and
services on the local network.

The client speaks Message Version 2. It covers properties, functions,
generators, events, callbacks, object references, wires, pipes, object and
monitor locks, and remote errors. Memories, subscriptions and the local and
intra transports are not implemented.

@section{Installation}

@commandline{raco pkg install "git+https://github.com/johnwason/robotraconteur_racket?path=robotraconteur"}

From a checkout of the repository, @exec{raco pkg install --link robotraconteur/}
links the package to the working tree.

TLS uses the OpenSSL libraries that Racket's @racketmodname[openssl] library
loads. Discovery, and connecting to link-local IPv6 addresses without a zone,
need Linux.

@section{Quick start}

@racketblock[
(require robotraconteur)

(define obj (rr-connect "rr+tcp://localhost:29200?service=reynard"))
(rr-object-type obj)              (code:comment "\"experimental.reynard_the_robot.Reynard\"")
(rr-call obj "say" "Hello from Racket!")
(rr-set! obj "color" (vector 0.8 0.2 0.2))
(rr-get obj "robot_position")
(rr-call obj "teleport" 0.1 -0.2)
(rr-close obj)
]

Finding a service on the local network instead of naming its address:

@racketblock[
(define found (rr-find-service-by-type "experimental.reynard_the_robot.Reynard"))
(define obj (rr-connect (car (rr-service-info-urls (car found)))))
]

@section{Connecting}

@defproc[(rr-connect [url string?]
                     [#:username username (or/c string? #f) #f]
                     [#:credentials credentials (or/c hash? #f) #f]
                     [#:timeout timeout (>/c 0) 10]
                     [#:ssl-context ssl-context (or/c ssl-client-context? #f) #f]
                     [#:tls-context tls-context (or/c rr-node-tls-context? #f) #f])
         rr-object?]{

Connects to the service named in @racket[url] and returns its root object.

URLs take these forms; @tt{nodename=} and @tt{nodeid=} may be added to the
query to require a particular node:

@itemlist[
 @item{@tt{rr+tcp://host:port/?service=name}: plain TCP.}
 @item{@tt{rrs+tcp://host:port/?service=name}: Robot Raconteur TLS (see
       @secref["tls"]).}
 @item{@tt{rr+ws://host:port/path?service=name}: WebSocket, normally on the
       same port as @tt{rr+tcp}.}
 @item{@tt{rr+wss://host[:port]/path?service=name}: WebSocket over standard
       TLS, for example behind an HTTPS reverse proxy. The default port is 443.}]

IPv6 hosts go in brackets. A link-local address may carry its zone,
@tt{[fe80::1%25eth0]}; without one, the address is tried on every local
interface with a link-local address at the same time and the first connection
is kept, as the C++ core does.

@racket[username] and @racket[credentials] are sent for services that require
authentication, for example
@racket[(rr-connect url #:username "user" #:credentials (hash "password" "pass"))].

The TCP connect gives up after 5 seconds, and the whole connect (TCP, TLS, the
WebSocket upgrade and the Robot Raconteur handshake) after @racket[timeout]
seconds. On timeout everything opened for the attempt is closed and an
@racket[exn:fail:robotraconteur] with name @racket["RobotRaconteur.ConnectionError"]
is raised. Requests on an open connection time out after 30 seconds.

@racket[ssl-context] is used for @tt{rr+wss}; see @racket[rr-make-ssl-context].
@racket[tls-context] is used for @tt{rrs+tcp}; see @racket[rr-make-node-tls-context].}

@defproc[(rr-close [obj rr-object?]) void?]{
Disconnects the connection that @racket[obj] belongs to. Other objects from
the same connection become unusable.}

@defproc[(rr-object? [v any/c]) boolean?]{
Recognizes service objects: the root object returned by @racket[rr-connect]
and objects returned by @racket[rr-objref].}

@defproc[(rr-object-path [obj rr-object?]) string?]{
The object's service path, such as @racket["reynard"] or @racket["robot.tool[0]"].}

@defproc[(rr-object-type [obj rr-object?]) string?]{
The fully qualified object type, such as @racket["experimental.reynard_the_robot.Reynard"].}

@defproc[(rr-object-members [obj rr-object?]) (listof (cons/c symbol? string?))]{
The object's members, including those of the object types it implements, as
pairs of kind and name. Kinds are @racket['property], @racket['function],
@racket['event], @racket['objref], @racket['pipe], @racket['callback],
@racket['wire] and @racket['memory].}

@defproc[(rr-member-direction [obj rr-object?] [name string?])
         (or/c 'both 'readonly 'writeonly)]{
The direction of a member, from its @tt{readonly} or @tt{writeonly} modifier.}

@defproc[(rr-attributes [obj rr-object?]) hash?]{
The service attributes the service sent when connecting, a hash from strings
to values.}

@defproc[(rr-service-definitions [obj rr-object?]) (hash/c string? string?)]{
The service definitions received so far, as a hash from service definition
name to its source text.}

@section{Values}

Values are converted to and from Robot Raconteur types using the service
definitions:

@tabular[#:sep @hspace[2] #:style 'boxed
 (list (list @bold{Robot Raconteur} @bold{Racket})
       (list "numbers, bool" @elem{numbers, booleans; @tt{cdouble} and @tt{csingle} are complex numbers})
       (list "numeric arrays" @elem{vectors (lists are accepted when sending)})
       (list @tt{T[*]} @elem{@racket[rr-multidim]})
       (list @tt{string} "string")
       (list "struct, pod, namedarray" @elem{@racket[rr-struct]})
       (list @elem{@tt{T{int32}}, @tt{T{string}}} "hash")
       (list @tt{T{list}} "list")
       (list "enum" @elem{integer; a symbol naming the value is accepted when sending})
       (list @tt{varvalue} @elem{any of the above, or @racket[rr-varvalue] to fix the type})
       (list "null" @racket['null]))]

Numbers inside a received @tt{varvalue} are always vectors, because the wire
does not distinguish a scalar from a one-element array.

@defstruct*[rr-struct ([type string?] [fields hash?])]{
A structure, pod or namedarray value. @racket[fields] is a mutable hash from
field names to values. Use @racket[rr-new-structure] to make one with every
field set to its default.}

@defproc[(rr-struct-ref [s rr-struct?] [field string?]) any/c]{
Gets a field.}

@defproc[(rr-struct-set! [s rr-struct?] [field string?] [v any/c]) void?]{
Sets a field.}

@defproc[(rr-new-structure [obj rr-object?] [type string?]) rr-struct?]{
A new structure, pod or namedarray of @racket[type], qualified or relative to
@racket[obj]'s service definition, with default field values.}

@defstruct*[rr-multidim ([dims (listof exact-nonnegative-integer?)] [array vector?])]{
A multidimensional array. @racket[array] holds the elements in column-major
order, as Robot Raconteur and numpy's @tt{order="F"} do.}

@defstruct*[rr-varvalue ([value any/c] [type string?])]{
A value with an explicit type for a @tt{varvalue} field or parameter, for
example @racket[(rr-varvalue (vector 1 2) "int16[]")].}

@defproc[(rr-enum-values [obj rr-object?] [type string?])
         (listof (cons/c string? exact-integer?))]{
The names and values of an enum type.}

@defproc[(rr-pack-element [obj rr-object?] [type string?] [v any/c] [name string? "value"]) any/c]{
Converts @racket[v] to a message element of @racket[type] the way the client
does on the wire.}

@defproc[(rr-unpack-element [obj rr-object?] [type string?] [element any/c]) any/c]{
Converts a message element back to a value; the inverse of @racket[rr-pack-element].}

@section{Members}

@subsection{Properties and functions}

@defproc[(rr-get [obj rr-object?] [name string?]) any/c]{
Reads a property.}

@defproc[(rr-set! [obj rr-object?] [name string?] [v any/c]) void?]{
Writes a property.}

@defproc[(rr-call [obj rr-object?] [name string?] [arg any/c] ...) any/c]{
Calls a function and returns its result, or @racket[(void)] for a
@tt{void} function. A function returning a generator, or taking a generator
parameter, returns an @racket[rr-generator?] value.}

@subsection{Object references}

@defproc[(rr-objref [obj rr-object?] [name string?]
                    [index (or/c #f exact-integer? string?) #f])
         rr-object?]{
Gets the object behind an @tt{objref} member, indexed for @tt{objref T[]}
and @tt{objref T{string}} members.}

@subsection{Events and callbacks}

@defproc[(rr-add-event-listener! [obj rr-object?] [name string?] [proc procedure?]) void?]{
Calls @racket[proc] with the event's arguments each time the service fires
the event. See @secref["threads"].}

@defproc[(rr-set-callback! [obj rr-object?] [name string?] [proc procedure?]) void?]{
Sets the procedure the service calls for a @tt{callback} member. Its result
is returned to the service; if it raises, the service receives the error.}

@subsection{Generators}

@defproc[(rr-generator? [v any/c]) boolean?]{
Recognizes generators returned by @racket[rr-call].}

@defproc[(rr-generator-next [g rr-generator?] [param any/c 'none]) any/c]{
Returns the next value, or @racket[eof] once the generator is finished.
@racket[param] is sent to generators that take a parameter.}

@defproc[(rr-generator-close [g rr-generator?]) void?]{
Finishes the generator normally; @racket[rr-generator-next] then returns @racket[eof].}

@defproc[(rr-generator-abort [g rr-generator?]) void?]{
Aborts the operation. The service reports the abort on the next
@racket[rr-generator-next], usually as an @tt{OperationAborted} error.}

@defproc[(rr-generator->list [g rr-generator?]) list?]{
Collects the remaining values.}

@subsection{Wires}

Timestamps are pairs of seconds and nanoseconds.

@defproc[(rr-wire-peek-in [obj rr-object?] [name string?]) (values any/c pair?)]{
Reads the wire's current in-value and its timestamp without connecting.}

@defproc[(rr-wire-peek-out [obj rr-object?] [name string?]) (values any/c pair?)]{
Reads the wire's current out-value and its timestamp without connecting.}

@defproc[(rr-wire-poke-out! [obj rr-object?] [name string?] [v any/c]) void?]{
Sets the wire's out-value without connecting.}

@defproc[(rr-wire-connect [obj rr-object?] [name string?]) rr-wire-connection?]{
Connects to a wire. Values from the service arrive as the in-value; values
set with @racket[rr-wire-set-out-value!] go to the service.}

@defproc[(rr-wire-connection? [v any/c]) boolean?]{
Recognizes wire connections.}

@defproc[(rr-wire-in-value [w rr-wire-connection?]) any/c]{
The latest in-value. Raises @tt{ValueNotSet} if none has arrived or it has
expired (see @racket[rr-wire-set-in-value-lifespan!]).}

@defproc[(rr-wire-wait-in-value [w rr-wire-connection?] [#:timeout timeout real? 5]) any/c]{
Like @racket[rr-wire-in-value], but waits up to @racket[timeout] seconds for
a value.}

@defproc[(rr-wire-try-in-value [w rr-wire-connection?]) (values boolean? any/c any/c)]{
Returns whether there is a current in-value, the value and its timestamp.}

@defproc[(rr-wire-in-value-valid? [w rr-wire-connection?]) boolean?]{
Whether there is a current in-value.}

@defproc[(rr-wire-set-in-value-lifespan! [w rr-wire-connection?] [seconds (or/c real? #f)]) void?]{
How long an in-value stays current after it arrives; @racket[#f] for ever.}

@defproc[(rr-wire-set-out-value! [w rr-wire-connection?] [v any/c]) void?]{
Sends a new out-value.}

@defproc[(rr-wire-out-value [w rr-wire-connection?]) any/c]{
The last out-value sent. Raises @tt{ValueNotSet} if none has been sent.}

@defproc[(rr-wire-try-out-value [w rr-wire-connection?]) (values boolean? any/c any/c)]{
Returns whether an out-value has been sent, the value and its timestamp.}

@defproc[(rr-wire-add-listener! [w rr-wire-connection?] [proc (any/c pair? . -> . any)]) void?]{
Calls @racket[proc] with each new in-value and its timestamp. Out-of-order
packets are dropped. See @secref["threads"].}

@defproc[(rr-wire-close [w rr-wire-connection?]) void?]{
Closes the wire connection.}

@subsection{Pipes}

@defproc[(rr-pipe-connect [obj rr-object?] [name string?] [index exact-integer? -1])
         rr-pipe-endpoint?]{
Connects a pipe endpoint. With the default @racket[index] the service picks
the endpoint index. Packets that arrive before the connection completes are
kept.}

@defproc[(rr-pipe-endpoint? [v any/c]) boolean?]{
Recognizes pipe endpoints.}

@defproc[(rr-pipe-endpoint-index [p rr-pipe-endpoint?]) exact-integer?]{
The endpoint index.}

@defproc[(rr-pipe-send [p rr-pipe-endpoint?] [v any/c]) exact-nonnegative-integer?]{
Sends a packet and returns its packet number.}

@defproc[(rr-pipe-receive [p rr-pipe-endpoint?] [#:timeout timeout real? 5]) any/c]{
Waits up to @racket[timeout] seconds for the next packet. Returns @racket[eof]
when the pipe is closed and raises @tt{OperationTimeout} on timeout.}

@defproc[(rr-pipe-try-receive [p rr-pipe-endpoint?] [default any/c #f]) any/c]{
The next packet if one is waiting, otherwise @racket[default].}

@defproc[(rr-pipe-set-request-ack! [p rr-pipe-endpoint?] [on? boolean?]) void?]{
Whether packets sent from now on ask the service for an acknowledgement.}

@defproc[(rr-pipe-add-listener! [p rr-pipe-endpoint?] [proc (rr-pipe-endpoint? . -> . any)]) void?]{
Calls @racket[proc] with the endpoint each time a packet arrives; the packet
is still queued for @racket[rr-pipe-receive]. See @secref["threads"].}

@defproc[(rr-pipe-add-ack-listener! [p rr-pipe-endpoint?]
                                    [proc (rr-pipe-endpoint? exact-nonnegative-integer? . -> . any)])
         void?]{
Calls @racket[proc] with the endpoint and packet number when the service
acknowledges a packet.}

@defproc[(rr-pipe-close [p rr-pipe-endpoint?]) void?]{
Closes the endpoint.}

@section{Locks}

@defproc[(rr-request-object-lock [obj rr-object?] [kind (or/c 'user 'client) 'user]) string?]{
Locks @racket[obj] and the objects below it: for every session of the
authenticated user (@racket['user]) or for this connection only
(@racket['client]). Returns @racket["OK"].}

@defproc[(rr-release-object-lock [obj rr-object?]) string?]{
Releases an object lock.}

@defproc[(rr-monitor-enter [obj rr-object?] [timeout exact-integer? -1]) void?]{
Waits for the object's monitor lock; @racket[timeout] is in milliseconds,
@racket[-1] to wait for ever.}

@defproc[(rr-monitor-exit [obj rr-object?]) void?]{
Releases the monitor lock.}

@defproc[(call-with-rr-monitor-lock [obj rr-object?] [thunk (-> any)]
                                    [#:timeout timeout exact-integer? -1])
         any]{
Calls @racket[thunk] while holding the monitor lock, releasing it however
@racket[thunk] returns.}

@section{Errors}

@defstruct*[(exn:fail:robotraconteur exn:fail)
            ([error-code exact-integer?]
             [error-name string?]
             [error-message string?]
             [error-subname string?]
             [error-param any/c])]{
Raised for errors reported by the service and for client-side Robot Raconteur
errors such as timeouts. @racket[error-name] is a Robot Raconteur error name
such as @racket["RobotRaconteur.InvalidOperation"], or the name of an
exception defined by the service. @racket[error-subname] is @racket[""] and
@racket[error-param] is @racket['null] when the service sent none.}

@defproc[(rr-error-type [e exn:fail:robotraconteur?]) symbol?]{
The error code as a symbol, such as @racket['InvalidOperation],
@racket['ObjectLockedError] or @racket['RemoteError] (for exceptions defined
by a service).}

@section[#:tag "tls"]{TLS}

@defproc[(rr-make-node-tls-context [#:extra-roots extra-roots (listof path-string?) '()]
                                   [#:default-roots? default-roots? boolean? #t])
         rr-node-tls-context?]{
A context for @tt{rrs+tcp}. The client asks the server to start TLS, then
checks its certificate with Robot Raconteur's rules, like the C++ core:

@itemlist[
 @item{the chain leads to a trusted root: by default the two Robot Raconteur
       node root certificates (2015 and 2020), which are built in;}
 @item{each certificate carries the critical Robot Raconteur extension for its
       place in the chain, and no other unknown critical extension;}
 @item{the node certificate is for @tt{CN=Robot Raconteur Node {nodeid}} of
       the node that answered.}]

@racket[extra-roots] are PEM files of further roots to trust;
@racket[default-roots?] @racket[#f] leaves out the built-in ones. Client
certificates are not supported.}

@defproc[(rr-node-tls-context? [v any/c]) boolean?]{
Recognizes contexts from @racket[rr-make-node-tls-context].}

@defproc[(rr-make-ssl-context [#:trust trust (listof path-string?) '()]
                              [#:system-trust? system-trust? boolean? #t])
         ssl-client-context?]{
A client context for @tt{rr+wss} that checks the certificate chain and the
hostname, trusting the system's certificate store (unless
@racket[system-trust?] is @racket[#f]) and the PEM files in @racket[trust].
Without @racket[#:ssl-context], @racket[rr-connect] uses
@racket[(ssl-secure-client-context)].}

@section{Discovery}

Robot Raconteur nodes announce themselves with IPv6 link-local multicast
(group @tt{FF02::BA86}, UDP port 48653). These procedures send discovery
requests on every interface with a link-local address, listen for
@racket[timeout] seconds, and return what answered. Discovery needs Linux.

@defstruct*[rr-node-info ([nodeid string?] [nodename string?] [urls (listof string?)])]{
A node that answered. @racket[nodeid] has the form
@racket["{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}"]. @racket[urls] reach the node's
service index, one per interface the node was heard on, each with its zone.}

@defstruct*[rr-service-info ([name string?]
                             [root-object-type string?]
                             [implements (listof string?)]
                             [attributes hash?]
                             [nodeid string?]
                             [nodename string?]
                             [urls (listof string?)])]{
A service found by @racket[rr-find-service-by-type]; pass one of @racket[urls]
to @racket[rr-connect].}

@defproc[(rr-find-nodes [#:timeout timeout real? 3]) (listof rr-node-info?)]{
Every node that answered.}

@defproc[(rr-find-node-by-name [name string?] [#:timeout timeout real? 3]) (listof rr-node-info?)]{
The nodes named @racket[name].}

@defproc[(rr-find-node-by-id [id string?] [#:timeout timeout real? 3]) (listof rr-node-info?)]{
The node with NodeID @racket[id], with or without braces.}

@defproc[(rr-find-service-by-type [type string?]
                                  [#:timeout timeout real? 3]
                                  [#:transports transports (listof string?) '("rr+tcp" "rrs+tcp")])
         (listof rr-service-info?)]{
Services whose root object type is @racket[type] or implements it, on every
node that answered. Each node's service index is reached over the first of its
URLs, in @racket[transports] order, that connects.}

@section[#:tag "threads"]{Threads}

Each connection runs a few Racket threads: one reads and dispatches incoming
messages, one sends keep-alive messages, and one runs listeners. Any number of
threads may use a connection at the same time; requests are matched to their
replies.

Event, wire and pipe listeners run one at a time, in arrival order, on the
connection's listener thread. A listener must not block. In particular it must
not wait on a plain channel that another listener feeds. Hand slow work to
another thread or use an async channel (@racketmodname[racket/async-channel]).
A listener may call the service. Callbacks run in their own threads, so they
may block.

All of these are Racket threads, so they share one operating system thread.
