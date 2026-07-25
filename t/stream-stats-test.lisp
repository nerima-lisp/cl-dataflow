(in-package #:cl-dataflow.test)

(deftest stream-flatten-concatenates-lists
  (is (equal (stream-collect (stream-flatten (stream-of '(1 2) '(3) '() '(4 5))))
             '(1 2 3 4 5)))
  (is (null (stream-collect (stream-flatten (empty-stream))))))

(deftest stream-scan1-seeds-from-the-first-element
  (is (equal (stream-collect (stream-scan1 #'+ (stream-of 1 2 3 4)))
             '(1 3 6 10)))
  (is (null (stream-collect (stream-scan1 #'+ (empty-stream))))))

(deftest stream-count-if-counts-matches
  (is (= (stream-count-if #'evenp (stream-of 1 2 3 4 5 6)) 3))
  (is (= (stream-count-if #'evenp (stream-of 1 2 3 4) :limit 4) 2))
  (signals invalid-input-error
    (stream-count-if #'evenp (stream-of 1 2 3) :limit 2))
  (is (= (stream-count-if #'evenp (empty-stream)) 0)))

(deftest stream-variance-and-stddev
  ;; values 1..5 have mean 3 and population variance (4+1+0+1+4)/5 = 2.
  (is (= (stream-variance (stream-of 1 2 3 4 5)) 2))
  (is (< (abs (- (stream-stddev (stream-of 1 2 3 4 5)) (sqrt 2))) 1d-9))
  (is (null (stream-variance (empty-stream))))
  (is (null (stream-stddev (empty-stream))))
  ;; Keyed variance over structured elements.
  (is (= (stream-variance (stream-of '(:v 2) '(:v 4)) :key #'second) 1))
  (signals invalid-input-error
    (stream-variance (stream-of 1 2 3) :limit 2))
  (signals invalid-input-error
    (stream-stddev (stream-of 1 2 3) :limit 2)))

(deftest stream-median-of-odd-and-even-counts
  (is (= (stream-median (stream-of 3 1 2)) 2))
  (is (= (stream-median (stream-of 4 1 3 2)) 5/2))
  (signals invalid-input-error
    (stream-median (stream-of 1 2 3) :limit 2))
  (is (null (stream-median (empty-stream)))))
