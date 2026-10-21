#!/usr/bin/env bash

# Shared test setup, loaded by every .bats file's setup():
#
#   load test_helper/common
#
# Exports REPO_DIR (the repo root) and loads bats-support and bats-assert.
# make_repo creates a throwaway git repo for tests that need one.

# Unset repo-scoped GIT_* variables first: a caller (e.g. the pre-push hook)
# may carry GIT_DIR, which makes `git -C <fixture>` operate on the real repo.
_git_local_env_vars="$(git rev-parse --local-env-vars)"
while IFS= read -r _git_env_var; do
  unset "${_git_env_var}"
done <<< "${_git_local_env_vars}"
unset _git_local_env_vars _git_env_var

# Host git config must never leak into fixtures (a global commit.gpgsign=true
# would reach every fixture commit), and a fixture must never write into the
# real shared config.
export GIT_CONFIG_GLOBAL='/dev/null'
export GIT_CONFIG_SYSTEM='/dev/null'

REPO_DIR="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
export REPO_DIR

# Both libraries resolve through BATS_LIB_PATH, which the devShell's
# `bats.withLibraries` wrapper exports. A bats from anywhere else fails loudly
# here instead of silently omitting assert_*.
bats_load_library bats-support
bats_load_library bats-assert

# @description Create an empty git repo under the per-test temp dir, cd into it
#              and export its path as FIXTURE_REPO.
# @noargs
function make_repo() {
  git init --quiet "${BATS_TEST_TMPDIR}/repo"
  cd "${BATS_TEST_TMPDIR}/repo" || return 1
  FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
  export FIXTURE_REPO
}
