(in-package #:cl-dataflow)

;;;; More stream operators and terminal collectors on top of the FLOW-STREAM core.
;;;; Operators stay lazy; the map-building consumers (group-by, frequencies,
;;;; index-by) preserve first-seen key order and iterate rather than recurse.

;;; --- Lazy operators ------------------------------------------------------

(defun stream-zip-with (function stream-a stream-b)
  "Return a stream of (FUNCALL FUNCTION A B) for paired elements of STREAM-A and
STREAM-B, stopping when either stream ends."
  (%make-flow-stream
   (lambda ()
     (let ((step-a (%stream-step stream-a))
           (step-b (%stream-step stream-b)))
       (if (or (eq step-a :end) (eq step-b :end))
           :end
           (cons (funcall function (car step-a) (car step-b))
                 (stream-zip-with function (cdr step-a) (cdr step-b))))))))

(defun stream-interleave (stream-a stream-b)
  "Return a stream that alternates elements of STREAM-A and STREAM-B; when one ends
the remaining elements of the other follow."
  (%make-flow-stream
   (lambda ()
     (let ((step (%stream-step stream-a)))
       (if (eq step :end)
           (%stream-step stream-b)
           (cons (car step) (stream-interleave stream-b (cdr step))))))))

(defun %stream-take-nth (n stream)
  (%make-flow-stream
   (lambda ()
     (let ((step (%stream-step stream)))
       (if (eq step :end)
           :end
           (cons (car step)
                 (%stream-take-nth n (stream-drop (1- n) (cdr step)))))))))

(defun stream-take-nth (n stream)
  "Return a stream of every Nth element of STREAM, starting with the first (indices
0, N, 2N, ...). N must be positive."
  (%positive-size n "STREAM-TAKE-NTH")
  (%stream-take-nth n stream))

(defun %stream-dedupe-after (previous stream test)
  (%make-flow-stream
   (lambda ()
     (let ((current stream))
       (loop
         (let ((step (%stream-step current)))
           (cond ((eq step :end) (return :end))
                 ((funcall test (car step) previous) (setf current (cdr step)))
                 (t (return (cons (car step)
                                  (%stream-dedupe-after (car step) (cdr step) test)))))))))))

