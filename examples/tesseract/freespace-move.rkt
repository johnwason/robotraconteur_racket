#lang racket/base
;; Plan a freespace move with the Tesseract motion planning service.
;; Port of examples/python/freespace_move_example.py from
;; tesseract-robotics/tesseract_robotraconteur.
;;
;;   racket freespace-move.rkt [url]
;;
;; The service must be running with the abb_irb2400 scene from Tesseract's
;; support package, which is the default in the service's container image:
;;
;;   podman run --rm -p 63158:63158 docker.io/wasontech/tesseract_robotraconteur:0.4.0
;;
;; The client needs only this library; Tesseract is not needed on the client
;; side. By default it connects to rr+tcp://localhost:63158?service=tesseract.
;;
;; Unlike Python, Racket structures carry their Robot Raconteur type, so
;; varvalue fields and maps need no RR.VarValue wrapping.

(require robotraconteur racket/cmdline racket/math racket/random)

(define url
  (command-line
   #:args ([u "rr+tcp://localhost:63158?service=tesseract"])
   u))

;; Connect to the service. In this case, a localhost url is used. If the
;; service were running on a remote node, the URL would be
;; "rr+tcp://hostname.example.com:port?service=tesseract" for TCP. An IP
;; address can also be used directly.
(define c (rr-connect url))

;; Robot Raconteur provides plug-and-play capabilities: the structure and enum
;; types are read from the service at connect time, so the client does not need
;; to be configured with them.
(define cl "experimental.tesseract_robotics.command_language.")
(define (new-struct type) (rr-new-structure c type))
(define (enum-value type name) (cdr (assoc name (rr-enum-values c type))))

(define freespace (enum-value (string-append cl "MoveInstructionType") "freespace"))
(define ordered (enum-value (string-append cl "CompositeInstructionOrder") "ordered"))
(define action-complete (enum-value "com.robotraconteur.action.ActionStatusCode" "complete"))

;; Helpers that replace GeometryUtil and UuidUtil from the Python companion
;; library.

