(in-package #:cl-dataflow.test)

;;; --- Generators ----------------------------------------------------------

(deftest stream-iterate-and-repeat-are-lazy-and-infinite
  (is (equal (stream-collect (stream-take 4 (stream-iterate (lambda (x) (* x 2)) 1)))
             '(1 2 4 8)))
  (is (equal (stream-collect (stream-take 3 (stream-repeat :x)))
             '(:x :x :x))))

(deftest stream-cycle-repeats-and-handles-empty
  (is (equal (stream-collect (stream-take 5 (stream-cycle '(1 2))))
             '(1 2 1 2 1)))
  (is (stream-empty-p (stream-cycle '()))))

(deftest stream-enumerate-pairs-indices
  (is (equal (stream-collect (stream-enumerate (stream-of :a :b :c)))
             '((0 . :a) (1 . :b) (2 . :c))))
  (is (equal (stream-collect (stream-enumerate (stream-of :a :b) :start 10))
             '((10 . :a) (11 . :b))))
  (is (null (stream-collect (stream-enumerate (empty-stream))))))

(deftest stream-unfold-generates-until-nil
  (is (equal (stream-collect
              (stream-unfold (lambda (n) (when (> n 0) (cons n (1- n)))) 3))
             '(3 2 1)))
  ;; A seed that stops immediately yields the empty stream.
  (is (null (stream-collect (stream-unfold (lambda (n) (declare (ignore n)) nil) 5)))))

;;; --- Windowing and grouping ----------------------------------------------

(deftest stream-chunk-groups-fixed-size-runs
  (is (equal (stream-collect (stream-chunk 2 (stream-of 1 2 3 4 5)))
             '((1 2) (3 4) (5))))
  (is (null (stream-collect (stream-chunk 3 (empty-stream)))))
  (signals invalid-input-error (stream-chunk 0 (stream-of 1))))

(deftest stream-window-slides-over-elements
  (is (equal (stream-collect (stream-window 2 (stream-of 1 2 3 4)))
             '((1 2) (2 3) (3 4))))
  (let ((windows (stream-collect (stream-window 2 (stream-of 1 2 3)))))
    (setf (car (first windows)) :changed)
    (is (equal (second windows) '(2 3))))
  ;; A stream shorter than the window yields nothing.
  (is (null (stream-collect (stream-window 3 (stream-of 1 2)))))
  (signals invalid-input-error (stream-window 0 (stream-of 1))))

(deftest stream-window-advances-without-restarting-source
  (let ((forced 0))
    (is (equal (stream-collect
                (stream-take 3
                  (stream-window 2
                    (stream-tap (lambda (x)
                                  (declare (ignore x))
                                  (incf forced))
                                (stream-range 0 10)))))
               '((0 1) (1 2) (2 3))))
    (is (= forced 4))))

(deftest stream-partition-by-groups-consecutive-keys
  (is (equal (stream-collect (stream-partition-by #'evenp (stream-of 1 3 2 4 5)))
             '((1 3) (2 4) (5))))
  (is (null (stream-collect (stream-partition-by #'identity (empty-stream))))))

;;; --- Aggregate consumers -------------------------------------------------

(deftest stream-sum-adds-elements
  (is (= (stream-sum (stream-of 1 2 3 4)) 10))
  (is (= (stream-sum (stream-of 1 2 3) :limit 3) 6))
  (is (= (stream-sum (empty-stream)) 0))
  (is (= (stream-sum (stream-of '(:n 3) '(:n 4)) :key #'second) 7))
  (signals invalid-input-error
    (stream-sum (stream-of 1 2 3) :limit 2)))

(deftest stream-min-and-max-find-extremes
  (is (= (stream-min (stream-of 3 1 2)) 1))
  (is (= (stream-min (stream-of 3 1 2) :limit 3) 1))
  (is (= (stream-max (stream-of 3 1 2)) 3))
  (is (= (stream-max (stream-of 3 1 2) :limit 3) 3))
  (is (eq (stream-min (empty-stream) :default :none) :none))
  (is (eq (stream-max (empty-stream) :default :none) :none))
  ;; Keyed extremes return the whole element.
  (is (equal (stream-min (stream-of '(:score 5) '(:score 2) '(:score 9)) :key #'second)
             '(:score 2)))
  (signals invalid-input-error
    (stream-min (stream-of 3 1 2) :limit 2))
  (signals invalid-input-error
    (stream-max (stream-of 3 1 2) :limit 2)))

(deftest stream-find-and-some
  (is (= (stream-find #'evenp (stream-of 1 3 4 6)) 4))
  (is (= (stream-find #'evenp (stream-of 1 3 4 6) :limit 3) 4))
  (is (= (stream-find #'evenp (stream-of 1 3 4 6) nil :limit 3) 4))
  (is (eq (stream-find #'evenp (stream-of 1 3 5) :none) :none))
  (signals invalid-input-error
    (stream-find #'evenp (stream-of 1 3 5) :none :limit 2))
  (signals invalid-input-error
    (stream-find #'evenp (stream-of 1 3 5) :limit 2 :extra))
  (signals invalid-input-error
    (stream-find #'evenp (stream-of 1 3 5) :none :limit))
  (signals invalid-input-error
    (stream-find #'evenp (stream-of 1 3 5) :none :bogus 2))
  (is (= (stream-some (lambda (x) (and (evenp x) (* x 100))) (stream-of 1 3 4)) 400))
  (is (= (stream-some (lambda (x) (and (evenp x) (* x 100)))
                      (stream-of 1 3 4)
                      :limit 3)
         400))
  (is (null (stream-some (lambda (x) (and (evenp x) x)) (stream-of 1 3 5))))
  (signals invalid-input-error
    (stream-some (lambda (x) (and (evenp x) x)) (stream-of 1 3 5) :limit 2)))

(deftest stream-every-checks-all
  (is (stream-every #'evenp (stream-of 2 4 6)))
  (is (not (stream-every #'evenp (stream-of 2 3 4))))
  (is (not (stream-every #'evenp (stream-of 2 3 4) :limit 2)))
  (is (stream-every #'evenp (empty-stream)))
  (signals invalid-input-error
    (stream-every #'evenp (stream-of 2 4 6) :limit 2)))

(deftest stream-last-and-nth
  (is (= (stream-last (stream-of 1 2 3)) 3))
  (is (= (stream-last (stream-of 1 2 3) nil :limit 3) 3))
  (is (eq (stream-last (empty-stream) :none) :none))
  (signals invalid-input-error
    (stream-last (stream-of 1 2 3) nil :limit 2))
  (is (= (stream-nth 2 (stream-of :a :b 42 :d)) 42))
  (is (eq (stream-nth 10 (stream-of :a :b) :none) :none))
  (is (eq (stream-nth 0 (stream-of :first :second)) :first)))
