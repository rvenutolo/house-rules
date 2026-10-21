# house-rules

Shared lints for my Nix-based repos, published as a flake.

## Local gate

Every command runs inside the repo's hermetic devShell through `.ci/in-devshell`. The `just` recipe beside each is an
optional shortcut.

- `./.ci/in-devshell ./run-all-checks`: `nix flake check`, then the lints, then the tests (`just check`)
- `./.ci/in-devshell ./.ci/run-lint-checks`: the lints alone (`just lint`)
- `./.ci/in-devshell ./run-tests`: the BATS suite under `test/` (`just test`)
- `./.ci/in-devshell nix fmt`: treefmt over every tracked file (`just fmt`)

Entering the devShell (`nix develop`) points `core.hooksPath` at `.githooks`. `pre-push` runs the full gate and
`commit-msg` runs commitlint.