;; Transform from a position and roll/pitch/yaw angles (radians, R = Rz Ry Rx),
;; like GeometryUtil.xyz_rpy_to_transform
(define (xyz-rpy->transform xyz rpy)
  (define-values (r p y) (apply values (map (λ (a) (/ a 2.0)) rpy)))
  (define-values (cr sr cp sp cy sy) (values (cos r) (sin r) (cos p) (sin p) (cos y) (sin y)))
  (define q (new-struct "com.robotraconteur.geometry.Quaternion"))
  (rr-struct-set! q "w" (+ (* cr cp cy) (* sr sp sy)))
  (rr-struct-set! q "x" (- (* sr cp cy) (* cr sp sy)))
  (rr-struct-set! q "y" (+ (* cr sp cy) (* sr cp sy)))
  (rr-struct-set! q "z" (- (* cr cp sy) (* sr sp cy)))
  (define v (new-struct "com.robotraconteur.geometry.Vector3"))
  (for ([k '("x" "y" "z")] [a xyz]) (rr-struct-set! v k (exact->inexact a)))
  (define t (new-struct "com.robotraconteur.geometry.Transform"))
  (rr-struct-set! t "rotation" q)
  (rr-struct-set! t "translation" v)
  t)

;; Random version 4 UUID, like UuidUtil.NewRandomUuid
(define (new-random-uuid)
  (define b (crypto-random-bytes 16))
  (bytes-set! b 6 (bitwise-ior #x40 (bitwise-and (bytes-ref b 6) #x0f)))
  (bytes-set! b 8 (bitwise-ior #x80 (bitwise-and (bytes-ref b 8) #x3f)))
  (define u (new-struct "com.robotraconteur.uuid.UUID"))
  (rr-struct-set! u "uuid_bytes" (for/vector ([x (in-bytes b)]) x))
  u)

;; Get the available task pipeline information from the service. Tesseract
;; task pipelines execute planning and other operations. The data storage keys
;; are varvalues; the Racket client unwraps them automatically.
(define freespace-info (hash-ref (rr-get c "tasks_info") "FreespacePipeline"))
(define (task-key keys-field name)
  (rr-struct-ref (hash-ref (rr-struct-ref freespace-info keys-field) name) "keys"))
(define output-key (task-key "output_keys" "program"))
(define input-key (task-key "input_keys" "planning_input"))

;; Create the environment. In this case, the environment is loaded from the
;; service. The available environments are specified when the service is
;; started. "default" is the default environment.
(void (rr-call c "load_environment" "default" "env"))

;; Create the EnvironmentHandle to pass to the planner
(define env-handle (new-struct "experimental.tesseract_robotics.environment.EnvironmentHandle"))
(rr-struct-set! env-handle "name" "env")

;; Helper function to make a Move instruction
(define (build-move-instr xyz rpy)
  ;; Create a cartesian waypoint. Joint waypoints are also available.
  (define wp (new-struct (string-append cl "CartesianWaypoint")))
  (rr-struct-set! wp "transform" (xyz-rpy->transform xyz rpy))
  ;; Create a move instruction and set the waypoint
  (define instr (new-struct (string-append cl "MoveInstruction")))
  (rr-struct-set! instr "waypoint" wp)
  (rr-struct-set! instr "profile" "DEFAULT")
  (rr-struct-set! instr "move_type" freespace)
  (rr-struct-set! instr "uuid" (new-random-uuid))
  instr)

;; Create the instructions
(define down (map degrees->radians '(0 90 0)))
(define instr1 (build-move-instr '(0.8 -0.3 1.455) down))
(define instr2 (build-move-instr '(0.8 0.3 1.455) down))
(define instr3 (build-move-instr '(0.8 0.5 1.455) down))

;; Create and configure the manipulator info structure. tcp_offset is set to the
;; identity explicitly: service images up to 0.4.0 use a robotraconteur_companion
;; version that turns an all-zero rotation into an uninitialized one
;; (robotraconteur/robotraconteur_companion#79), which can make the plan abort.
(define manip-info (new-struct "experimental.tesseract_robotics.common.ManipulatorInfo"))
(rr-struct-set! manip-info "tcp_frame" "tool0")
(rr-struct-set! manip-info "working_frame" "base_link")
(rr-struct-set! manip-info "manipulator" "manipulator")
(rr-struct-set! manip-info "tcp_offset" (xyz-rpy->transform '(0 0 0) '(0 0 0)))

;; Create and configure the composite instruction
(define composite (new-struct (string-append cl "CompositeInstruction")))
(rr-struct-set! composite "order" ordered)
(rr-struct-set! composite "instructions" (list instr1 instr2)) ; instr3
(rr-struct-set! composite "manipulator_info" manip-info)
(rr-struct-set! composite "uuid" (new-random-uuid))

;; Find the first executor, and get the task executor object
(define executors-info (rr-get c "task_executors_info"))
(define default-task-executor
  (rr-struct-ref (car (hash-values executors-info)) "name"))
(define executor (rr-objref c "task_executors" default-task-executor))

;; Create the task executor input and set the pipeline name. In this case, we
;; are using the FreespacePipeline. Other pipelines are available. These
;; pipelines are configured when the service is started.
(define exec-input (new-struct "experimental.tesseract_robotics.tasks.TaskExecutorInput"))
(rr-struct-set! exec-input "task_name" "FreespacePipeline")
(rr-struct-set! exec-input "data_storage"
                (hash "environment" env-handle
                      input-key composite))

;; Run the pipeline. It returns a Robot Raconteur "Generator". Generators are
;; a type of coroutine used either for a long running operation or a sequence
;; operation. Call rr-generator-next until it returns eof; keep the last status.
(define exec-gen (rr-call executor "run" exec-input))
(define status
  (let loop ([last #f])
    (define s (rr-generator-next exec-gen))
    (if (eof-object? s) last (loop s))))

;; Check the status of the pipeline to make sure it completed successfully
(unless (and status (equal? (rr-struct-ref status "action_status") action-complete))
  (error 'freespace-move-example "planning did not complete: ~a"
         (and status (rr-struct-ref status "action_status"))))

;; Retrieve the output plan from the data storage
(define output-plan (hash-ref (rr-struct-ref status "data_storage") output-key))

;; Extract and print the planned waypoints
(define wp-positions
  (for/list ([instr (in-list (rr-struct-ref output-plan "instructions"))])
    (rr-struct-ref (rr-struct-ref instr "waypoint") "position")))

(for ([p (in-list wp-positions)])
  (displayln p))

(rr-close c)
