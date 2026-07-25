{
  description = "Composable Common Lisp dataflow runtime";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.cl-prolog = {
    url = "github:nerima-lisp/cl-prolog";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.cl-weave = {
    url = "github:nerima-lisp/cl-weave";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.paredit-cli = {
    url = "github:nerima-lisp/paredit-cli";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.cl-process-kit = {
    url = "github:nerima-lisp/cl-process-kit";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # cl-process-kit's own base ASDF system (:depends-on (:asdf :cl-boundary-kit
  # :cl-log-kit)) needs these two; they are never loaded or called directly by
  # cl-dataflow (no API usage, no adapter) -- only their source trees need to
  # be on CL_SOURCE_REGISTRY so ASDF can resolve cl-process-kit's :depends-on.
  # cl-tty-kit is NOT a dependency here: it's only required by the optional
  # cl-process-kit/pty subsystem, which cl-dataflow never loads. Neither ships
  # a flake.nix (like cl-prolog below), so their source tree is referenced
  # directly via .outPath rather than a packages.<system>.default output.
  inputs.cl-boundary-kit = {
    url = "github:nerima-lisp/cl-boundary-kit";
    flake = false;
  };
  inputs.cl-log-kit = {
    url = "github:nerima-lisp/cl-log-kit";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-prolog,
      cl-weave,
      paredit-cli,
      cl-process-kit,
      cl-boundary-kit,
      cl-log-kit,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        function: nixpkgs.lib.genAttrs systems (system: function (import nixpkgs { inherit system; }));
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
          version = "1.0.0";
          src = pkgs.lib.fileset.toSource {
            root = ./docs;
            fileset = pkgs.lib.fileset.unions [
              ./docs/mkdocs.yml
              ./docs/src
            ];
          };
          nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
          # Build fully offline: Material for MkDocs bundles all of its assets,
          # so no network access is required inside the Nix sandbox. --strict
          # promotes broken links and unlisted pages to build failures.
          buildPhase = ''
            runHook preBuild
            mkdocs build --strict --config-file mkdocs.yml --site-dir "$out"
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
      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      packages = forAllSystems (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "cl-dataflow";
          version = "1.0.0";
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
          # cl-prolog is architecture-independent Lisp source, and upstream now
          # ships Linux-only per-system packages, so reference the flake source
          # tree directly. Its cl-prolog.asd sits at the root, which the trailing
          # "//" recursive marker in CL_SOURCE_REGISTRY discovers on every system.
          prologSource = "${cl-prolog.outPath}//";
          weave = cl-weave.packages.${system}.default;
          # cl-process-kit's own package output has its .asd at the root (like
          # cl-prolog's source tree), not nested under share/common-lisp/source.
          # Its base system's :depends-on is cl-boundary-kit and cl-log-kit, so
          # their source trees need to be discoverable too -- cl-dataflow
          # itself never loads or calls either.
          processKit = cl-process-kit.packages.${system}.default;
          processKitTransitiveSources = "${cl-boundary-kit.outPath}//:${cl-log-kit.outPath}//";
          sourceRegistry = "${prologSource}:${weave}/share/common-lisp/source//:${processKit}//:${processKitTransitiveSources}:$PWD//:";
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
            arguments = [
              "run"
              "cl-dataflow/test"
            ];
          };

          coverage = mkWeaveCheck {
            name = "cl-dataflow-coverage";
            arguments = [
              "run"
              "cl-dataflow/test"
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
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          weave = cl-weave.packages.${system}.default;
          processKit = cl-process-kit.packages.${system}.default;
          processKitTransitiveSources = "${cl-boundary-kit.outPath}//:${cl-log-kit.outPath}//";
          test = pkgs.writeShellApplication {
            name = "cl-dataflow-test";
            runtimeInputs = [ weave ];
            text = ''
              export CL_SOURCE_REGISTRY="${cl-prolog.outPath}//:${weave}/share/common-lisp/source//:${processKit}//:${processKitTransitiveSources}:$PWD//:''${CL_SOURCE_REGISTRY:-}"
              exec cl-weave run cl-dataflow/test "$@"
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${test}/bin/cl-dataflow-test";
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
              pkgs.nixfmt
              pkgs.sbcl
              cl-weave.packages.${system}.default
              paredit-cli.packages.${system}.default
            ];
            shellHook = ''
              export CL_SOURCE_REGISTRY="${cl-prolog.outPath}//:${
                cl-weave.packages.${system}.default
              }/share/common-lisp/source//:${cl-process-kit.packages.${system}.default}//:${cl-boundary-kit.outPath}//:${cl-log-kit.outPath}//:$PWD//:''${CL_SOURCE_REGISTRY:-}"
            '';
          };
        }
      );
    };
}
