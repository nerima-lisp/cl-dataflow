(in-package #:cl-dataflow-kit)

;;;; Search, predicate, and combinatorial helpers over streams: first-match index,
;;;; a "no element matches" predicate, the most frequent element, and the Cartesian
;;;; product of two streams. Consumers iterate; STREAM-CARTESIAN stays lazy.

(defun stream-find-index (predicate stream &key limit)
  "Return the 0-based index of the first element of STREAM satisfying PREDICATE, or
NIL when none does. LIMIT bounds the number of input elements accepted."
  (%validate-stream-limit limit "STREAM-FIND-INDEX")
  (let ((index 0))
    (do-stream (element stream :limit limit :caller "STREAM-FIND-INDEX" :on-end nil)
      (when (funcall predicate element) (return index))
      (incf index))))

(defun stream-none-p (predicate stream &key limit)
  "Return true when no element of STREAM satisfies PREDICATE (true for an empty
stream). LIMIT bounds the number of input elements accepted."
  (%validate-stream-limit limit "STREAM-NONE-P")
  (do-stream (element stream :limit limit :caller "STREAM-NONE-P" :on-end t)
    (when (funcall predicate element) (return nil))))

(defun stream-mode (stream &key (test 'equal) limit)
  "Return the most frequently occurring element of STREAM (the first-seen element
wins ties), or NIL when STREAM is empty. TEST is the hash-table equality used to
group elements. LIMIT bounds the number of input elements accepted."
  (%validate-stream-limit limit "STREAM-MODE")
  (let ((counts (make-hash-table :test test))
        (order '()))
    (do-stream (element stream :limit limit :caller "STREAM-MODE" :on-end nil)
      (unless (nth-value 1 (gethash element counts))
        (push element order)
        (setf (gethash element counts) 0))
      (incf (gethash element counts)))
    (let ((best nil)
          (best-count -1))
      (dolist (element (nreverse order) best)
        (when (> (gethash element counts) best-count)
          (setf best-count (gethash element counts)
                best element))))))

(defun stream-cartesian (stream-a stream-b)
  "Return a stream of (A . B) conses for every pair drawn from STREAM-A and
STREAM-B, with B varying fastest. STREAM-B is re-consumed once per element of
STREAM-A (streams are pure, so this is safe)."
  (stream-flat-map (lambda (a)
                     (stream-map (lambda (b) (cons a b)) stream-b))
                   stream-a))
