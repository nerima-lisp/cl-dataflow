(in-package #:cl-dataflow.test)

;;;; Property-based tests treating the equivalent list operation as the
;;;; reference model for each stream operator/consumer: for any generated
;;;; finite list, forcing the stream built from it must agree with the plain
;;;; list computation. Complements the hand-written edge-case coverage in
;;;; streams-test.lisp (empty streams, limits, laziness) rather than replacing
;;;; it.

(it-property "stream-map over any list matches mapcar"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-collect (stream-map #'1+ (list->stream numbers)))
             (mapcar #'1+ numbers))))

(it-property "stream-filter over any list matches remove-if-not"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-collect (stream-filter #'evenp (list->stream numbers)))
             (remove-if-not #'evenp numbers))))

(it-property "stream-reduce over any list matches reduce"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-reduce #'+ 0 (list->stream numbers))
             (reduce #'+ numbers :initial-value 0))))

(it-property "stream-count over any list matches length"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-count (list->stream numbers))
             (length numbers))))

(it-property "stream-sum over any list matches apply +"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-sum (list->stream numbers))
             (apply #'+ numbers))))

(it-property "stream-take n over any list matches bounded subseq"
    ((numbers (gen-list (gen-integer :min -100 :max 100)))
     (n (gen-integer :min 0 :max 20)))
  (is (equal (stream-collect (stream-take n (list->stream numbers)))
             (subseq numbers 0 (min n (length numbers))))))

(it-property "stream-drop n over any list matches nthcdr bounded by length"
    ((numbers (gen-list (gen-integer :min -100 :max 100)))
     (n (gen-integer :min 0 :max 20)))
  (is (equal (stream-collect (stream-drop n (list->stream numbers)))
             (nthcdr (min n (length numbers)) numbers))))

(it-property "stream-zip over any two lists matches mapcar cons"
    ((a (gen-list (gen-integer :min -50 :max 50)))
     (b (gen-list (gen-integer :min -50 :max 50))))
  (is (equal (stream-collect (stream-zip (list->stream a) (list->stream b)))
             (mapcar #'cons a b))))

(it-property "stream-every over any list matches every"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-every #'evenp (list->stream numbers))
             (every #'evenp numbers))))

(it-property "stream-some over any list matches some"
    ((numbers (gen-list (gen-integer :min -100 :max 100))))
  (is (equal (stream-some #'evenp (list->stream numbers))
             (some #'evenp numbers))))
