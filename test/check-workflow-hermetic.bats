#!/usr/bin/env bats

function setup() {
  load test_helper/common
  make_repo
}

# @description Write stdin to the fixture repo's .house-rules.yml.
# @noargs
function write_config() {
  cat > "${FIXTURE_REPO}/.house-rules.yml"
}

# @description Write a workflow with one run step whose id is `bare`.
# @noargs
function write_bare_step_workflow() {
  mkdir --parents "${FIXTURE_REPO}/.github/workflows"
  cat > "${FIXTURE_REPO}/.github/workflows/ci.yml" << 'EOF'
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
}

# @description Assert the run failed with exit 1 on the given config error and
#              ended with the error count.
# @arg $1 message the message after the `.house-rules.yml: ` prefix
function assert_config_error() {
  local -r message="$1"
  assert_failure 1
  assert_output --partial ".house-rules.yml: ${message}"
  assert_output --partial 'error(s)'
}

@test 'passes: no .house-rules.yml and no workflows' {
  run check-workflow-hermetic
  assert_success
}

@test 'passes: empty .house-rules.yml' {
  : > "${FIXTURE_REPO}/.house-rules.yml"
  run check-workflow-hermetic
  assert_success
}

@test 'passes: empty check-workflow-hermetic section' {
  write_config << 'EOF'
check-workflow-hermetic:
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: a valid exemption for an exempt step' {
  write_bare_step_workflow
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: unparsable .house-rules.yml' {
  write_config << 'EOF'
check-workflow-hermetic: [
EOF
  run check-workflow-hermetic
  assert_config_error 'not valid YAML: '
}

@test 'fails: .house-rules.yml is a dangling symlink' {
  ln --symbolic 'missing.yml' "${FIXTURE_REPO}/.house-rules.yml"
  run check-workflow-hermetic
  assert_config_error 'not valid YAML: '
}

@test 'fails: two YAML documents' {
  write_config << 'EOF'
check-workflow-hermetic: {}
---
check-workflow-hermetic: {}
EOF
  run check-workflow-hermetic
  assert_config_error 'holds 2 YAML documents; expected one'
}

@test 'fails: top level is a list' {
  write_config << 'EOF'
- check-workflow-hermetic
EOF
  run check-workflow-hermetic
  assert_config_error 'top level must be a map'
}

@test 'fails: duplicate top-level key' {
  write_config << 'EOF'
check-workflow-hermetic: {}
check-workflow-hermetic: {}
EOF
  run check-workflow-hermetic
  assert_config_error "duplicate key 'check-workflow-hermetic' in top level"
}

@test 'fails: unknown lint section' {
  write_config << 'EOF'
check-workflow-hermitic: {}
EOF
  run check-workflow-hermetic
  assert_config_error "unknown lint 'check-workflow-hermitic'; known: check-workflow-hermetic"
}

@test 'fails: section is a string' {
  write_config << 'EOF'
check-workflow-hermetic: yes please
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic must be a map'
}

@test 'fails: unknown section key' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempts: []
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: unknown key 'exempts'"
}

@test 'fails: duplicate key in the section' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: .ci/in-devshell
  wrapper: .ci/other
EOF
  run check-workflow-hermetic
  assert_config_error "duplicate key 'wrapper' in check-workflow-hermetic"
}

@test 'fails: wrapper is a list' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper:
    - .ci/in-devshell
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: wrapper must be a string'
}

@test 'fails: empty wrapper' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: ''
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: wrapper must not be empty'
}

@test 'passes: a custom wrapper' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: scripts/in-nix
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: exempt given with no value' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt must be a list'
}

@test 'fails: exempt is a map' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    step: .github/workflows/ci.yml::bare
    reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt must be a list'
}

@test 'fails: exempt entry is a string' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - .github/workflows/ci.yml::bare
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt[0] must be a map'
}

@test 'fails: duplicate key in an entry' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      step: .github/workflows/ci.yml::other
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "duplicate key 'step' in check-workflow-hermetic.exempt[0]"
}

@test 'fails: unknown entry key' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      reason: Runs before Nix is installed.
      note: extra
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: unknown key 'note'"
}

@test 'fails: missing step' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt[0]: step is missing'
}

@test 'fails: step is an int' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: 5
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt[0]: step must be a string'
}

@test 'fails: malformed step (no separator)' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: a.yml
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step 'a.yml' is not <file>::<id>"
}

@test 'fails: malformed step (empty file part)' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: ::x
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step '::x' is not <file>::<id>"
}

@test 'fails: malformed step (empty id part)' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: 'a.yml::'
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step 'a.yml::' is not <file>::<id>"
}

@test 'fails: malformed step (two separators)' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: a.yml::x::y
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step 'a.yml::x::y' is not <file>::<id>"
}

@test 'passes: step with a nested path and a space' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/actions/my action/action.yml::x
      reason: Runs before Nix is installed.
    - step: a/b.yml::x
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: missing reason' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt[0]: reason is missing or empty'
}

@test 'fails: whitespace-only reason' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      reason: "  "
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt[0]: reason is missing or empty'
}

@test 'fails: reason is a list' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      reason: [a]
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt[0]: reason must be a string'
}

@test 'fails: duplicate step' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      reason: Runs before Nix is installed.
    - step: .github/workflows/ci.yml::bare
      reason: Still runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[1]: duplicate step '.github/workflows/ci.yml::bare'"
}

@test 'reports every config error in one run' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: a.yml
      reason: Runs before Nix is installed.
    - step: .github/workflows/ci.yml::bare
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial ".house-rules.yml: check-workflow-hermetic: exempt[0]: step 'a.yml' is not <file>::<id>"
  assert_output --partial '.house-rules.yml: check-workflow-hermetic: exempt[1]: reason is missing or empty'
  assert_output --partial '2 .house-rules.yml error(s)'
}

@test 'fails: outside a git repository' {
  cd "${BATS_TEST_TMPDIR}"
  run check-workflow-hermetic
  assert_failure 1
  assert_output 'check-workflow-hermetic: not inside a git repository'
}

@test '--help prints usage and exits 0' {
  run check-workflow-hermetic --help
  assert_success
  assert_output --partial 'usage: check-workflow-hermetic [--help]'
}

@test 'fails: an unexpected argument' {
  run check-workflow-hermetic extra
  assert_failure 1
  assert_output --partial "check-workflow-hermetic: unexpected argument 'extra'"
}
