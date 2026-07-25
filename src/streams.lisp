(in-package #:cl-dataflow)

;;;; A small lazy stream / transducer layer. A FLOW-STREAM is a delayed sequence:
;;;; a STEP thunk that yields either :END or (element . next-stream). Operators
;;;; (map/filter/scan/take/...) build new streams without forcing the source, and
;;;; consumers (collect/reduce/for-each/...) drive evaluation one element at a time.
;;;;
;;;; Two properties are deliberate:
;;;;   * Purity -- pulling never mutates the source, so a stream can be consumed
;;;;     more than once and operators compose freely.
;;;;   * Bounded stack -- every per-pull "skip" loop (filter, drop, distinct,
;;;;     flat-map, concat) is iterative, so discarding a long run of elements does
;;;;     not grow the control stack; consumers iterate rather than recurse.
(defstruct (flow-stream (:constructor %make-flow-stream (step))
                        (:copier nil)
                        (:predicate flow-stream-p))
  ;; STEP: () -> :END | (cons element next-flow-stream)
  step)

(declaim (inline %stream-step))

(defun %stream-step (stream)
  (funcall (flow-stream-step stream)))

(defun empty-stream ()
  "Return a stream with no elements."
  (%make-flow-stream
    (lambda ()
      :end)))

(defun list->stream (list)
  "Return a stream that yields the elements of LIST in order."
  (if (null list) (empty-stream)
    (%make-flow-stream
      (lambda ()
        (cons (first list) (list->stream (rest list)))))))

(defun stream-of (&rest elements)
  "Return a stream that yields ELEMENTS in order."
  (list->stream elements))

(defun stream-range (start end &key (step 1))
  "Return a stream of numbers from START (inclusive) toward END (exclusive) by
STEP. STEP may be negative for a descending range but must not be zero."
  (when (zerop step)
    (error
      'invalid-input-error
      :expected
      'nonzero-step
      :value
      step
      :detail
      "STREAM-RANGE step must be non-zero."))
  (labels ((generate (n)
              (if (if (plusp step) (>= n end)
            (<= n end)) (empty-stream)
          (%make-flow-stream
            (lambda ()
              (cons n (generate (+ n step))))))))
    (generate start)))

;;; --- Operators (stream -> stream) ----------------------------------------
(defun stream-map (function stream)
  "Return a stream of (FUNCALL FUNCTION ELEMENT) for each element of STREAM."
  (%make-flow-stream
    (lambda ()
      (let ((step (%stream-step stream)))
        (if (eq step :end) :end
          (cons (funcall function (car step)) (stream-map function (cdr step))))))))

(defun stream-filter (predicate stream)
  "Return a stream of the elements of STREAM for which PREDICATE is true."
  (%make-flow-stream
    (lambda ()
      (let ((current stream))
        (loop (let ((step (%stream-step current)))
            (cond
              ((eq step :end) (return :end))
              ((funcall predicate (car step))
                (return (cons (car step) (stream-filter predicate (cdr step)))))
              (t
                (setf current (cdr step))))))))))

(defun %stream-scan-rest (function accumulator stream)
  (%make-flow-stream
    (lambda ()
      (let ((step (%stream-step stream)))
        (if (eq step :end) :end
          (let ((next (funcall function accumulator (car step))))
            (cons next (%stream-scan-rest function next (cdr step)))))))))

(defun stream-scan (function seed stream)
  "Return the stream of running accumulations of STREAM under FUNCTION. SEED is
emitted first, then (FUNCTION accumulator element) after each element, so the
result has one more element than STREAM."
  (%make-flow-stream
    (lambda ()
      (cons seed (%stream-scan-rest function seed stream)))))

(defun stream-take (n stream)
  "Return a stream of at most the first N elements of STREAM."
  (%make-flow-stream
    (lambda ()
      (if (<= n 0) :end
        (let ((step (%stream-step stream)))
          (if (eq step :end) :end
            (cons (car step) (stream-take (1- n) (cdr step)))))))))

(defun stream-drop (n stream)
  "Return a stream of STREAM with its first N elements skipped."
  (%make-flow-stream
    (lambda ()
      (let ((current stream)
            (remaining n))
        (loop (if (<= remaining 0) (return (%stream-step current))
            (let ((step (%stream-step current)))
              (if (eq step :end) (return :end)
                (progn
                  (setf current (cdr step))
                  (decf remaining))))))))))

(defun stream-take-while (predicate stream)
  "Return the longest leading run of STREAM whose elements satisfy PREDICATE."
  (%make-flow-stream
    (lambda ()
      (let ((step (%stream-step stream)))
        (if (or (eq step :end) (not (funcall predicate (car step)))) :end
          (cons (car step) (stream-take-while predicate (cdr step))))))))

(defun stream-drop-while (predicate stream)
  "Return STREAM with its longest leading PREDICATE-satisfying run removed. Once an
element fails PREDICATE, the remainder is emitted unchanged."
  (%make-flow-stream
    (lambda ()
      (let ((current stream))
        (loop (let ((step (%stream-step current)))
            (cond
              ((eq step :end) (return :end))
              ((funcall predicate (car step))
                (setf current (cdr step)))
              (t (return (cons (car step) (cdr step)))))))))))

(defun %validate-stream-limit (limit caller)
  (unless (or (null limit) (and (integerp limit) (not (minusp limit))))
    (error
      'invalid-input-error
      :expected
      'non-negative-integer-or-nil
      :value
      limit
      :detail
      (format nil "~A limit must be a non-negative integer or NIL." caller)))
  limit)

(defun %signal-stream-limit-exceeded (caller limit)
  (error
    'invalid-input-error
    :expected
    (list :at-most limit)
    :value
    limit
    :detail
    (format nil "~A exceeded limit ~D." caller limit)))

(defun %validate-stream-limit-mode (mode caller valid-modes)
  (unless (member mode valid-modes)
    (error
      'invalid-input-error
      :expected
      valid-modes
      :value
      mode
      :detail
      (format nil "~A on-limit must be one of ~S." caller valid-modes)))
  mode)

(defun %standard-distinct-test (test)
  (loop for name in (list 'eq 'eql 'equal 'equalp)
        when (or (eq test name) (and (functionp test) (eq test (symbol-function name))))
          return name))

(defun %distinct-hashable-value-p (standard-test value)
  (case standard-test
    ((eq eql) t)
    ((equal equalp)
      ;; These immutable scalar categories cannot be EQUAL/EQUALP to structural values.
      (or (numberp value) (characterp value) (symbolp value)))))

(defun %distinct-hash-levels-member-p (value levels)
  (loop for table in levels
        thereis (and table (nth-value 1 (gethash value table)))))

(defun %distinct-hash-levels-add (value levels test)
  (labels ((carry (table size remaining)
              (cond
          ((null remaining) (list table))
          ((null (car remaining)) (cons table (cdr remaining)))
          (t
            (let ((merged (make-hash-table :test test :size (* 2 size))))
              (maphash
                (lambda (key present)
                  (declare (ignore present))
                  (setf (gethash key merged) t))
                table)
              (maphash
                (lambda (key present)
                  (declare (ignore present))
                  (setf (gethash key merged) t))
                (car remaining))
              (cons nil (carry merged (* 2 size) (cdr remaining))))))))
    (let ((singleton (make-hash-table :test test :size 1)))
      (setf (gethash value singleton) t)
      (carry singleton 1 levels))))

(defun %stream-distinct-emit (value step hashable seen hash-levels standard-test test
                              distinct-count max-distinct)
  "Build the CONS cell %STREAM-DISTINCT-STEP returns once VALUE is confirmed new:
signal a MAX-DISTINCT overflow first, then continue lazily from (CDR STEP) with
VALUE recorded in whichever of SEEN/HASH-LEVELS its hashability picked."
  (when (and max-distinct (>= distinct-count max-distinct))
    (%signal-stream-limit-exceeded "STREAM-DISTINCT" max-distinct))
  (cons
    value
    (%stream-distinct-step
      (cdr step)
      (if hashable seen
        (cons value seen))
      (if hashable (%distinct-hash-levels-add value hash-levels standard-test)
        hash-levels)
      standard-test
      test
      (1+ distinct-count)
      max-distinct)))

(defun %stream-distinct-step (stream seen hash-levels standard-test test distinct-count max-distinct)
  (%make-flow-stream
    (lambda ()
      (let ((current stream))
        (loop (let ((step (%stream-step current)))
            (when (eq step :end)
              (return :end))
            (let* ((value (car step))
                    (hashable (%distinct-hashable-value-p standard-test value))
                    (duplicate-p
                  (if hashable (%distinct-hash-levels-member-p value hash-levels)
                    (member value seen :test test))))
              (if duplicate-p (setf current (cdr step))
                (return
                  (%stream-distinct-emit value step hashable seen hash-levels
                                         standard-test test distinct-count max-distinct))))))))))

(defun stream-distinct (stream &key (test 'equal) max-distinct)
  "Return a lazy stream containing only the first occurrence of each value.
TEST may be a function designator accepted by MEMBER. Standard EQ/EQL tests use
persistent hash lookup for every value; standard EQUAL/EQUALP tests do so for
mutation-stable scalar values and retain list semantics for structural values.
MAX-DISTINCT bounds the number of unique values retained; exceeding it signals
INVALID-INPUT-ERROR when the next new value is pulled. NIL means unbounded."
  (%validate-stream-limit max-distinct "STREAM-DISTINCT")
  (let ((standard-test (%standard-distinct-test test)))
    (%stream-distinct-step
      stream
      '()
      '()
      standard-test
      test
      0
      max-distinct)))

(defun %stream-flat-map-cont (function inner outer)
  (%make-flow-stream
    (lambda ()
      (let ((inner-stream inner)
            (outer-stream outer))
        (loop (let ((inner-step (%stream-step inner-stream)))
            (if (eq inner-step :end) (let ((outer-step (%stream-step outer-stream)))
                (if (eq outer-step :end) (return :end)
                  (setf inner-stream (funcall function (car outer-step))
                        outer-stream (cdr outer-step))))
              (return
                (cons
                  (car inner-step)
                  (%stream-flat-map-cont function (cdr inner-step) outer-stream))))))))))

(defun stream-flat-map (function stream)
  "Return the concatenation of the streams produced by applying FUNCTION to each
element of STREAM. FUNCTION must return a stream for every element."
  (%stream-flat-map-cont function (empty-stream) stream))

(defun %stream-concat-list (streams)
  (%make-flow-stream
    (lambda ()
      (let ((remaining streams))
        (loop (if (null remaining) (return :end)
            (let ((step (%stream-step (first remaining))))
              (if (eq step :end) (setf remaining (rest remaining))
                (return
                  (cons (car step) (%stream-concat-list (cons (cdr step) (rest remaining)))))))))))))

(defun stream-concat (&rest streams)
  "Return the concatenation of STREAMS in order."
  (%stream-concat-list streams))

(defun stream-zip (stream-a stream-b)
  "Return a stream of (a . b) conses pairing STREAM-A with STREAM-B element by
element, stopping when either stream ends."
  (%make-flow-stream
    (lambda ()
      (let ((step-a (%stream-step stream-a))
            (step-b (%stream-step stream-b)))
        (if (or (eq step-a :end) (eq step-b :end)) :end
          (cons (cons (car step-a) (car step-b)) (stream-zip (cdr step-a) (cdr step-b))))))))

(defun stream-tap (function stream)
  "Return a stream identical to STREAM, calling FUNCTION on each element for its
side effect as the element passes through."
  (%make-flow-stream
    (lambda ()
      (let ((step (%stream-step stream)))
        (if (eq step :end) :end
          (progn
            (funcall function (car step))
            (cons (car step) (stream-tap function (cdr step)))))))))

;;; --- Consumers (stream -> value) -----------------------------------------

(defmacro do-stream ((element stream &key limit caller on-end) &body body)
  "Iterate ELEMENT over the elements of STREAM in order, driving %STREAM-STEP one
element at a time. When LIMIT is non-NIL, exceeding it signals
INVALID-INPUT-ERROR by way of %SIGNAL-STREAM-LIMIT-EXCEEDED naming CALLER. Once
the stream is exhausted the form evaluates to ON-END; BODY may (RETURN value)
to stop early with a different value instead."
  (let ((current (gensym "CURRENT"))
        (step (gensym "STEP"))
        (count (gensym "COUNT")))
    `(let ((,current ,stream)
           (,count 0))
       (loop
         (let ((,step (%stream-step ,current)))
           (when (eq ,step :end) (return ,on-end))
           (when (and ,limit (= ,count ,limit))
             (%signal-stream-limit-exceeded ,caller ,limit))
           (let ((,element (car ,step)))
             ,@body)
           (incf ,count)
           (setf ,current (cdr ,step)))))))

(defun stream-collect (stream &key limit (on-limit :error))
  "Force STREAM and return its elements as a fresh list.
LIMIT bounds the number of elements accepted. ON-LIMIT is :ERROR (signal when the
stream contains more than LIMIT elements) or :TRUNCATE (return the first LIMIT
elements without forcing more input)."
  (%validate-stream-limit limit "STREAM-COLLECT")
  (%validate-stream-limit-mode on-limit "STREAM-COLLECT" '(:error :truncate))
  (let ((result '())
        (current stream)
        (count 0))
    (loop (when (and limit (= count limit) (eq on-limit :truncate))
        (return (nreverse result))) (let ((step (%stream-step current)))
        (when (eq step :end)
          (return (nreverse result)))
        (when (and limit (= count limit))
          (%signal-stream-limit-exceeded "STREAM-COLLECT" limit))
        (push (car step) result)
        (incf count)
        (setf current (cdr step))))))

(defun stream-reduce (function seed stream &key limit)
  "Fold STREAM left to right under FUNCTION starting from SEED, returning the final
accumulator. LIMIT bounds the number of input elements accepted."
  (%validate-stream-limit limit "STREAM-REDUCE")
  (let ((accumulator seed))
    (do-stream (element stream :limit limit :caller "STREAM-REDUCE" :on-end accumulator)
      (setf accumulator (funcall function accumulator element)))))

(defun stream-for-each (function stream &key limit)
  "Call FUNCTION on each element of STREAM for its side effect. Returns no values.
LIMIT bounds the number of input elements accepted."
  (%validate-stream-limit limit "STREAM-FOR-EACH")
  (do-stream (element stream :limit limit :caller "STREAM-FOR-EACH" :on-end (values))
    (funcall function element)))

(defun stream-count (stream &key limit)
  "Return the number of elements in STREAM. LIMIT bounds the number of input
elements accepted."
  (%validate-stream-limit limit "STREAM-COUNT")
  (let ((count 0))
    (do-stream (element stream :limit limit :caller "STREAM-COUNT" :on-end count)
      (declare (ignore element))
      (incf count))))

(defun stream-first (stream &optional default)
  "Return the first element of STREAM, or DEFAULT when STREAM is empty."
  (let ((step (%stream-step stream)))
    (if (eq step :end) default
      (car step))))

(defun stream-empty-p (stream)
  "Return true when STREAM has no elements."
  (eq (%stream-step stream) :end))
