(in-package #:cl-dataflow.test)

(deftest graph-articulation-points-finds-cut-vertices
  ;; In the path a -> b -> c, b is the cut vertex; the endpoints are not.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (equal (graph-articulation-points graph) '("b"))))
  ;; A cycle has no articulation points.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (c a)))
    (is (null (graph-articulation-points graph))))
  ;; A hub connecting two leaves is a cut vertex.
  (with-graph-fixture (graph
                       ((hub "hub") (l "left") (r "right"))
                       :edges ((hub l) (hub r)))
    (is (equal (graph-articulation-points graph) '("hub")))))

(deftest graph-bridges-finds-critical-connections
  ;; Every edge of a path is a bridge.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (equal (graph-bridges graph) '(("a" "b") ("b" "c")))))
  ;; A cycle has no bridges.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (c a)))
    (is (null (graph-bridges graph)))))

(deftest graph-bridges-handles-self-loops-and-antiparallel-edges
  ;; Self-loops are ignored; anti-parallel a<->b collapse to one undirected
  ;; connection, and that single connection to the isolated cycle {a,b} is not a
  ;; bridge to the rest because there is none -- but the a<->b pair, if it is the
  ;; only link, is critical. Here d hangs off b by a single edge (a bridge).
  (with-graph-fixture (graph
                       ((a "a") (b "b") (d "d"))
                       :edges ((a b) (b a) (a a) (b d)))
    ;; a<->b has two edges; removing both disconnects them only if there's no other
    ;; path -- there isn't, so it is a critical connection. b->d is a lone bridge.
    (is (equal (graph-bridges graph) '(("a" "b") ("b" "d"))))
    ;; b is a cut vertex (it links d to the a<->b pair).
    (is (equal (graph-articulation-points graph) '("b")))))

(deftest graph-dominators-builds-the-immediate-dominator-tree
  ;; Diamond under a with a tail: a dominates b, c, and their merge d (both paths
  ;; from a to d run through a), and d dominates e. Exercises a merge node with
  ;; two processed predecessors (the intersect step) and a re-converging path.
  (with-graph-fixture (graph
                       ((r "r") (a "a") (b "b") (c "c") (d "d") (e "e"))
                       :edges ((r a) (a b) (a c) (b d) (c d) (d e)))
    (is (equal (graph-dominators graph "r")
               '(("a" . "r") ("b" . "a") ("c" . "a") ("d" . "a") ("e" . "d")))))
  ;; A back edge c -> a makes the graph cyclic: on the first pass a's predecessor
  ;; c has no dominator yet (the skipped-predecessor case), and the fixpoint loop
  ;; must run a second pass. a still dominates b, c, and d.
  (with-graph-fixture (graph
                       ((r "r") (a "a") (b "b") (c "c") (d "d"))
                       :edges ((r a) (a b) (b c) (c a) (a d)))
    (is (equal (graph-dominators graph "r")
               '(("a" . "r") ("b" . "a") ("c" . "b") ("d" . "a")))))
  ;; Nodes unreachable from the source have no dominator and are omitted.
  (with-graph-fixture (graph
                       ((r "r") (a "a") (island "island"))
                       :edges ((r a)))
    (is (equal (graph-dominators graph "r") '(("a" . "r")))))
  ;; A lone source dominates nothing, so the map is empty.
  (with-graph-fixture (graph ((r "r")))
    (is (null (graph-dominators graph "r")))))

(deftest graph-post-dominators-builds-the-reverse-dominator-tree
  ;; In the chain a -> b -> c toward sink c, every path from a to c runs through
  ;; b, and every path from b through c: ipdom(a)=b, ipdom(b)=c.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (equal (graph-post-dominators graph "c")
               '(("a" . "b") ("b" . "c")))))
  ;; A diamond that reconverges at the sink d: both branches must pass through d,
  ;; and a's paths reconverge only at d, so every node's post-dominator is d.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    (is (equal (graph-post-dominators graph "d")
               '(("a" . "d") ("b" . "d") ("c" . "d")))))
  ;; A node that cannot reach the sink has no post-dominator and is omitted.
  (with-graph-fixture (graph
                       ((a "a") (sink "sink") (stray "stray"))
                       :edges ((a sink)))
    (is (equal (graph-post-dominators graph "sink") '(("a" . "sink")))))
  ;; A lone sink post-dominates nothing.
  (with-graph-fixture (graph ((sink "sink")))
    (is (null (graph-post-dominators graph "sink")))))
