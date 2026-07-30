{
  description = "Composable Common Lisp dataflow runtime";

  # Every sibling input is pinned to a release tag. A bare
  # `github:nerima-lisp/<name>` follows that repo's default branch, so an
  # upstream push to main breaks this repo's CI without warning.
  #
  # Siblings are pulled with `flake = false` wherever only their source tree is
  # needed, per DEPENDENCY_POLICY.md. A `flake = true` sibling drags its entire
  # transitive input graph into flake.lock: this file used to declare 6 siblings
  # and produce a 78-node lock, holding 16 copies of cl-weave and 13 each of
  # paredit-cli, rust-overlay and treefmt-nix. `inputs.nixpkgs.follows` does not
  # help there -- it was already set on every flake input, which is why there
  # was only ever one nixpkgs node.
  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # treefmt drives `nix fmt` and the `checks.<system>.formatting` gate.
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # cl-nix-forge is the org's Nix flake-library for building/testing/
    # composing ASDF systems -- "crane for Common Lisp". It builds
    # packages.default (compiled fasls, dependency-graph-resolved
    # CL_SOURCE_REGISTRY via lispDependencies/lispCheckDependencies), the docs
    # site, and the checks below, replacing what used to be hand-rolled,
    # three-times-duplicated CL_SOURCE_REGISTRY string concatenation across
    # `checks`/`apps`/`devShells`.
    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.4.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    # cl-prolog backs the graph edge relation. Only its source tree is used
    # (given its own `lispDerivation` build below, since it ships no fasls of
    # its own -- see that build's comment for why a bare `fromDerivation`
    # wrap doesn't work here): it is architecture-independent Lisp with its
    # .asd at the repository root, and upstream ships Linux-only per-system
    # packages, so there is nothing to gain from evaluating its flake.
    cl-prolog = {
      url = "github:nerima-lisp/cl-prolog/v1.1.0";
      flake = false;
    };

    # cl-weave stays `flake = true`: checks.default and checks.coverage invoke
    # its `cl-weave` executable (packages.default), and every build below
    # needs its ASDF source tree (packages.cl-weave) -- both are packages
    # outputs, so only a flake input provides them.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
      # cl-weave declares `github:takeokunn/paredit-cli` with no tag, so
      # without this override our lock would carry an untagged reference to a
      # personal fork's default branch (plus a second rust-overlay and
      # treefmt-nix). Nothing we build out of cl-weave uses paredit-cli.
      inputs.paredit-cli.follows = "paredit-cli";
    };

    # paredit-cli stays `flake = true`: checks.paredit-lint calls its
    # `lib.<system>.mkLintCheck`, which is a flake output.
    paredit-cli = {
      url = "github:nerima-lisp/paredit-cli/v1.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    # Test-only, and source-only: t/core-runtime-example-test.lisp runs the
    # example scripts as subprocesses through cl-process-kit. Its .asd sits at
    # the repository root, so the source tree is directly usable.
    cl-process-kit = {
      url = "github:nerima-lisp/cl-process-kit/v1.0.1";
      flake = false;
    };

    # cl-process-kit's own base ASDF system (:depends-on (:asdf :cl-boundary-kit
    # :cl-log-kit)) needs these two; they are never loaded or called directly by
    # cl-dataflow (no API usage, no adapter) -- only their source trees need to
    # be on CL_SOURCE_REGISTRY so ASDF can resolve cl-process-kit's :depends-on.
    # cl-tty-kit is NOT a dependency here: it's only required by the optional
    # cl-process-kit/pty subsystem, which cl-dataflow never loads.
    cl-boundary-kit = {
      url = "github:nerima-lisp/cl-boundary-kit/v1.0.0";
      flake = false;
    };
    cl-log-kit = {
      url = "github:nerima-lisp/cl-log-kit/v1.0.0";
      flake = false;
    };

    # cl-concurrent-kit backs RUN-PIPELINE's :PARALLEL mode
    # (src/pipeline-parallel.lisp): a real runtime dependency, not test- or
    # build-only. Stays `flake = true`: its `packages.cl-concurrent-kit`
    # output (a compiled ASDF system, `pkgs.sbcl.buildASDFSystem`) is the only
    # way to get its source onto CL_SOURCE_REGISTRY -- confirmed by building
    # it directly and inspecting the result: `cl-concurrent-kit.asd` sits at
    # its outPath root alongside the compiled fasls, the same
    # source-tree-at-root shape as cl-weave's `packages.cl-weave`.
    cl-concurrent-kit = {
      url = "github:nerima-lisp/cl-concurrent-kit/v0.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      cl-nix-forge,
      cl-prolog,
      cl-weave,
      paredit-cli,
      cl-process-kit,
      cl-boundary-kit,
      cl-log-kit,
      cl-concurrent-kit,
    }:
    let
      # Only what is verified: x86_64-linux by CI, aarch64-darwin by the
      # maintainer's local `nix flake check`. aarch64-linux and x86_64-darwin
      # are not declared because nothing runs them, and a platform no runner
      # can build makes `nix flake check --all-systems` fail with "platform
      # mismatch" rather than skip it. See ADR-0078.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems =
        function: nixpkgs.lib.genAttrs systems (system: function (import nixpkgs { inherit system; }));

      # Single source of truth for the package version: the `:version` form in
      # cl-dataflow.asd. A release edits that one line and every Nix package
      # (default + docs) follows. Nix regexes are whole-string anchored and `.`
      # never spans newlines, so the version is extracted line-by-line rather
      # than with one multi-line match.
      version =
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile ./cl-dataflow.asd);
          versionLine = builtins.head (
            builtins.filter (line: builtins.match "[[:space:]]*:version \"[^\"]*\"" line != null) lines
          );
        in
        builtins.head (builtins.match "[[:space:]]*:version \"([^\"]*)\"" versionLine);

      # Scope is Nix only: nixfmt (RFC-style) is a zero-footgun, low-diff
      # formatter, whereas YAML formatters mangle the GitHub Actions `on:` key
      # and Markdown reformatting would churn the whole docs tree.
      treefmtEval = forAllSystems (
        pkgs:
        treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );

      # Everything below is per-system: the cl-nix-forge library instance, the
      # foreign sibling dependencies wrapped once as `fromDerivation` leaves,
      # and the one `lispDerivation` build that `packages`/`checks`/`apps`/
      # `devShells` all share -- replacing the old hand-rolled `sourceFor` and
      # three separately hand-concatenated CL_SOURCE_REGISTRY strings with one
      # dependency graph resolved by cl-nix-forge itself.
      forSystem = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          cl = cl-nix-forge.lib.${system};
          weave = cl-weave.packages.${system}.default;
          weaveSource = cl-weave.packages.${system}.cl-weave;
          concurrentKit = cl-concurrent-kit.packages.${system}.cl-concurrent-kit;

          # `fromDerivation` wraps an ALREADY-COMPILED foreign package (its own
          # example wraps `pkgs.sbcl.pkgs.alexandria`): `lispDerivation`'s
          # identity ASDF_OUTPUT_TRANSLATIONS lands a dependency's fasls
          # beside its source, which only works when that source is writable
          # -- fine for cl-concurrent-kit (built by `pkgs.sbcl.buildASDFSystem`,
          # confirmed to ship .fasl files beside every .lisp file), but a raw
          # `flake = false` source checkout like cl-prolog has no fasls and
          # sits in an immutable Nix store path, so compiling it via a plain
          # `fromDerivation` wrap tries to write a .fasl into a read-only
          # directory and fails with SB-INT:SIMPLE-FILE-ERROR ("Permission
          # denied") -- reproduced directly before landing this. The fix is to
          # give each raw-source sibling its own `lispDerivation` build first
          # (a real, compiled cl-nix-forge output, exactly like cl-dataflow's
          # own), then depend on THAT -- not the raw source.
          concurrentKitDep = cl.fromDerivation {
            drv = concurrentKit;
            recursive = true;
            lispImplementation = "sbcl";
          };

          prologBuild = cl.lispDerivation {
            lispSystem = "cl-prolog";
            version = cl.fromAsdSystem "${cl-prolog}/cl-prolog.asd";
            src = cl-prolog;
          };
          # `packages.cl-weave` publishes cl-weave's own ASDF system directly
          # (cl-weave.asd at its outPath root) -- the sanctioned way a sibling
          # gets cl-weave's source, the same output cl-prolog/cl-json-kit
          # consume. `weave` (packages.default) is the delivered CLI binary,
          # used directly by the checks below, not wrapped as a dependency.
          # It ships fasls for 72 of its 143 .lisp files (confirmed directly),
          # not a complete set, so it gets the same lispDerivation treatment
          # as the fully-source-only siblings rather than a bare
          # `fromDerivation` gamble on which files still need compiling.
          weaveBuild = cl.lispDerivation {
            lispSystem = "cl-weave";
            version = cl.fromAsdSystem "${weaveSource}/cl-weave.asd";
            src = weaveSource;
          };
          # cl-process-kit's base system :depends-on cl-boundary-kit and
          # cl-log-kit, so both need their own lispDerivation build too --
          # cl-dataflow itself never loads or calls either directly.
          # cl-boundary-kit's OWN base system in turn :depends-on cl-log-kit
          # (verified directly against the pinned v1.0.0 tag's .asd, not
          # assumed from the old flat-registry comment, which only modeled
          # the edges INTO cl-process-kit and never needed to model this one
          # explicitly since every sibling shared one CL_SOURCE_REGISTRY).
          # cl-log-kit's own base system depends on nothing beyond ASDF
          # itself, so it is the one genuine leaf here.
          logKitBuild = cl.lispDerivation {
            lispSystem = "cl-log-kit";
            version = cl.fromAsdSystem "${cl-log-kit}/cl-log-kit.asd";
            src = cl-log-kit;
          };
          boundaryKitBuild = cl.lispDerivation {
            lispSystem = "cl-boundary-kit";
            version = cl.fromAsdSystem "${cl-boundary-kit}/cl-boundary-kit.asd";
            src = cl-boundary-kit;
            lispDependencies = [ logKitBuild ];
          };
          processKitBuild = cl.lispDerivation {
            lispSystem = "cl-process-kit";
            version = cl.fromAsdSystem "${cl-process-kit}/cl-process-kit.asd";
            src = cl-process-kit;
            lispDependencies = [
              boundaryKitBuild
              logKitBuild
            ];
          };

          cl-dataflow-drv = cl.lispDerivation {
            lispSystem = "cl-dataflow";
            inherit version;
            # An allowlist (.asd/.lisp anywhere under root), not the old
            # cleanSourceFilter-based denylist: t/ is kept by the same rule
            # that keeps src/, with no clause of its own to fall out of sync.
            # Two non-Lisp fixtures the build genuinely reads are opted in
            # explicitly: scripts/run-examples.sh (checks.examples' command)
            # and __snapshots__/snapshots.sexp (cl-weave's own
            # :to-match-snapshot fixture, read by cl-weave-advanced-test.lisp
            # -- tracked in git despite /__snapshots__/'s .gitignore rule,
            # per that file's own comment).
            src = cl.mkLispSource {
              root = ./.;
              include = [
                ./scripts/run-examples.sh
                ./__snapshots__/snapshots.sexp
              ];
            };
            lispDependencies = [
              prologBuild
              concurrentKitDep
            ];
            # Only pulled onto CL_SOURCE_REGISTRY when doCheck is true (i.e.
            # via .enableCheck, which every check helper below applies) --
            # cl-dataflow/test's own :depends-on ("cl-dataflow" "cl-weave"
            # "cl-process-kit"), plus cl-process-kit's transitive two (already
            # folded into processKitBuild's own ancestry, so listing it alone
            # is enough for boundary-kit/log-kit to reach the registry too).
            lispCheckDependencies = [
              weaveBuild
              processKitBuild
            ];
          };
        in
        {
          inherit
            system
            cl
            weave
            cl-dataflow-drv
            ;
        }
      );
    in
    {
      # `nix fmt` entry point, sharing its configuration with checks.formatting
      # so the two can never disagree about what "formatted" means.
      formatter = forAllSystems (
        pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper
      );

      packages = forAllSystems (
        pkgs:
        let
          inherit (forSystem.${pkgs.stdenv.hostPlatform.system}) cl cl-dataflow-drv;
        in
        {
          default = cl-dataflow-drv;

          # Rooted at the repository, not at ./docs, because
          # docs/src/changelog.md is a single `--8<-- "CHANGELOG.md"` include
          # and pymdownx.snippets resolves that relative to mkdocs' working
          # directory. Keeping the changelog in one file is the point: a
          # hand-maintained site copy drifts from the root one, which is how
          # every other repo in the org ended up with two different histories.
          docs = cl.mkDocsSite {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./docs/mkdocs.yml
              ./docs/src
              ./CHANGELOG.md
            ];
            mkdocsYmlName = "docs/mkdocs.yml";
            pname = "cl-dataflow-docs";
            inherit version;
            meta = {
              description = "Rendered MkDocs (Material) documentation for cl-dataflow";
              homepage = "https://github.com/nerima-lisp/cl-dataflow";
              license = pkgs.lib.licenses.mit;
            };
          };
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          inherit (forSystem.${system}) cl weave cl-dataflow-drv;
          # Same allowlist cl-dataflow-drv builds from: paredit-lint only
          # ever reads .lisp/.asd files, so it needs nothing more, and
          # nothing stray from the working tree can inflate its input hash.
          src = cl.mkLispSource { root = ./.; };
        in
        {
          default = cl.mkCommandCheck {
            drv = cl-dataflow-drv;
            name = "cl-dataflow-tests";
            nativeBuildInputs = [ weave ];
            timeoutSeconds = 900;
            # --reporter github costs nothing extra: this check already runs
            # the suite once under `nix flake check`, and
            # github-annotatable-event-p only emits `::error file=...::msg`
            # lines for fail/error events, so a passing run's output is
            # unaffected. Scoped to this derivation alone -- apps.default/
            # apps.test and the devShell keep cl-weave's plain :spec reporter
            # for local dev. Nix prints a failed derivation's build log to the
            # invoking terminal, which is where GitHub Actions scans for
            # `::error::`, so a CI test failure surfaces as an inline PR
            # annotation instead of requiring a second, annotation-only run.
            #
            # cl-weave's own default is 100 samples per it-property test.
            # Verified this repo's generators (graph/state-machine/stream
            # property tests) stay well within budget at 50x that: the whole
            # suite still compiles and runs in well under a minute.
            command = [
              "env"
              "CL_WEAVE_PROPERTY_TESTS=5000"
              "cl-weave"
              "run"
              "cl-dataflow/test"
              "--reporter"
              "github"
            ];
          };

          coverage = cl.mkCommandCheck {
            drv = cl-dataflow-drv;
            name = "cl-dataflow-coverage";
            nativeBuildInputs = [ weave ];
            timeoutSeconds = 900;
            command = [
              "env"
              "CL_WEAVE_PROPERTY_TESTS=5000"
              "cl-weave"
              "run"
              "cl-dataflow/test"
              "--reporter"
              "github"
              "--coverage"
              "--coverage-system"
              "cl-dataflow"
              "--coverage-min-expression"
              "84"
              "--coverage-min-branch"
              "100"
              "--coverage-output"
              "cl-dataflow.coverage"
              "--coverage-report-directory"
              "coverage/"
            ];
            artifacts = [
              "cl-dataflow.coverage"
              "coverage/"
            ];
          };

          paredit-lint = paredit-cli.lib.${system}.mkLintCheck {
            inherit src;
            name = "cl-dataflow-paredit-lint";
          };

          # t/core-runtime-example-test.lisp's own smoke tests spawn examples
          # through cl-process-kit's `run` from inside the running cl-weave
          # test process -- confirmed to deadlock (not just run slowly), which
          # is exactly the "implementation-specific run-program deadlock" its
          # docstring warns about and why they stay opt-in
          # (CL_DATAFLOW_RUN_EXAMPLE_SMOKE). scripts/run-examples.sh runs each
          # example as its own top-level `sbcl` process from a plain shell
          # loop instead, with no such parent-process entanglement, so this
          # check is what actually exercises every example on a schedule.
          examples = cl.mkCommandCheck {
            drv = cl-dataflow-drv;
            name = "cl-dataflow-examples";
            nativeBuildInputs = [ pkgs.sbcl ];
            timeoutSeconds = 900;
            command = [
              "sh"
              "./scripts/run-examples.sh"
            ];
          };

          # Fails `nix flake check` when any tracked Nix file is unformatted,
          # turning the formatter into an enforced CI gate rather than a
          # convention someone has to remember to run.
          formatting = treefmtEval.${system}.config.build.check self;

          # packages.docs runs `mkdocs build --strict`, so a broken link or a
          # page missing from the nav fails here. Without this the docs are
          # only ever built by docs.yml, which runs after the merge to main,
          # so such a break surfaces as a failed deploy rather than a failed
          # pull request.
          docs = self.packages.${system}.docs;
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          inherit (forSystem.${system}) weave cl-dataflow-drv;
          # `.enableCheck` resolves `lispCheckDependencies` (cl-weave,
          # cl-process-kit and its own transitive two) onto `registryPath` --
          # every app below runs the suite, so all of them need those on the
          # registry, not just the runtime two `packages.default` alone
          # would carry.
          registryPath = cl-dataflow-drv.enableCheck.registryPath;
          test = pkgs.writeShellApplication {
            name = "cl-dataflow-test";
            runtimeInputs = [ weave ];
            text = ''
              export CL_SOURCE_REGISTRY="${registryPath}:''${CL_SOURCE_REGISTRY:-}"
              exec cl-weave run cl-dataflow/test "$@"
            '';
          };
          # `cl-weave watch` re-runs the suite on every source change --
          # the fast local-development loop `advanced cl-weave usage` calls
          # for. `--once` is for CI/scripts (run once, exit); bare `watch`
          # here is the interactive default, matching how a developer
          # actually uses it at a terminal.
          watch = pkgs.writeShellApplication {
            name = "cl-dataflow-watch";
            runtimeInputs = [ weave ];
            text = ''
              export CL_SOURCE_REGISTRY="${registryPath}:''${CL_SOURCE_REGISTRY:-}"
              exec cl-weave watch cl-dataflow/test "$@"
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${test}/bin/cl-dataflow-test";
          };
          # `nix run .#test` is the name the org standard uses; `nix run .`
          # keeps working for existing muscle memory. Both drive the same
          # suite that run-tests.lisp and checks.default run.
          test = {
            type = "app";
            program = "${test}/bin/cl-dataflow-test";
          };
          watch = {
            type = "app";
            program = "${watch}/bin/cl-dataflow-watch";
          };
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          inherit (forSystem.${system}) cl weave cl-dataflow-drv;
        in
        {
          # `.enableCheck` so the exported CL_SOURCE_REGISTRY includes
          # cl-weave and friends -- the shell is meant to run the suite
          # interactively, not just load the bare runtime.
          default = cl.mkDevShell {
            drv = cl-dataflow-drv.enableCheck;
            extraPackages = [
              treefmtEval.${system}.config.build.wrapper
              weave
              paredit-cli.packages.${system}.default
            ];
          };
        }
      );
    };
}
