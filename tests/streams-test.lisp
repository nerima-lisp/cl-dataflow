(in-package #:cl-dataflow.test)

;;; --- Constructors --------------------------------------------------------
(deftest
  streams-construct-from-lists-and-varargs
  (is (flow-stream-p (stream-of 1 2 3)))
  (is (equal (stream-collect (stream-of 1 2 3)) '(1 2 3)))
  (is (equal (stream-collect (list->stream '(:a :b))) '(:a :b)))
  (is (stream-empty-p (empty-stream)))
  (is (null (stream-collect (empty-stream)))))

(deftest
  stream-range-ascends-and-descends
  (is (equal (stream-collect (stream-range 0 5)) '(0 1 2 3 4)))
  (is (equal (stream-collect (stream-range 0 10 :step 3)) '(0 3 6 9)))
  (is (equal (stream-collect (stream-range 3 0 :step -1)) '(3 2 1)))
  (is (null (stream-collect (stream-range 5 5))))
  (signals invalid-input-error (stream-range 0 5 :step 0)))

;;; --- Operators -----------------------------------------------------------
(deftest
  stream-map-and-filter
  (is
    (equal
      (stream-collect
        (stream-map
          (lambda (x)
            (* x x))
          (stream-of 1 2 3 4)))
      '(1 4 9 16)))
  (is
    (equal
      (stream-collect (stream-filter #'evenp (stream-of 1 2 3 4 5 6)))
      '(2 4 6))))

(deftest
  stream-scan-emits-running-accumulations
  (is (equal (stream-collect (stream-scan #'+ 0 (stream-of 1 2 3))) '(0 1 3 6)))
  (is (equal (stream-collect (stream-scan #'+ 10 (empty-stream))) '(10))))

(deftest stream-take-and-drop
  (is (equal (stream-collect (stream-take 3 (stream-range 0 100))) '(0 1 2)))
  (is (equal (stream-collect (stream-drop 2 (stream-of 1 2 3 4))) '(3 4)))
  (is (null (stream-collect (stream-take 0 (stream-of 1 2)))))
  ;; Taking more than the source holds stops when the source is exhausted.
  (is (equal (stream-collect (stream-take 5 (stream-of 1 2))) '(1 2)))
  (is (null (stream-collect (stream-drop 5 (stream-of 1 2))))))

(deftest stream-take-while-and-drop-while
  (is (equal (stream-collect (stream-take-while (lambda (x) (< x 3)) (stream-of 1 2 3 1)))
              '(1 2)))
  (is (equal (stream-collect (stream-drop-while (lambda (x) (< x 3)) (stream-of 1 2 3 1)))
              '(3 1)))
  ;; drop-while whose predicate never fails drains the whole stream.
  (is (null (stream-collect (stream-drop-while (constantly t) (stream-of 1 2 3))))))

(deftest
  stream-distinct-keeps-first-occurrences
  (is
    (equal (stream-collect (stream-distinct (stream-of 1 2 1 3 2 4))) '(1 2 3 4)))
  (is
    (equal
      (stream-collect (stream-distinct (stream-of "a" "b" "a") :test 'equal))
      '("a" "b")))
  (signals
    invalid-input-error
    (stream-collect (stream-distinct (stream-of 1 2 3) :max-distinct 2))))

(deftest stream-flat-map-concatenates-sub-streams
  (is (equal (stream-collect
              (stream-flat-map (lambda (x) (stream-of x (* x 10)))
                                (stream-of 1 2 3)))
              '(1 10 2 20 3 30)))
  ;; Empty sub-streams are skipped.
  (is (equal (stream-collect
              (stream-flat-map (lambda (x)
                                  (if (evenp x) (stream-of x) (empty-stream)))
                                (stream-of 1 2 3 4)))
              '(2 4))))

(deftest
  stream-concat-and-zip
  (is
    (equal
      (stream-collect (stream-concat (stream-of 1 2) (empty-stream) (stream-of 3)))
      '(1 2 3)))
  (is
    (equal
      (stream-collect (stream-zip (stream-of 1 2 3) (stream-of :a :b)))
      '((1 . :a) (2 . :b)))))

(deftest
  stream-tap-observes-each-element
  (let ((seen '()))
    (is
      (equal
        (stream-collect
          (stream-tap
            (lambda (x)
              (push x seen))
            (stream-of 1 2 3)))
        '(1 2 3)))
    (is (equal (nreverse seen) '(1 2 3)))))

;;; --- Consumers -----------------------------------------------------------
(deftest
  stream-reduce-count-first-and-emptiness
  (is (= (stream-reduce #'+ 0 (stream-of 1 2 3 4)) 10))
  (is (= (stream-reduce #'+ 0 (stream-of 1 2 3) :limit 3) 6))
  (signals invalid-input-error (stream-reduce #'+ 0 (stream-of 1 2 3) :limit 2))
  (is (= (stream-count (stream-of 1 2 3)) 3))
  (is (= (stream-count (stream-of 1 2 3) :limit 3) 3))
  (signals invalid-input-error (stream-count (stream-of 1 2 3) :limit 2))
  (is (= (stream-first (stream-of 9 8 7)) 9))
  (is (eq (stream-first (empty-stream) :none) :none))
  (is (not (stream-empty-p (stream-of 1))))
  (is (stream-empty-p (empty-stream))))

(deftest
  stream-for-each-runs-side-effects
  (let ((total 0))
    (stream-for-each
      (lambda (x)
        (incf total x))
      (stream-of 1 2 3 4))
    (is (= total 10)))
  (let ((total 0))
    (stream-for-each
      (lambda (x)
        (incf total x))
      (stream-of 1 2 3)
      :limit
      3)
    (is (= total 6)))
  (signals
    invalid-input-error
    (stream-for-each
      (lambda (x)
        x)
      (stream-of 1 2 3)
      :limit
      2)))

(deftest
  stream-collect-supports-bounded-consumption
  (is (equal (stream-collect (stream-of 1 2 3) :limit 3) '(1 2 3)))
  (signals invalid-input-error (stream-collect (stream-of 1 2 3) :limit 2))
  (signals invalid-input-error (stream-collect (stream-of 1 2 3) :limit -1))
  (signals invalid-input-error (stream-count (stream-of 1 2 3) :limit 1.5))
  (signals
    invalid-input-error
    (stream-collect (stream-of 1 2 3) :limit 2 :on-limit :bogus))
  (let ((forced 0))
    (is
      (equal
        (stream-collect
          (stream-tap
            (lambda (x)
              (declare (ignore x))
              (incf forced))
            (stream-range 0 100))
          :limit
          2
          :on-limit
          :truncate)
        '(0 1)))
    (is (= forced 2))))

;;; --- Laziness and purity -------------------------------------------------
(deftest streams-are-lazy-over-unbounded-ranges
  ;; Only the first three elements of a huge range are ever forced.
  (is (equal (stream-collect (stream-take 3 (stream-map (lambda (x) (* x x))
                                                        (stream-range 0 1000000))))
              '(0 1 4))))

(deftest streams-only-force-what-a-consumer-pulls
  (let ((forced 0))
    (let ((stream (stream-tap (lambda (x) (declare (ignore x)) (incf forced))
                              (stream-range 0 1000))))
      (is (= (stream-first stream) 0))
      ;; Pulling one element forces exactly one tap, not the whole range.
      (is (= forced 1)))))

(deftest streams-can-be-consumed-more-than-once
  (let ((stream (stream-map (lambda (x) (+ x 1)) (stream-of 1 2 3))))
    (is (equal (stream-collect stream) '(2 3 4)))
    ;; Re-consuming yields the same result because pulling never mutates the source.
    (is (equal (stream-collect stream) '(2 3 4)))))

(deftest
  streams-compose-into-pipelines
  (is
    (equal
      (stream-collect
        (stream-take
          3
          (stream-filter
            #'evenp
            (stream-map
              (lambda (x)
                (* x x))
              (stream-range 1 100)))))
      '(4 16 36))))

(deftest
  stream-distinct-accepts-standard-function-designators
  (dolist (test (list 'eql #'eql 'equalp #'equalp))
    (is
      (equal
        (stream-collect (stream-distinct (stream-of 1 1.0 2 2.0) :test test))
        (if (member test (list 'equalp #'equalp) :test #'eq) (list 1 2)
          (list 1 1.0 2 2.0))))))

(deftest
  stream-distinct-preserves-custom-test-exploration
  (let ((calls '()))
    (is
      (equal
        (stream-collect
          (stream-distinct
            (stream-of 1 2 1)
            :test
            (lambda (candidate existing)
              (push (list candidate existing) calls)
              (eql candidate existing))))
        '(1 2)))
    (is (equal (nreverse calls) '((2 1) (1 2) (1 1))))))

(deftest
  stream-distinct-retains-mutable-equal-semantics
  (let* ((value (copy-seq "a"))
          (distinct (stream-distinct (stream-of value "a" "b") :test 'equal))
          (first-step (cl-dataflow::%stream-step distinct)))
    (is (eq (car first-step) value))
    (setf (char value 0) #\b)
    (is (equal (stream-collect (cdr first-step)) (list "a")))))

(deftest
  stream-distinct-max-distinct-boundaries-and-payload
  (is (null (stream-collect (stream-distinct (empty-stream) :max-distinct 0))))
  (is
    (equal
      (stream-collect (stream-distinct (stream-of 1 1 2 2) :max-distinct 2))
      '(1 2)))
  (handler-case (progn
      (stream-collect (stream-distinct (stream-of 1) :max-distinct 0))
      (is nil))
    (invalid-input-error (condition)
      (is (equal (invalid-input-expected condition) '(:at-most 0)))
      (is (eql (invalid-input-value condition) 0))
      (is
        (string= (invalid-input-detail condition) "STREAM-DISTINCT exceeded limit 0.")))))

(deftest
  stream-distinct-can-recollect-the-same-derived-stream
  (let ((distinct (stream-distinct (stream-of 1 2 1 3 2) :test #'eql)))
    (is (equal (stream-collect distinct) '(1 2 3)))
    (is (equal (stream-collect distinct) '(1 2 3)))))
