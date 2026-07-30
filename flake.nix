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

    # cl-prolog backs the graph edge relation. Only its source tree is used
    # (CL_SOURCE_REGISTRY): it is architecture-independent Lisp with its .asd
    # at the repository root, and upstream ships Linux-only per-system
    # packages, so there is nothing to gain from evaluating its flake.
    cl-prolog = {
      url = "github:nerima-lisp/cl-prolog/v1.1.0";
      flake = false;
    };

    # cl-weave stays `flake = true`: checks.default and checks.coverage invoke
    # its `cl-weave` executable (packages.default), and every CL_SOURCE_REGISTRY
    # build below needs its ASDF source tree (packages.cl-weave) -- both are
    # packages outputs, so only a flake input provides them.
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

      sourceFor =
        pkgs:
        pkgs.lib.cleanSourceWith {
          src = ./.;
          filter =
            path: type:
            (pkgs.lib.cleanSourceFilter path type)
            && !(
              pkgs.lib.hasSuffix ".fasl" (builtins.baseNameOf path)
              || pkgs.lib.hasSuffix ".core" (builtins.baseNameOf path)
            );
        };

      mkDocs =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "cl-dataflow-docs";
          inherit version;
          # Rooted at the repository, not at ./docs, because
          # docs/src/changelog.md is a single `--8<-- "CHANGELOG.md"` include
          # and pymdownx.snippets resolves that relative to mkdocs' working
          # directory. Keeping the changelog in one file is the point: a
          # hand-maintained site copy drifts from the root one, which is how
          # every other repo in the org ended up with two different histories.
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./docs/mkdocs.yml
              ./docs/src
              ./CHANGELOG.md
            ];
          };
          nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
          # Build fully offline: Material for MkDocs bundles all of its assets,
          # so no network access is required inside the Nix sandbox. --strict
          # promotes broken links and unlisted pages to build failures.
          buildPhase = ''
            runHook preBuild
            mkdocs build --strict --config-file docs/mkdocs.yml --site-dir "$out"
            runHook postBuild
          '';
          dontInstall = true;
          meta = {
            description = "Rendered MkDocs (Material) documentation for cl-dataflow";
            homepage = "https://github.com/nerima-lisp/cl-dataflow";
            license = pkgs.lib.licenses.mit;
          };
        };
    in
    {
      # `nix fmt` entry point, sharing its configuration with checks.formatting
      # so the two can never disagree about what "formatted" means.
      formatter = forAllSystems (
        pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper
      );

      packages = forAllSystems (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "cl-dataflow";
          inherit version;
          src = sourceFor pkgs;
          dontBuild = true;
          installPhase = ''
            mkdir -p "$out/share/common-lisp/source/cl-dataflow"
            cp -R . "$out/share/common-lisp/source/cl-dataflow"
          '';
        };

        docs = mkDocs pkgs;
      });

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          src = sourceFor pkgs;
          # The source-only siblings all keep their .asd at the repository root,
          # which the trailing "//" recursive marker in CL_SOURCE_REGISTRY
          # discovers on every system.
          prologSource = "${cl-prolog.outPath}//";
          weave = cl-weave.packages.${system}.default;
          # `packages.cl-weave` publishes cl-weave's own ASDF system directly
          # (cl-weave.asd at its outPath root) -- the sanctioned way a sibling
          # gets cl-weave's source, the same output cl-prolog/cl-json-kit
          # consume. `${weave}/share/common-lisp/source` is a different thing:
          # an internal layout `installSource` creates so the DELIVERED BINARY
          # can find its own systems, not a published interface for us to read.
          weaveSource = cl-weave.packages.${system}.cl-weave;
          # cl-process-kit's base system :depends-on cl-boundary-kit and
          # cl-log-kit, so their source trees need to be discoverable too --
          # cl-dataflow itself never loads or calls either.
          processKit = cl-process-kit.outPath;
          processKitTransitiveSources = "${cl-boundary-kit.outPath}//:${cl-log-kit.outPath}//";
          # A real runtime dependency (RUN-PIPELINE's :PARALLEL mode), unlike
          # cl-process-kit's test-only role above -- see cl-dataflow.asd.
          concurrentKitSource = cl-concurrent-kit.packages.${system}.cl-concurrent-kit;
          sourceRegistry = "${prologSource}:${weaveSource}//:${processKit}//:${processKitTransitiveSources}:${concurrentKitSource}//:$PWD//:";
          mkWeaveCheck =
            {
              name,
              arguments,
              artifacts ? [ ],
            }:
            pkgs.stdenvNoCC.mkDerivation {
              inherit name src;
              nativeBuildInputs = [ weave ];
              buildPhase = ''
                export HOME="$TMPDIR/home"
                export XDG_CACHE_HOME="$TMPDIR/cache"
                mkdir -p "$HOME" "$XDG_CACHE_HOME"
                export CL_SOURCE_REGISTRY="${sourceRegistry}"
                # cl-weave's own default is 100 samples per it-property test.
                # Verified this repo's generators (graph/state-machine/stream
                # property tests) stay well within budget at 50x that: the
                # whole suite still compiles and runs in well under a minute.
                export CL_WEAVE_PROPERTY_TESTS=5000
                cl-weave ${pkgs.lib.escapeShellArgs arguments}
                ${pkgs.lib.concatMapStringsSep "\n" (
                  artifact: "test -e ${pkgs.lib.escapeShellArg artifact}"
                ) artifacts}
              '';
              installPhase = ''
                mkdir -p "$out"
                ${pkgs.lib.concatMapStringsSep "\n" (
                  artifact: "cp -R ${pkgs.lib.escapeShellArg artifact} \"$out/\""
                ) artifacts}
              '';
            };
        in
        {
          default = mkWeaveCheck {
            name = "cl-dataflow-tests";
            # --reporter github costs nothing extra: this check already runs the
            # suite once under `nix flake check`, and github-annotatable-event-p
            # only emits `::error file=...::msg` lines for fail/error events, so a
            # passing run's output is unaffected. It is scoped to this derivation
            # alone -- apps.default/apps.test (nix run ., scripts/verify.sh) and
            # the devShell keep cl-weave's plain :spec reporter for local dev.
            # Nix prints a failed derivation's build log to the invoking
            # terminal, which is where GitHub Actions scans for `::error::`, so
            # a CI test failure surfaces as an inline PR annotation instead of
            # requiring a second, annotation-only test run.
            arguments = [
              "run"
              "cl-dataflow/test"
              "--reporter"
              "github"
            ];
          };

          coverage = mkWeaveCheck {
            name = "cl-dataflow-coverage";
            arguments = [
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
          examples = pkgs.stdenvNoCC.mkDerivation {
            name = "cl-dataflow-examples";
            inherit src;
            nativeBuildInputs = [ pkgs.sbcl ];
            buildPhase = ''
              export HOME="$TMPDIR/home"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              mkdir -p "$HOME" "$XDG_CACHE_HOME"
              export CL_SOURCE_REGISTRY="${prologSource}:${concurrentKitSource}//:$PWD//:"
              ./scripts/run-examples.sh
            '';
            installPhase = ''
              mkdir -p "$out"
            '';
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
          weave = cl-weave.packages.${system}.default;
          weaveSource = cl-weave.packages.${system}.cl-weave;
          processKit = cl-process-kit.outPath;
          processKitTransitiveSources = "${cl-boundary-kit.outPath}//:${cl-log-kit.outPath}//";
          concurrentKitSource = cl-concurrent-kit.packages.${system}.cl-concurrent-kit;
          exportSourceRegistry = ''export CL_SOURCE_REGISTRY="${cl-prolog.outPath}//:${weaveSource}//:${processKit}//:${processKitTransitiveSources}:${concurrentKitSource}//:$PWD//:''${CL_SOURCE_REGISTRY:-}"'';
          test = pkgs.writeShellApplication {
            name = "cl-dataflow-test";
            runtimeInputs = [ weave ];
            text = ''
              ${exportSourceRegistry}
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
              ${exportSourceRegistry}
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
        in
        {
          default = pkgs.mkShell {
            packages = [
              treefmtEval.${system}.config.build.wrapper
              pkgs.sbcl
              cl-weave.packages.${system}.default
              paredit-cli.packages.${system}.default
            ];
            shellHook = ''
              export CL_SOURCE_REGISTRY="${cl-prolog.outPath}//:${
                cl-weave.packages.${system}.cl-weave
              }//:${cl-process-kit.outPath}//:${cl-boundary-kit.outPath}//:${cl-log-kit.outPath}//:${
                cl-concurrent-kit.packages.${system}.cl-concurrent-kit
              }//:$PWD//:''${CL_SOURCE_REGISTRY:-}"
            '';
          };
        }
      );
    };
}
