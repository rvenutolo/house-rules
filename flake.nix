{
  description = "house-rules - shared lints for rvenutolo's Nix-based repos";

  inputs = {
    # Keep this URL in github:NixOS/nixpkgs/... form. Renovate's
    # lockFileMaintenance refreshes flake.lock only when that exact string
    # appears here; any other spelling leaves the lock frozen with no error.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    bats-support = {
      url = "github:bats-core/bats-support";
      flake = false;
    };
    bats-assert = {
      url = "github:bats-core/bats-assert";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      treefmt-nix,
      bats-support,
      bats-assert,
    }:
    let
      eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./.treefmt.nix);
      # nixpkgs' unstable-version convention, derived from the input's own
      # lastModifiedDate so a flake.lock bump relabels the store path too.
      unstableVersion =
        input:
        let
          d = input.lastModifiedDate;
        in
        "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
    in
    {
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper);

      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.check self;
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            # linters
            shellcheck
            shfmt
            actionlint
            # zizmor audits workflows for security where actionlint audits
            # them for syntax; they overlap nowhere.
            zizmor
            yamllint
            markdownlint-cli2
            typos
            # nix linters: statix for antipatterns, deadnix for unused bindings.
            statix
            deadnix
            # runtime
            yq-go
            git
            just
            commitlint
            # nix.out, not bare `nix`: the default output is `dev`, which has
            # no bin/, so a bare `nix` puts nothing on PATH.
            nix.out
            coreutils
            findutils
            gnugrep
            # withLibraries, not bare bats: the wrapper exports BATS_LIB_PATH
            # at its own share/bats, so test_helper/common.bash loads the
            # libraries with `bats_load_library`, and a bats that is not this
            # one fails loudly instead of silently missing them. Both libraries
            # come from flake inputs pinned in flake.lock: the nixpkgs
            # bats-assert release lacks assert_stderr.
            (bats.withLibraries (l: [
              (l.bats-support.overrideAttrs (_: {
                src = bats-support;
                version = unstableVersion bats-support;
              }))
              (l.bats-assert.overrideAttrs (_: {
                src = bats-assert;
                version = unstableVersion bats-assert;
              }))
            ]))
          ];

          # Activate the tracked git hooks for this clone. Tolerant of failure
          # on purpose: a devShell that aborts on hook setup is worse than
          # inert hooks. Resolved via git rather than the flake's store path so
          # it configures the working clone, not a read-only copy.
          shellHook = ''
            if hooks_repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
              "$hooks_repo_root/.ci/activate-githooks" \
                || echo 'warning: could not activate tracked git hooks' >&2
            fi
          '';
        };
      });
    };
}
