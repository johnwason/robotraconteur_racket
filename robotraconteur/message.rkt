#lang racket/base
;; Robot Raconteur Message Version 2 binary codec.
;;
;; Wire layout (all little endian):
;;   Message      = Header Entry*
;;   Header       = "RRAC" u32:message_size u16:version(=2) u16:header_size
;;                  16:sender_nodeid 16:receiver_nodeid u32:sender_ep u32:receiver_ep
;;                  str16:sender_nodename str16:receiver_nodename str16:metadata
;;                  u16:entry_count u16:message_id u16:message_res_id
;;   Entry        = u32:entry_size u16:entry_type u16:reserved str16:service_path
;;                  str16:member_name u32:request_id u16:error str16:metadata
;;                  u16:element_count Element*
;;   Element      = u32:element_size str16:name u16:data_type str16:type_name
;;                  str16:metadata u32:data_count data
;; where str16 is a u16 byte length followed by UTF-8 bytes.

(require racket/list)

(provide (struct-out message)
         (struct-out entry)
         (struct-out elem)
         message->bytes
         read-message
         bytes->message
         ;; data type codes
         dt-void dt-double dt-single dt-int8 dt-uint8 dt-int16 dt-uint16
         dt-int32 dt-uint32 dt-int64 dt-uint64 dt-string dt-cdouble dt-csingle
         dt-bool dt-structure dt-vector dt-dictionary dt-object dt-varvalue
         dt-varobject dt-list dt-pod dt-pod-array dt-pod-multidimarray dt-enum
         dt-namedtype dt-namedarray dt-namedarray-array
         dt-namedarray-multidimarray dt-multidimarray
         numeric-dt? nested-dt? dt-size
         ;; helpers
         make-entry make-elem find-elem find-elem* elem-value
         entry-type-code entry-type-name
         message-error-code)

;; ---------------------------------------------------------------------------
;; Data type codes

(define dt-void 0)
(define dt-double 1)
(define dt-single 2)
(define dt-int8 3)
(define dt-uint8 4)
(define dt-int16 5)
(define dt-uint16 6)
(define dt-int32 7)
(define dt-uint32 8)
(define dt-int64 9)
(define dt-uint64 10)
(define dt-string 11)
(define dt-cdouble 12)
(define dt-csingle 13)
(define dt-bool 14)
(define dt-structure 101)
(define dt-vector 102)
(define dt-dictionary 103)
(define dt-object 104)
(define dt-varvalue 105)
(define dt-varobject 106)
(define dt-list 108)
(define dt-pod 109)
(define dt-pod-array 110)
(define dt-pod-multidimarray 111)
(define dt-enum 112)
(define dt-namedtype 113)
(define dt-namedarray 114)
(define dt-namedarray-array 115)
(define dt-namedarray-multidimarray 116)
(define dt-multidimarray 117)

(define (numeric-dt? t) (or (<= dt-double t dt-uint64) (<= dt-cdouble t dt-bool)))

(define (nested-dt? t)
  (memv t (list dt-structure dt-vector dt-dictionary dt-multidimarray dt-list
                dt-pod dt-pod-array dt-pod-multidimarray
                dt-namedarray-array dt-namedarray-multidimarray)))

