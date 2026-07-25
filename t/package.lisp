(defpackage #:cl-dataflow.test
  (:use #:cl #:cl-dataflow)
  (:import-from #:cl-weave
                #:benchmark
                #:benchmark-result-samples
                #:defmatcher
                #:expect
                #:fail
                #:gen-integer
                #:gen-list
                #:gen-member
                #:gen-sexp
                #:gen-state-machine
                #:gen-tuple
                #:it-fuzz
                #:it-property
                #:logic-query
                #:mean-ms
                #:mutation-summary
                #:run-mutations
                #:signals
                #:*snapshot-directory*
                #:mock-restore
                #:spy-on)
  (:import-from #:process-kit
                #:run
                #:process-result-exit-code
                #:process-result-stdout
                #:process-result-stderr
                #:process-result-timed-out-p)
  (:export #:run-tests))

