#!/usr/bin/env bats

function setup() {
  load test_helper/common
}

@test 'exits 1 with usage when given no command' {
  run env --unset=IN_DEVSHELL "${REPO_DIR}/.ci/in-devshell"
  assert_failure 1
  assert_output --partial 'usage: in-devshell <command>'
}

@test 'runs the command directly when IN_DEVSHELL is set' {
  IN_DEVSHELL=1 run "${REPO_DIR}/.ci/in-devshell" echo MARKER
  assert_success
  assert_output 'MARKER'
}

@test 'exits 1 outside a git repo' {
  cd "${BATS_TEST_TMPDIR}"
  run env --unset=IN_DEVSHELL "${REPO_DIR}/.ci/in-devshell" true
  assert_failure 1
  assert_output --partial 'not a git repo'
}
