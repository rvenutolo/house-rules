#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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
#              reported the given total error count.
# @arg $1 message the message after the `.house-rules.yml: ` prefix
# @arg $2 count the expected total error count; defaults to 1
function assert_config_error() {
  local -r message="$1"
  local -r count="${2:-1}"
  assert_failure 1
  assert_output --partial ".house-rules.yml: ${message}"
  assert_line "${count} .house-rules.yml error(s)"
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

@test 'passes: exempt is an empty list' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt: []
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: whitespace-only wrapper' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: '   '
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: wrapper must not be empty'
}

@test 'fails: wrapper with a trailing newline' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: ".ci/in-devshell\n"
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: wrapper must be a single line'
}

@test 'fails: step with a trailing newline' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: "a.yml::x\n"
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step 'a.yml::x\n' is not <file>::<id>"
}

@test 'fails: step as a literal block scalar' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: |
        a.yml::x
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step 'a.yml::x\n' is not <file>::<id>"
}

@test 'fails: malformed step (blank file part)' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: ' ::x'
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step ' ::x' is not <file>::<id>"
}

@test 'fails: malformed step (blank id part)' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: 'a.yml:: '
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step 'a.yml:: ' is not <file>::<id>"
}

@test 'passes: a folded multi-line reason' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: a.yml::x
      reason: >-
        Runs before Nix is installed. It decides whether the Nix jobs run at
        all, so it cannot depend on them.
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: merge key adds an unknown key to an entry' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - {step: a.yml::x, reason: r, <<: {bogus: 1}}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_output ''
  assert_stderr - << 'EOF'
.house-rules.yml: merge key '<<' is not supported (in check-workflow-hermetic.exempt[0])
1 .house-rules.yml error(s)
EOF
}

@test 'fails: merge key adds an unknown key to the section' {
  write_config << 'EOF'
check-workflow-hermetic:
  <<: {bogus: 1}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: merge key '<<' is not supported (in check-workflow-hermetic)
1 .house-rules.yml error(s)
EOF
}

@test 'fails: merge key overrides an entry step' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - {step: a.yml::x, reason: r, <<: {step: b.yml::y}}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: merge key '<<' is not supported (in check-workflow-hermetic.exempt[0])
1 .house-rules.yml error(s)
EOF
}

@test 'fails: entry made only of a merge key' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - <<: {step: a.yml::x, reason: r}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: merge key '<<' is not supported (in check-workflow-hermetic.exempt[0])
1 .house-rules.yml error(s)
EOF
}

@test 'fails: YAML alias' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - &entry {step: a.yml::x, reason: r}
    - *entry
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: YAML alias '*entry' is not supported (in check-workflow-hermetic.exempt[1])
1 .house-rules.yml error(s)
EOF
}

@test 'fails: merge key with an alias reports both' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - &base {step: a.yml::x, reason: r}
    - {<<: *base, step: b.yml::y}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: merge key '<<' is not supported (in check-workflow-hermetic.exempt[1])
.house-rules.yml: YAML alias '*base' is not supported (in check-workflow-hermetic.exempt[1].<<)
2 .house-rules.yml error(s)
EOF
}

@test 'reports only its own lines on stderr for a section error' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt: {}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_output ''
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: exempt must be a list
1 .house-rules.yml error(s)
EOF
}

@test 'fails: quoted << key in the section' {
  write_config << 'EOF'
check-workflow-hermetic:
  "<<": {bogus: 1}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: unknown key '<<'
1 .house-rules.yml error(s)
EOF
}

@test 'fails: quoted << key in an entry' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - {step: a.yml::x, reason: r, "<<": {step: b.yml::y}}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: exempt[0]: unknown key '<<'
1 .house-rules.yml error(s)
EOF
}

@test 'fails: !!str << key in an entry' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - {step: a.yml::x, reason: r, !!str <<: {step: b.yml::y}}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: exempt[0]: unknown key '<<'
1 .house-rules.yml error(s)
EOF
}

@test 'fails: newline in a top-level key' {
  write_config << 'EOF'
"check-workflow-hermetic\ncheck-workflow-hermetic": 1
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: unknown lint 'check-workflow-hermetic\ncheck-workflow-hermetic'; known: check-workflow-hermetic
1 .house-rules.yml error(s)
EOF
}

@test 'fails: newline in a section key' {
  write_config << 'EOF'
check-workflow-hermetic:
  "wrapper\nexempt": {bogus: 1}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: unknown key 'wrapper\nexempt'
1 .house-rules.yml error(s)
EOF
}

@test 'fails: newline in an entry key' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - {step: a.yml::x, reason: r, "step\nstep": [1, 2, 3]}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: exempt[0]: unknown key 'step\nstep'
1 .house-rules.yml error(s)
EOF
}

@test 'fails: carriage return in a key is printed escaped' {
  write_config << 'EOF'
check-workflow-hermetic:
  "wrapper\rexempt": 1
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  refute_regex "${stderr}" $'\r'
  assert_stderr - << 'EOF'
.house-rules.yml: check-workflow-hermetic: unknown key 'wrapper\rexempt'
1 .house-rules.yml error(s)
EOF
}

@test 'fails: custom tag on the wrapper key' {
  write_config << 'EOF'
check-workflow-hermetic:
  !custom wrapper: .ci/x
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: YAML tag '!custom' is not supported (in check-workflow-hermetic)
1 .house-rules.yml error(s)
EOF
}

@test 'fails: custom tag on the wrapper value' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: !custom .ci/x
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: YAML tag '!custom' is not supported (in check-workflow-hermetic.wrapper)
1 .house-rules.yml error(s)
EOF
}

@test 'fails: custom tag on a step' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: !foo a.yml::x
      reason: Runs before Nix is installed.
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: YAML tag '!foo' is not supported (in check-workflow-hermetic.exempt[0].step)
1 .house-rules.yml error(s)
EOF
}

@test 'fails: custom tag on an entry' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - !foo {step: a.yml::x, reason: r}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: YAML tag '!foo' is not supported (in check-workflow-hermetic.exempt[0])
1 .house-rules.yml error(s)
EOF
}

@test 'fails: custom tag on the exempt list' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt: !foo
    - {step: a.yml::x, reason: r}
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.house-rules.yml: YAML tag '!foo' is not supported (in check-workflow-hermetic.exempt)
1 .house-rules.yml error(s)
EOF
}

@test 'fails: !!str tagged int step is read as a string' {
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: !!str 5
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_config_error "check-workflow-hermetic: exempt[0]: step '5' is not <file>::<id>"
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
  assert_line '2 .house-rules.yml error(s)'
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
