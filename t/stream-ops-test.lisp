(in-package #:cl-dataflow.test)

;;; --- Operators -----------------------------------------------------------

(deftest stream-zip-with-combines-pairs
  (is (equal (stream-collect (stream-zip-with #'+ (stream-of 1 2 3) (stream-of 10 20 30)))
             '(11 22 33)))
  ;; Stops when the first stream ends.
  (is (equal (stream-collect (stream-zip-with #'+ (stream-of 1) (stream-of 10 20)))
             '(11)))
  ;; Stops when the second stream ends.
  (is (equal (stream-collect (stream-zip-with #'+ (stream-of 1 2 3) (stream-of 10)))
             '(11))))

(deftest stream-interleave-alternates-and-appends-remainder
  (is (equal (stream-collect (stream-interleave (stream-of 1 2 3) (stream-of :a :b)))
             '(1 :a 2 :b 3)))
  (is (equal (stream-collect (stream-interleave (stream-of 1) (stream-of :a :b :c)))
             '(1 :a :b :c))))

(deftest stream-take-nth-samples-every-nth
  (is (equal (stream-collect (stream-take-nth 2 (stream-range 0 7)))
             '(0 2 4 6)))
  (is (equal (stream-collect (stream-take-nth 1 (stream-of 1 2 3)))
             '(1 2 3)))
  (signals invalid-input-error (stream-take-nth 0 (stream-of 1))))

(deftest stream-dedupe-consecutive-collapses-runs
  (is (equal (stream-collect (stream-dedupe-consecutive (stream-of 1 1 2 2 2 3 1)))
             '(1 2 3 1)))
  (is (null (stream-collect (stream-dedupe-consecutive (empty-stream))))))

(deftest stream-interpose-inserts-separators
  (is (equal (stream-collect (stream-interpose 0 (stream-of 1 2 3)))
             '(1 0 2 0 3)))
  (is (equal (stream-collect (stream-interpose 0 (stream-of 1))) '(1)))
  (is (null (stream-collect (stream-interpose 0 (empty-stream))))))

;;; --- Terminal collectors -------------------------------------------------

(deftest stream-group-by-buckets-by-key
  (is (equal (stream-group-by #'evenp (stream-of 1 2 3 4 5))
             '((nil 1 3 5) (t 2 4))))
  (is (equal (stream-group-by #'evenp (stream-of 1 2) :limit 2)
             '((nil 1) (t 2))))
  (signals invalid-input-error
    (stream-group-by #'evenp (stream-of 1 2 3) :limit 2)))

(deftest stream-frequencies-counts-occurrences
  (is (equal (stream-frequencies (stream-of :a :b :a :a :b :c))
             '((:a . 3) (:b . 2) (:c . 1))))
  (signals invalid-input-error
    (stream-frequencies (stream-of :a :b :c) :limit 2)))

(deftest stream-index-by-keeps-last-per-key
  (is (equal (stream-index-by (lambda (x) (mod x 2)) (stream-of 1 2 3 4))
             '((1 . 3) (0 . 4))))
  (signals invalid-input-error
    (stream-index-by #'identity (stream-of :a :b :c) :limit 2)))

(deftest stream-partition-splits-by-predicate
  (multiple-value-bind (evens odds) (stream-partition #'evenp (stream-of 1 2 3 4 5 6))
    (is (equal evens '(2 4 6)))
    (is (equal odds '(1 3 5)))))

(deftest stream-split-at-divides-head-and-rest
  (multiple-value-bind (head rest) (stream-split-at 2 (stream-of 1 2 3 4))
    (is (equal head '(1 2)))
    (is (equal (stream-collect rest) '(3 4))))
  ;; A stream shorter than N yields it all with an empty rest.
  (multiple-value-bind (head rest) (stream-split-at 5 (stream-of 1 2))
    (is (equal head '(1 2)))
    (is (stream-empty-p rest))))

(deftest stream-average-computes-the-mean
  (is (= (stream-average (stream-of 1 2 3 4)) 5/2))
  (is (= (stream-average (stream-of '(:v 10) '(:v 20)) :key #'second) 15))
  (is (= (stream-average (stream-of 1 2 3) :limit 3) 2))
  (signals invalid-input-error
    (stream-average (stream-of 1 2 3) :limit 2))
  (is (null (stream-average (empty-stream)))))

(deftest stream-distinct-by-dedupes-on-a-key
  ;; Keep the first element for each (mod x 3) key: 1(1),4(dup),2(2),5(dup),3(0).
  (is (equal (stream-collect (stream-distinct-by (lambda (x) (mod x 3))
                                                 (stream-of 1 4 2 5 3)))
             '(1 2 3)))
  (is (null (stream-collect (stream-distinct-by #'identity (empty-stream)))))
  (signals invalid-input-error
    (stream-collect (stream-distinct-by #'identity (stream-of :a :b :c)
                                        :max-distinct 2))))