(define (dt-size t)
  (case t
    [(1) 8] [(2) 4] [(3 4) 1] [(5 6) 2] [(7 8) 4] [(9 10) 8]
    [(12) 16] [(13) 8] [(14) 1]
    [else (error 'dt-size "not a numeric type: ~a" t)]))

;; ---------------------------------------------------------------------------
;; Message entry type codes

(define entry-types
  '((Null . 0) (StreamOp . 1) (StreamOpRet . 2)
    (StreamCheckCapability . 3) (StreamCheckCapabilityRet . 4)
    (GetServiceDesc . 101) (GetServiceDescRet . 102)
    (ObjectTypeName . 103) (ObjectTypeNameRet . 104)
    (ServiceClosed . 105) (ServiceClosedRet . 106)
    (ConnectClient . 107) (ConnectClientRet . 108)
    (DisconnectClient . 109) (DisconnectClientRet . 110)
    (ConnectionTest . 111) (ConnectionTestRet . 112)
    (GetNodeInfo . 113) (GetNodeInfoRet . 114)
    (ReconnectClient . 115) (ReconnectClientRet . 116)
    (NodeCheckCapability . 117) (NodeCheckCapabilityRet . 118)
    (GetServiceAttributes . 119) (GetServiceAttributesRet . 120)
    (ConnectClientCombined . 121) (ConnectClientCombinedRet . 122)
    (EndpointCheckCapability . 501) (EndpointCheckCapabilityRet . 502)
    (ServiceCheckCapabilityReq . 1101) (ServiceCheckCapabilityRet . 1102)
    (ClientKeepAliveReq . 1105) (ClientKeepAliveRet . 1106)
    (ClientSessionOpReq . 1107) (ClientSessionOpRet . 1108)
    (ServicePathReleasedReq . 1109) (ServicePathReleasedRet . 1110)
    (PropertyGetReq . 1111) (PropertyGetRes . 1112)
    (PropertySetReq . 1113) (PropertySetRes . 1114)
    (FunctionCallReq . 1121) (FunctionCallRes . 1122)
    (GeneratorNextReq . 1123) (GeneratorNextRes . 1124)
    (EventReq . 1131) (EventRes . 1132)
    (PipePacket . 1141) (PipePacketRet . 1142)
    (PipeConnectReq . 1143) (PipeConnectRet . 1144)
    (PipeDisconnectReq . 1145) (PipeDisconnectRet . 1146)
    (PipeClosed . 1147) (PipeClosedRet . 1148)
    (CallbackCallReq . 1151) (CallbackCallRet . 1152)
    (WirePacket . 1161) (WirePacketRet . 1162)
    (WireConnectReq . 1163) (WireConnectRet . 1164)
    (WireDisconnectReq . 1165) (WireDisconnectRet . 1166)
    (WireClosed . 1167) (WireClosedRet . 1168)
    (MemoryRead . 1171) (MemoryReadRet . 1172)
    (MemoryWrite . 1173) (MemoryWriteRet . 1174)
    (MemoryGetParam . 1175) (MemoryGetParamRet . 1176)
    (WirePeekInValueReq . 1181) (WirePeekInValueRet . 1182)
    (WirePeekOutValueReq . 1183) (WirePeekOutValueRet . 1184)
    (WirePokeOutValueReq . 1185) (WirePokeOutValueRet . 1186)))

(define code->entry-type
  (for/hasheqv ([p (in-list entry-types)]) (values (cdr p) (car p))))

(define (entry-type-code sym)
  (cond [(assq sym entry-types) => cdr]
        [else (error 'entry-type-code "unknown entry type ~a" sym)]))

(define (entry-type-name code) (hash-ref code->entry-type code code))

;; Error codes (MessageErrorType); only the ones the client cares about by name.
(define message-error-codes
  '((None . 0) (ConnectionError . 1) (ProtocolError . 2) (ServiceNotFound . 3)
    (ObjectNotFound . 4) (InvalidEndpoint . 5) (EndpointCommunicationFatalError . 6)
    (NodeNotFound . 7) (ServiceError . 8) (MemberNotFound . 9)
    (MemberFormatMismatch . 10) (DataTypeMismatch . 11) (DataTypeError . 12)
    (DataSerializationError . 13) (MessageEntryNotFound . 14)
    (MessageElementNotFound . 15) (UnknownError . 16) (InvalidOperation . 17)
    (InvalidArgument . 18) (OperationFailed . 19) (NullValue . 20)
    (InternalError . 21) (SystemResourcePermissionDenied . 22)
    (OutOfSystemResource . 23) (SystemResourceError . 24)
    (ResourceNotFound . 25) (IOError . 26) (BufferLimitViolation . 27)
    (ServiceDefinitionError . 28) (OutOfRange . 29) (KeyNotFound . 30)
    (InvalidConfiguration . 31) (InvalidState . 32)
    (RemoteError . 100) (RequestTimeout . 101) (ReadOnlyMember . 102)
    (WriteOnlyMember . 103) (NotImplementedError . 104) (MemberBusy . 105)
    (ValueNotSet . 106) (AbortOperation . 107) (OperationAborted . 108)
    (StopIteration . 109) (OperationTimeout . 110) (OperationCancelled . 111)
    (AuthenticationError . 150) (ObjectLockedError . 151) (PermissionDenied . 152)))

(define (message-error-code sym)
  (cond [(assq sym message-error-codes) => cdr]
        [else (error 'message-error-code "unknown error ~a" sym)]))

;; ---------------------------------------------------------------------------
;; In-memory representation

;; header fields are folded into the message itself
(struct message (sender-nodeid receiver-nodeid sender-ep receiver-ep
                 sender-nodename receiver-nodename metadata
                 message-id message-res-id entries)
  #:transparent)

;; type is a symbol from entry-types (or a raw integer if unknown)
(struct entry (type service-path member-name request-id error metadata elements)
  #:transparent)

;; data:
;;  void            -> #f
;;  numeric         -> vector of numbers (booleans for bool, complex for c*)
;;  string          -> string
;;  nested types    -> list of elem
(struct elem (name type type-name metadata data) #:transparent)

(define (make-entry type #:path [path ""] #:member [member ""] #:request-id [rid 0]
                    #:error [err 0] #:metadata [md ""] . elems)
  (entry type path member rid err md elems))

(define (make-elem name type data #:type-name [tn ""] #:metadata [md ""])
  (elem name type tn md data))

(define (find-elem* elems name)
  (for/first ([e (in-list elems)] #:when (equal? (elem-name e) name)) e))

(define (find-elem elems name)
  (or (find-elem* elems name)
      (error 'find-elem "message element not found: ~a" name)))

(define (elem-value e) (elem-data e))

;; ---------------------------------------------------------------------------
;; Writing

(define (u8 n) (bytes n))
(define (u16 n) (integer->integer-bytes n 2 #f #f))
(define (u32 n) (integer->integer-bytes n 4 #f #f))

(define (str16 s)
  (define b (string->bytes/utf-8 s))
  (when (> (bytes-length b) 65535) (error 'rr "string too long"))
  (bytes-append (u16 (bytes-length b)) b))

(define (write-number t v out)
  (case t
    [(1) (write-bytes (real->floating-point-bytes (exact->inexact v) 8 #f) out)]
    [(2) (write-bytes (real->floating-point-bytes (exact->inexact v) 4 #f) out)]
    [(3) (write-bytes (integer->integer-bytes v 1 #t #f) out)]
    [(4) (write-byte v out)]
    [(5) (write-bytes (integer->integer-bytes v 2 #t #f) out)]
    [(6) (write-bytes (integer->integer-bytes v 2 #f #f) out)]
    [(7) (write-bytes (integer->integer-bytes v 4 #t #f) out)]
    [(8) (write-bytes (integer->integer-bytes v 4 #f #f) out)]
    [(9) (write-bytes (integer->integer-bytes v 8 #t #f) out)]
    [(10) (write-bytes (integer->integer-bytes v 8 #f #f) out)]
    [(12) (write-number 1 (real-part v) out) (write-number 1 (imag-part v) out)]
    [(13) (write-number 2 (real-part v) out) (write-number 2 (imag-part v) out)]
    [(14) (write-byte (if v 1 0) out)]))

(define (numeric-data->bytes t v)
  (define out (open-output-bytes))
  (for ([x (in-vector v)]) (write-number t x out))
  (get-output-bytes out))

(define (elem->bytes e)
  (define t (elem-type e))
  (define d (elem-data e))
  (define-values (count body)
    (cond
      [(= t dt-void) (values 0 #"")]
      [(= t dt-string)
       (define b (string->bytes/utf-8 d))
       (values (bytes-length b) b)]
      [(numeric-dt? t) (values (vector-length d) (numeric-data->bytes t d))]
      [(nested-dt? t)
       (values (length d) (apply bytes-append (map elem->bytes d)))]
      [else (error 'elem->bytes "cannot serialize data type ~a" t)]))
  (define rest
    (bytes-append (str16 (elem-name e)) (u16 t) (str16 (elem-type-name e))
                  (str16 (elem-metadata e)) (u32 count) body))
  (bytes-append (u32 (+ 4 (bytes-length rest))) rest))

(define (entry->bytes en)
  (define t (entry-type en))
  (define rest
    (bytes-append (u16 (if (symbol? t) (entry-type-code t) t)) (u16 0)
                  (str16 (entry-service-path en)) (str16 (entry-member-name en))
                  (u32 (entry-request-id en)) (u16 (entry-error en))
                  (str16 (entry-metadata en))
                  (u16 (length (entry-elements en)))
                  (apply bytes-append (map elem->bytes (entry-elements en)))))
  (bytes-append (u32 (+ 4 (bytes-length rest))) rest))

(define (message->bytes m)
  (define entries-bytes (apply bytes-append (map entry->bytes (message-entries m))))
  (define header-tail
    (bytes-append (message-sender-nodeid m) (message-receiver-nodeid m)
                  (u32 (message-sender-ep m)) (u32 (message-receiver-ep m))
                  (str16 (message-sender-nodename m))
                  (str16 (message-receiver-nodename m))
                  (str16 (message-metadata m))
                  (u16 (length (message-entries m)))
                  (u16 (message-message-id m))
                  (u16 (message-message-res-id m))))
  (define header-size (+ 12 (bytes-length header-tail)))
  (define total (+ header-size (bytes-length entries-bytes)))
  (bytes-append #"RRAC" (u32 total) (u16 2) (u16 header-size) header-tail entries-bytes))

;; ---------------------------------------------------------------------------
;; Reading (from a byte string with a cursor)

(struct rd (buf [pos #:mutable]))

(define (take! r n)
  (define p (rd-pos r))
  (when (> (+ p n) (bytes-length (rd-buf r)))
    (error 'rr "message truncated"))
  (set-rd-pos! r (+ p n))
  (subbytes (rd-buf r) p (+ p n)))

(define (r-u16 r) (integer-bytes->integer (take! r 2) #f #f))
(define (r-u32 r) (integer-bytes->integer (take! r 4) #f #f))
(define (r-str r n) (bytes->string/utf-8 (take! r n) #\?))
(define (r-str16 r) (r-str r (r-u16 r)))

(define (read-number t r)
  (case t
    [(1) (floating-point-bytes->real (take! r 8) #f)]
    [(2) (floating-point-bytes->real (take! r 4) #f)]
    [(3) (integer-bytes->integer (take! r 1) #t #f)]
    [(4) (bytes-ref (take! r 1) 0)]
    [(5) (integer-bytes->integer (take! r 2) #t #f)]
    [(6) (integer-bytes->integer (take! r 2) #f #f)]
    [(7) (integer-bytes->integer (take! r 4) #t #f)]
    [(8) (integer-bytes->integer (take! r 4) #f #f)]
    [(9) (integer-bytes->integer (take! r 8) #t #f)]
    [(10) (integer-bytes->integer (take! r 8) #f #f)]
    [(12) (let* ([a (read-number 1 r)] [b (read-number 1 r)]) (make-rectangular a b))]
    [(13) (let* ([a (read-number 2 r)] [b (read-number 2 r)]) (make-rectangular a b))]
    [(14) (not (zero? (bytes-ref (take! r 1) 0)))]))

(define (read-elem r)
  (define start (rd-pos r))
  (define size (r-u32 r))
  (define name (r-str16 r))
  (define t (r-u16 r))
  (define tn (r-str16 r))
  (define md (r-str16 r))
  (define count (r-u32 r))
  (define data
    (cond
      [(= t dt-void) #f]
      [(= t dt-string) (r-str r count)]
      [(numeric-dt? t)
       (for/vector #:length count ([i (in-range count)]) (read-number t r))]
      [(nested-dt? t) (for/list ([i (in-range count)]) (read-elem r))]
      [else (error 'read-elem "unknown data type ~a" t)]))
  (unless (= (rd-pos r) (+ start size))
    (error 'read-elem "element size mismatch"))
  (elem name t tn md data))

(define (read-entry r)
  (define start (rd-pos r))
  (define size (r-u32 r))
  (define t (r-u16 r))
  (r-u16 r)
  (define path (r-str16 r))
  (define member (r-str16 r))
  (define rid (r-u32 r))
  (define err (r-u16 r))
  (define md (r-str16 r))
  (define n (r-u16 r))
  (define elems (for/list ([i (in-range n)]) (read-elem r)))
  (unless (= (rd-pos r) (+ start size))
    (error 'read-entry "entry size mismatch"))
  (entry (entry-type-name t) path member rid err md elems))

(define (bytes->message b)
  (define r (rd b 0))
  (unless (equal? (take! r 4) #"RRAC") (error 'rr "invalid message magic"))
  (r-u32 r)
  (define version (r-u16 r))
  (unless (= version 2)
    (error 'rr "unsupported message version ~a (only version 2 is implemented)" version))
  (define header-size (r-u16 r))
  (define sender-id (take! r 16))
  (define receiver-id (take! r 16))
  (define sender-ep (r-u32 r))
  (define receiver-ep (r-u32 r))
  (define sender-name (r-str16 r))
  (define receiver-name (r-str16 r))
  (define md (r-str16 r))
  (define n (r-u16 r))
  (define mid (r-u16 r))
  (define mrid (r-u16 r))
  (unless (= (rd-pos r) header-size) (error 'rr "header size mismatch"))
  (define entries (for/list ([i (in-range n)]) (read-entry r)))
  (message sender-id receiver-id sender-ep receiver-ep sender-name receiver-name
           md mid mrid entries))

;; Read one complete message from an input port. Returns eof on end of stream.
(define (read-message in)
  (define head (read-bytes 8 in))
  (cond
    [(eof-object? head) eof]
    [(< (bytes-length head) 8) eof]
    [else
     (unless (equal? (subbytes head 0 4) #"RRAC") (error 'rr "invalid message magic"))
     (define size (integer-bytes->integer (subbytes head 4 8) #f #f))
     (define rest (read-bytes (- size 8) in))
     (if (or (eof-object? rest) (< (bytes-length rest) (- size 8)))
         eof
         (bytes->message (bytes-append head rest)))]))
