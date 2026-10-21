#!/usr/bin/env bats

function setup() {
  load test_helper/common
  make_repo
}

@test 'sets core.hooksPath to .githooks' {
  run "${REPO_DIR}/.ci/activate-githooks"
  assert_success
  run git config --local --get core.hooksPath
  assert_success
  assert_output '.githooks'
}

@test 'is silent when already set' {
  "${REPO_DIR}/.ci/activate-githooks" 2> '/dev/null'
  run "${REPO_DIR}/.ci/activate-githooks"
  assert_success
  assert_output ''
}

@test 'exits 1 when given an argument' {
  run "${REPO_DIR}/.ci/activate-githooks" unexpected
  assert_failure 1
  assert_output --partial 'expected no arguments, got 1'
}

@test 'fails outside a git repository' {
  cd "${BATS_TEST_TMPDIR}"
  run "${REPO_DIR}/.ci/activate-githooks"
  assert_failure 1
  assert_output --partial 'not a git repo'
}

@test 'repoints a foreign core.hooksPath' {
  git config --local core.hooksPath 'other-hooks'
  run "${REPO_DIR}/.ci/activate-githooks"
  assert_success
  assert_output --partial 'repointed core.hooksPath from other-hooks to .githooks'
  run git config --local --get core.hooksPath
  assert_output '.githooks'
}
