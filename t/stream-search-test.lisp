(in-package #:cl-dataflow.test)

(deftest stream-find-index-locates-the-first-match
  (is (= (stream-find-index #'evenp (stream-of 1 3 4 6)) 2))
  (is (= (stream-find-index #'evenp (stream-of 1 3 4 6) :limit 3) 2))
  (is (null (stream-find-index #'evenp (stream-of 1 3 5))))
  (is (= (stream-find-index (constantly t) (stream-of :a :b)) 0))
  (signals invalid-input-error
    (stream-find-index #'evenp (stream-of 1 3 5) :limit 2)))

(deftest stream-none-p-checks-absence
  (is (stream-none-p #'evenp (stream-of 1 3 5)))
  (is (not (stream-none-p #'evenp (stream-of 1 2 3))))
  (is (not (stream-none-p #'evenp (stream-of 1 2 3) :limit 2)))
  (is (stream-none-p #'evenp (empty-stream)))
  (signals invalid-input-error
    (stream-none-p #'evenp (stream-of 1 3 5) :limit 2)))

(deftest stream-mode-finds-the-most-frequent-element
  (is (equal (stream-mode (stream-of :a :b :a :a :b)) :a))
  (is (equal (stream-mode (stream-of :a :b :a) :limit 3) :a))
  (signals invalid-input-error
    (stream-mode (stream-of :a :b :c) :limit 2))
  ;; First-seen element wins a tie.
  (is (equal (stream-mode (stream-of :x :y :x :y)) :x))
  (is (null (stream-mode (empty-stream)))))

(deftest stream-cartesian-pairs-every-combination
  (is (equal (stream-collect (stream-cartesian (stream-of 1 2) (stream-of :a :b)))
             '((1 . :a) (1 . :b) (2 . :a) (2 . :b))))
  (is (null (stream-collect (stream-cartesian (empty-stream) (stream-of :a)))))
  (is (null (stream-collect (stream-cartesian (stream-of 1) (empty-stream))))))
