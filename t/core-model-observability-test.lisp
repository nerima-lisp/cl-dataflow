(in-package #:cl-dataflow.test)

(deftest context-observability-helpers-expose-chronological-data
  (let* ((boot-event (make-event "boot"))
         (done-event (make-event "done"))
         (audit-effect (make-effect "audit"))
         (notify-effect (make-effect "notify"))
         (context (make-context :events (list done-event boot-event)
                                :effects (list notify-effect audit-effect)
                                :trace (list '(:effect "notify")
                                             '(:event "boot"))))
         (events-in-order (context-events-in-order context))
         (effects-in-order (context-effects-in-order context))
         (trace-in-order (context-trace-in-order context)))
    (is (equal (mapcar #'event-type events-in-order) '("boot" "done")))
    (is (equal (context-event-types context) '("boot" "done")))
    (is (equal (mapcar #'effect-type effects-in-order) '("audit" "notify")))
    (is (equal (context-effect-types context) '("audit" "notify")))
    (is (equal (mapcar #'event-type (context-events-of-type context "boot"))
               '("boot")))
    (is (equal (mapcar #'effect-type (context-effects-of-type context "notify"))
               '("notify")))
    (is (equal (event-type (context-last-event context)) "done"))
    (is (equal (effect-type (context-last-effect context)) "notify"))
    (is (equal trace-in-order '((:event "boot")
                                (:effect "notify"))))))

(deftest context-observability-helpers-return-empty-results-without-matches
  (let ((context (make-context
                  :events (list (make-event "boot"))
                  :effects (list (make-effect "audit")))))
    (is (null (context-events-of-type context "missing")))
    (is (null (context-effects-of-type context "missing")))
    (is (null (context-last-event (make-context))))
    (is (null (context-last-effect (make-context))))))

(define-snapshot-freshness-test context-event-observability-helpers-copy-snapshot-entries
  ((boot-event (make-event "boot" :payload '(:id 1)))
   (done-event (make-event "done" :payload '(:id 2)))
   (context (make-context :events (list done-event boot-event)))
   (events-snapshot (context-events-in-order context))
   (last-event (context-last-event context)))
  ((first events-snapshot)
   (first (context-events-in-order context)))
  (last-event
   (context-last-event context)))

(define-snapshot-freshness-test context-effect-observability-helpers-copy-snapshot-entries
  ((audit-effect (make-effect "audit" :payload '(:message "ok")))
   (notify-effect (make-effect "notify" :payload '(:message "done")))
   (context (make-context :effects (list notify-effect audit-effect)))
   (effects-snapshot (context-effects-in-order context))
   (last-effect (context-last-effect context)))
  ((first effects-snapshot)
   (first (context-effects-in-order context)))
  (last-effect
   (context-last-effect context)))

(define-snapshot-freshness-test context-trace-observability-helpers-copy-snapshot-entries
  ((context (make-context :trace (list (list :event "boot"
                                             :payload (list :id 1))
                                       (list :effect "notify"
                                             :result (list :message "done")))))
   (trace-snapshot (context-trace-in-order context)))
  ((first trace-snapshot)
   (first (context-trace-in-order context))))

(define-snapshot-payload-isolation-test context-event-snapshots-are-independent
  ((boot-event (make-event "boot" :payload '(:id 1)))
   (context (make-context :events (list boot-event))))
  (events-snapshot (context-events-in-order context))
  (event-payload (first events-snapshot))
  (event-payload (first (context-events context)))
  '(:id 1))

(define-snapshot-payload-isolation-test context-effect-snapshots-are-independent
  ((audit-effect (make-effect "audit" :payload '(:message "ok")))
   (context (make-context :effects (list audit-effect))))
  (effects-snapshot (context-effects-in-order context))
  (effect-payload (first effects-snapshot))
  (effect-payload (first (context-effects context)))
  '(:message "ok"))

(define-snapshot-isolation-test context-trace-snapshots-are-independent
  ((context (make-context :trace (list (list :event "boot"
                                             :payload (list :id 1))))))
  (trace-snapshot (context-trace-in-order context))
  (set-plist-entry (first trace-snapshot) :payload (list :mutated 1))
  (assert-context-first-trace-entry context
    (:payload '(:id 1))))

(define-snapshot-payload-isolation-test context-last-event-snapshot-is-independent
  ((boot-event (make-event "boot" :payload '(:id 1)))
   (context (make-context :events (list boot-event))))
  (last-event (context-last-event context))
  (event-payload last-event)
  (event-payload (context-last-event context))
  '(:id 1))

(define-snapshot-payload-isolation-test context-last-effect-snapshot-is-independent
  ((audit-effect (make-effect "audit" :payload '(:message "ok")))
   (context (make-context :effects (list audit-effect))))
  (last-effect (context-last-effect context))
  (effect-payload last-effect)
  (effect-payload (context-last-effect context))
  '(:message "ok"))
