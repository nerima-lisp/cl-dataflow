(in-package #:cl-dataflow)

;;;; DEFINE-COPY-INSTANCE(-WITH-CHECK) generate the %COPY-* deep-copy
;;;; constructors for every model class (event, effect, node, edge, ...) from
;;;; a per-slot copy-form list, keeping each class's copy logic declarative
;;;; and next to the slots it touches instead of hand-written per class.
;;;; %COPY-INSTANCE-SLOT-INITARGS needs :COMPILE-TOPLEVEL because both
;;;; macros' expanders call it and this file uses those macros on itself, a
;;;; few lines below.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %copy-instance-slot-initargs (slots)
    (mapcan (lambda (slot-spec)
              (destructuring-bind (initarg form) slot-spec
                (list initarg form)))
            slots)))

(defmacro define-copy-instance (name (source class) &body slots)
  `(defun ,name (,source)
     (make-instance ',class
       ,@(%copy-instance-slot-initargs slots))))

(defmacro define-copy-instance-with-check (name (source class expected-kind expected-symbol)
                                           &body slots)
  `(defun ,name (,source)
     (unless (typep ,source ',class)
       (%signal-invalid-input-error
         ',expected-symbol
         ,source
         (%expected-object-detail ,expected-kind ,source)))
     (make-instance ',class
       ,@(%copy-instance-slot-initargs slots))))

(define-copy-instance-with-check %copy-event (event event "EVENT" event)
  (:type (%read-slot event 'type))
  (:payload (%copy-structured-value (%read-slot event 'payload)))
  (:metadata (%normalize-metadata (%read-slot event 'metadata)))
  (:trace-index (%read-slot event 'trace-index)))

(define-copy-instance-with-check %copy-effect (effect effect "EFFECT" effect)
  (:type (%read-slot effect 'type))
  (:payload (%copy-structured-value (%read-slot effect 'payload)))
  (:metadata (%normalize-metadata (%read-slot effect 'metadata)))
  (:trace-index (%read-slot effect 'trace-index))
  (:result (%copy-structured-value (%read-slot effect 'result))))

(define-copy-instance %copy-node-snapshot (node node)
  (:name (slot-value node 'name))
  (:inputs (%normalize-unique-port-list (slot-value node 'inputs) "input"))
  (:outputs (%normalize-unique-port-list (slot-value node 'outputs) "output"))
  (:handler (slot-value node 'handler))
  (:metadata (%normalize-metadata (slot-value node 'metadata))))

(define-copy-instance %copy-node-error-snapshot (node node)
  (:name (%slot-value-or node 'name nil))
  (:inputs (%copy-structured-value (%slot-value-or node 'inputs nil)))
  (:outputs (%copy-structured-value (%slot-value-or node 'outputs nil)))
  (:handler (%slot-value-or node 'handler nil))
  (:metadata (%normalize-metadata (%slot-value-or node 'metadata nil))))

(define-copy-instance %copy-edge-snapshot (edge edge)
  (:from (slot-value edge 'from))
  (:from-port (slot-value edge 'from-port))
  (:to (slot-value edge 'to))
  (:to-port (slot-value edge 'to-port))
  (:metadata (%normalize-metadata (slot-value edge 'metadata))))

(define-copy-hash-table %copy-node-table-snapshot (nodes #'%copy-node-snapshot))

(define-copy-hash-table %copy-node-table-error-snapshot
    (nodes #'%copy-node-error-snapshot))

(defun %copy-graph-base (graph)
  (make-graph :metadata (graph-metadata graph)))

(defun %copy-graph-snapshot (graph)
  (let ((copy (%copy-graph-base graph)))
    (setf (graph-nodes copy) (graph-nodes graph))
    (setf (graph-edges copy) (graph-edges graph))
    copy))

(defun %copy-graph-error-snapshot (graph)
  (let ((copy (%copy-graph-base graph)))
    (setf (slot-value copy 'nodes)
          (%copy-node-table-error-snapshot (slot-value graph 'nodes)))
    (setf (slot-value copy 'edges)
          (mapcar #'%copy-edge-snapshot (slot-value graph 'edges)))
    copy))

(defun %copy-error-value (value)
  (typecase value
    (graph (%copy-graph-error-snapshot value))
    (node (%copy-node-snapshot value))
    (edge (%copy-edge-snapshot value))
    (event (%copy-event value))
    (effect (%copy-effect value))
    (t (%copy-structured-value value))))

(defun copy-graph (graph)
  (%copy-graph-snapshot graph))

(defun copy-context (context)
  ;; The collections are read live: MAKE-CONTEXT assigns each through its
  ;; public setter, and every one of those setters already copies (see
  ;; DEFINE-SLOT-APIS' :COPY/:MAPCAR-COPY setter forms and the hand-written
  ;; (SETF CONTEXT-TRACE)/(SETF CONTEXT-EFFECT-HANDLERS)). Reading through the
  ;; copying readers as well made two copies of each collection -- three of the
  ;; handler table -- to build one independent context. METADATA and RESULT keep
  ;; their public readers only because no %-prefixed live reader exists for
  ;; those two slots; their setters copy as well, so the extra copy is a single
  ;; scalar/plist rather than a whole collection.
  (make-context :values (%context-values-table context)
                :events (%context-events-list context)
                :effects (%context-effects-list context)
                :trace (%context-trace-list context)
                :metadata (context-metadata context)
                :effect-handlers (%context-effect-handler-table context)
                :result (context-result context)
                :state (context-state context)))

(defun copy-event (event)
  (%copy-event event))

(defun copy-effect (effect)
  (%copy-effect effect))
