(in-package #:cl-dataflow.test)

(deftest
  subjects-emit-to-subscribers-in-order
  (let* ((subject (make-subject))
        (collector (subject-collect subject)))
    (is (subject-p subject))
    (is (= (subject-subscriber-count subject) 1))
    (subject-emit subject 1)
    (subject-emit subject 2)
    (subject-emit subject 3)
    (is (equal (funcall collector) '(1 2 3)))))

(deftest
  subject-collect-supports-bounded-history
  (let* ((subject (make-subject))
        (collector (subject-collect subject :limit 2 :on-limit :drop-newest)))
    (subject-emit subject 1)
    (subject-emit subject 2)
    (subject-emit subject 3)
    (is (equal (funcall collector) '(1 2)))))

(deftest
  subject-collect-errors-when-limit-is-exceeded
  (let* ((subject (make-subject))
        (collector (subject-collect subject :limit 2)))
    (subject-emit subject 1)
    (subject-emit subject 2)
    (signals invalid-input-error (subject-emit subject 3))
    (is (equal (funcall collector) '(1 2)))))

(deftest
  subject-unsubscribe-stops-delivery
  (let* ((subject (make-subject))
        (seen '())
        (handler
        (lambda (value)
          (push value seen))))
    (subject-subscribe subject handler)
    (subject-emit subject :a)
    (subject-unsubscribe subject handler)
    (subject-emit subject :b)
    (is (equal seen '(:a)))
    (is (zerop (subject-subscriber-count subject)))))

(deftest
  subject-subscribe-preserves-order-after-unsubscribe
  (let ((subject (make-subject))
        (seen '()))
    (labels ((record (tag)
              (lambda (value)
            (push (cons tag value) seen))))
      (let ((first (record :first))
            (second (record :second))
            (third (record :third)))
        (subject-subscribe subject first)
        (subject-subscribe subject second)
        (subject-unsubscribe subject first)
        (subject-subscribe subject third)
        (subject-emit subject :value)
        (is (equal (reverse seen) '((:second . :value) (:third . :value))))
        (is (= (subject-subscriber-count subject) 2))))))

;; Single-source operators (and their compositions) as declarative specs; see
;; DEFINE-SINGLE-SOURCE-SUBJECT-TESTS. SUBJECT-MERGE below has two sources and
;; stays a hand-written DEFTEST.
(define-single-source-subject-tests
  (subject-map-transforms-emissions
   (lambda (s) (subject-map s (lambda (x) (* x 2)))) (1 5) (2 10))
  (subject-filter-drops-non-matching
   (lambda (s) (subject-filter s #'evenp)) (1 2 3 4 5 6) (2 4 6))
  ;; A small reactive pipeline: source -> filter evens -> map (*10).
  (reactive-graph-chains-operators
   (lambda (s) (subject-map (subject-filter s #'evenp) (lambda (x) (* x 10))))
   (1 2 3 4) (20 40)))

(deftest
  subject-merge-combines-sources
  (let* ((a (make-subject))
        (b (make-subject))
        (merged (subject-merge a b))
        (collector (subject-collect merged)))
    (subject-emit a 1)
    (subject-emit b 2)
    (subject-emit a 3)
    (is (equal (funcall collector) '(1 2 3)))))

(deftest subject-emit-empty-and-return-value
  (let ((subject (make-subject)))
    (is (eq (subject-emit subject :value) subject))))

(deftest subject-emit-self-unsubscribe-uses-entry-snapshot
  (let ((subject (make-subject))
        (seen '())
        self)
    (setf self (lambda (value)
        (push (list :self value) seen)
        (subject-unsubscribe subject self)))
    (subject-subscribe subject self)
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :other value) seen)))
    (is (eq (subject-emit subject :first) subject))
    (subject-emit subject :second)
    (is (equal (nreverse seen) '((:self :first) (:other :first) (:other :second))))))

(deftest subject-emit-other-unsubscribe-uses-entry-snapshot
  (let ((subject (make-subject))
        (seen '())
        other)
    (setf other (lambda (value)
        (push (list :other value) seen)))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :first value) seen)
        (subject-unsubscribe subject other)))
    (subject-subscribe subject other)
    (subject-emit subject :first)
    (subject-emit subject :second)
    (is (equal (nreverse seen) '((:first :first) (:other :first) (:first :second))))))

(deftest subject-emit-subscribe-during-emit-uses-entry-snapshot
  (let ((subject (make-subject))
        (seen '())
        (subscribed nil))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :first value) seen)
        (unless subscribed
          (setf subscribed t)
          (subject-subscribe
            subject
            (lambda (late-value)
              (push (list :late late-value) seen))))))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :second value) seen)))
    (subject-emit subject :first)
    (subject-emit subject :second)
    (is
      (equal
        (nreverse seen)
        '((:first :first)
          (:second :first)
          (:first :second)
          (:second :second)
          (:late :second))))))

(deftest subject-emit-reentrant-after-subscribe-sees-latest-registry
  (let ((subject (make-subject))
        (seen '()))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :first value) seen)
        (when (eq value :outer)
          (subject-subscribe
            subject
            (lambda (late-value)
              (push (list :late late-value) seen)))
          (subject-emit subject :inner))))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :second value) seen)))
    (subject-emit subject :outer)
    (is
      (equal
        (nreverse seen)
        '((:first :outer)
          (:first :inner)
          (:second :inner)
          (:late :inner)
          (:second :outer))))))

(deftest subject-emit-reentrant-after-unsubscribe-sees-latest-registry
  (let ((subject (make-subject))
        (seen '())
        second)
    (setf second (lambda (value)
        (push (list :second value) seen)))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :first value) seen)
        (when (eq value :outer)
          (subject-unsubscribe subject second)
          (subject-emit subject :inner))))
    (subject-subscribe subject second)
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :third value) seen)))
    (subject-emit subject :outer)
    (is
      (equal
        (nreverse seen)
        '((:first :outer)
          (:first :inner)
          (:third :inner)
          (:second :outer)
          (:third :outer))))))

(deftest subject-emit-exception-skips-followers-and-retains-registry
  (let ((subject (make-subject))
        (seen '()))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :first value) seen)))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :error value) seen)
        (error "Intentional subject callback failure.")))
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :follower value) seen)))
    (signals simple-error (subject-emit subject :value))
    (is (equal (nreverse seen) '((:first :value) (:error :value))))
    (is (= (subject-subscriber-count subject) 3))))

(deftest subject-unsubscribe-removes-all-duplicate-subscriptions
  (let* ((subject (make-subject))
        (seen '())
        (duplicate
        (lambda (value)
          (push (list :duplicate value) seen))))
    (subject-subscribe subject duplicate)
    (subject-subscribe subject duplicate)
    (subject-subscribe
      subject
      (lambda (value)
        (push (list :other value) seen)))
    (is (= (subject-subscriber-count subject) 3))
    (subject-emit subject :before)
    (is
      (equal
        (nreverse seen)
        '((:duplicate :before) (:duplicate :before) (:other :before))))
    (setf seen nil)
    (is (eq (subject-unsubscribe subject duplicate) subject))
    (is (= (subject-subscriber-count subject) 1))
    (subject-emit subject :after)
    (is (equal seen '((:other :after))))))
