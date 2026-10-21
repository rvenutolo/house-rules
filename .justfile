# Developer shortcuts. Each recipe wraps a command that stands alone; nothing
# requires `just`. Run `just` on its own to list them.

# List the available recipes.
default:
    @just --list

# Run the full gate: ./.ci/in-devshell ./run-all-checks
check:
    ./.ci/in-devshell ./run-all-checks

# Run the lint suite only: ./.ci/in-devshell ./.ci/run-lint-checks
lint:
    ./.ci/in-devshell ./.ci/run-lint-checks

# Run the BATS suite: ./.ci/in-devshell ./run-tests
test:
    ./.ci/in-devshell ./run-tests

# Format every tracked file: ./.ci/in-devshell nix fmt
fmt:
    ./.ci/in-devshell nix fmt