(defun stream-dedupe-consecutive (stream &key (test 'equal))
  "Return a stream of STREAM with consecutive duplicate elements (under TEST)
collapsed to a single element. Non-adjacent duplicates are kept."
  (%make-flow-stream
   (lambda ()
     (let ((step (%stream-step stream)))
       (if (eq step :end)
           :end
           (cons (car step)
                 (%stream-dedupe-after (car step) (cdr step) test)))))))

(defun %stream-interpose-rest (separator stream)
  (%make-flow-stream
   (lambda ()
     (let ((step (%stream-step stream)))
       (if (eq step :end)
           :end
           (cons separator
                 (%make-flow-stream
                  (lambda ()
                    (cons (car step)
                          (%stream-interpose-rest separator (cdr step)))))))))))

(defun stream-interpose (separator stream)
  "Return a stream with SEPARATOR inserted between consecutive elements of STREAM."
  (%make-flow-stream
   (lambda ()
     (let ((step (%stream-step stream)))
       (if (eq step :end)
           :end
           (cons (car step)
                 (%stream-interpose-rest separator (cdr step))))))))

(defun %stream-distinct-by-emit (function value key step hashable seen hash-levels
                                 standard-test test distinct-count max-distinct)
  "Build the CONS cell %STREAM-DISTINCT-BY-STEP returns once VALUE's KEY is confirmed
new: signal a MAX-DISTINCT overflow first, then continue lazily from (CDR STEP) with
KEY recorded in whichever of SEEN/HASH-LEVELS its hashability picked."
  (when (and max-distinct (>= distinct-count max-distinct))
    (%signal-stream-limit-exceeded "STREAM-DISTINCT-BY" max-distinct))
  (cons
    value
    (%stream-distinct-by-step
      function
      (cdr step)
      (if hashable seen
        (cons key seen))
      (if hashable (%distinct-hash-levels-add key hash-levels standard-test)
        hash-levels)
      standard-test
      test
      (1+ distinct-count)
      max-distinct)))

(defun %stream-distinct-by-step (function stream seen hash-levels standard-test test distinct-count max-distinct)
  (%make-flow-stream
    (lambda ()
      (let ((current stream))
        (loop (let ((step (%stream-step current)))
            (when (eq step :end)
              (return :end))
            (let* ((value (car step))
                    (key (funcall function value))
                    (hashable (%distinct-hashable-value-p standard-test key))
                    (duplicate-p
                  (if hashable (%distinct-hash-levels-member-p key hash-levels)
                    (member key seen :test test))))
              (if duplicate-p (setf current (cdr step))
                (return
                  (%stream-distinct-by-emit function value key step hashable seen hash-levels
                                            standard-test test distinct-count max-distinct))))))))))

(defun stream-distinct-by (function stream &key (test 'equal) max-distinct)
  "Return a stream of the elements of STREAM whose key (FUNCALL FUNCTION ELEMENT) has
not appeared before (under TEST), keeping the first element for each key. The
key-projected analog of STREAM-DISTINCT: standard EQ/EQL tests use persistent hash
lookup for every key; standard EQUAL/EQUALP tests do so for mutation-stable scalar
keys and retain list semantics for structural keys. MAX-DISTINCT bounds retained
distinct keys and signals INVALID-INPUT-ERROR when exceeded."
  (%validate-stream-limit max-distinct "STREAM-DISTINCT-BY")
  (let ((standard-test (%standard-distinct-test test)))
    (%stream-distinct-by-step function stream '() '() standard-test test 0 max-distinct)))

;;; --- Terminal collectors -------------------------------------------------

(defun %stream-group-into (stream key-function value-function limit caller)
  "Fold STREAM into (VALUES TABLE FIRST-SEEN-KEY-ORDER), applying VALUE-FUNCTION to
accumulate (OLD-OR-NIL, PRESENT-P, ELEMENT) into each key's cell."
  (%validate-stream-limit limit caller)
  (let ((table (make-hash-table :test #'equal))
        (order '()))
    (do-stream (element stream :limit limit :caller caller
                :on-end (values table (nreverse order)))
      (let ((key (funcall key-function element)))
        (multiple-value-bind (existing present) (gethash key table)
          (unless present
            (push key order))
          (setf (gethash key table)
                (funcall value-function existing present element)))))))

(defun stream-group-by (function stream &key limit)
  "Return an alist (KEY . ELEMENTS) grouping STREAM's elements by (FUNCALL FUNCTION
ELEMENT). Keys appear in first-seen order and elements in stream order. LIMIT
bounds the number of input elements accepted."
  (multiple-value-bind (table order)
      (%stream-group-into stream function
                          (lambda (existing present element)
                            (declare (ignore present))
                            (cons element existing))
                          limit
                          "STREAM-GROUP-BY")
    (mapcar (lambda (key) (cons key (nreverse (gethash key table)))) order)))

(defun stream-frequencies (stream &key (key #'identity) limit)
  "Return an alist (VALUE . COUNT) counting occurrences of (FUNCALL KEY ELEMENT)
over STREAM, in first-seen order. LIMIT bounds the number of input elements
accepted."
  (multiple-value-bind (table order)
      (%stream-group-into stream key
                          (lambda (existing present element)
                            (declare (ignore element))
                            (if present (1+ existing) 1))
                          limit
                          "STREAM-FREQUENCIES")
    (mapcar (lambda (value) (cons value (gethash value table))) order)))

(defun stream-index-by (function stream &key limit)
  "Return an alist (KEY . ELEMENT) indexing STREAM by (FUNCALL FUNCTION ELEMENT),
with the last element for each key winning. Keys appear in first-seen order.
LIMIT bounds the number of input elements accepted."
  (multiple-value-bind (table order)
      (%stream-group-into stream function
                          (lambda (existing present element)
                            (declare (ignore existing present))
                            element)
                          limit
                          "STREAM-INDEX-BY")
    (mapcar (lambda (key) (cons key (gethash key table))) order)))

(defun stream-partition (predicate stream)
  "Return (VALUES MATCHING NON-MATCHING) splitting STREAM's elements by PREDICATE,
each preserving stream order."
  (let ((matching '())
        (non-matching '())
        (current stream))
    (loop
      (let ((step (%stream-step current)))
        (when (eq step :end)
          (return (values (nreverse matching) (nreverse non-matching))))
        (if (funcall predicate (car step))
            (push (car step) matching)
            (push (car step) non-matching))
        (setf current (cdr step))))))

(defun stream-split-at (n stream)
  "Return (VALUES FIRST-N-LIST REST-STREAM) splitting STREAM after N elements. When
STREAM has fewer than N elements the first value holds them all and REST-STREAM is
empty."
  (let ((head '())
        (current stream)
        (remaining n))
    (loop
      (when (<= remaining 0) (return))
      (let ((step (%stream-step current)))
        (when (eq step :end) (return))
        (push (car step) head)
        (setf current (cdr step)
              remaining (1- remaining))))
    (values (nreverse head) current)))

(defun stream-average (stream &key (key #'identity) limit)
  "Return the arithmetic mean of (FUNCALL KEY ELEMENT) over STREAM, or NIL when
STREAM is empty. LIMIT bounds the number of input elements accepted."
  (%validate-stream-limit limit "STREAM-AVERAGE")
  (let ((sum 0)
        (count 0))
    (do-stream (element stream :limit limit :caller "STREAM-AVERAGE"
                :on-end (if (zerop count) nil (/ sum count)))
      (incf sum (funcall key element))
      (incf count))))
