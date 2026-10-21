#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

function setup() {
  load test_helper/common
  make_repo
  # The forbidden spelling is assembled from two words, so the literal never
  # appears in this file: the user's repos scan their trees for it, and such a
  # scan cannot tell a fixture line from an offender.
  local -r develop_word='develop'
  DIRECT_SPELLING="nix ${develop_word}"
}

# A test that makes a directory unreadable restores it here, so a failed
# assertion cannot leave bats unable to delete the test's temp dir.
function teardown() {
  if [[ -n "${LOCKED_DIR:-}" ]]; then
    chmod u+rwx "${LOCKED_DIR}"
  fi
}

# @description Write stdin to a file under the fixture repo, creating its
#              parent directories, with every @@DIRECT@@ sentinel replaced by
#              the forbidden spelling.
# @arg $1 rel_path the file's path relative to the fixture repo
function write_fixture() {
  local -r rel_path="$1"
  mkdir --parents "$(dirname "${FIXTURE_REPO}/${rel_path}")"
  sed "s|@@DIRECT@@|${DIRECT_SPELLING}|g" > "${FIXTURE_REPO}/${rel_path}"
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
    - step: .github/workflows/a/b.yml::x
      reason: Runs before Nix is installed.
EOF
  write_fixture '.github/actions/my action/action.yml' << 'EOF'
runs:
  using: composite
  steps:
    - id: x
      shell: bash
      run: echo PAYLOAD
EOF
  write_fixture '.github/workflows/a/b.yml' << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: x
        run: echo PAYLOAD
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
    - step: .github/workflows/ci.yml::bare
      reason: >-
        Runs before Nix is installed. It decides whether the Nix jobs run at
        all, so it cannot depend on them.
EOF
  write_bare_step_workflow
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

# ---- rule 1: passes ----

@test 'passes: a workflow run step that invokes the wrapper' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - name: do
        run: ./.ci/in-devshell ./check-scripts
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: the wrapper named inside a multi-line block' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - name: do
        run: |
          set -Eeuo pipefail
          count="$(./.ci/in-devshell bats --count test/functions)"
          printf '%s\n' "${count}"
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: a composite-action run step that invokes the wrapper' {
  write_fixture .github/actions/myaction/action.yml << 'EOF'
runs:
  using: composite
  steps:
    - shell: bash
      run: ./.ci/in-devshell bashcov --root . -- bats test/functions
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: steps with no run: key are ignored' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - uses: actions/checkout@v7
        with:
          dry-run: false
      - uses: ./.github/actions/setup
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: empty workflow and action directories' {
  mkdir --parents "${FIXTURE_REPO}/.github/workflows" "${FIXTURE_REPO}/.github/actions"
  run check-workflow-hermetic
  assert_success
}

@test 'passes: a custom wrapper from config' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: ./gate
EOF
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: build
        run: ./gate make
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: invoked from a subdirectory uses the repo root' {
  write_bare_step_workflow
  write_fixture .github/workflows/b.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: wrapped
        run: ./.ci/in-devshell make
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/ci.yml::bare
      reason: Runs before Nix is installed.
EOF
  cd .github
  run check-workflow-hermetic
  assert_success
}

@test 'passes: an exemption covers a step in an action dir with a space' {
  write_fixture '.github/actions/my action/action.yml' << 'EOF'
runs:
  using: composite
  steps:
    - id: bare
      shell: bash
      run: echo PAYLOAD
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/actions/my action/action.yml::bare
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: the wrapper reached through a YAML alias' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
x-cmd: &cmd ./.ci/in-devshell make
jobs:
  build:
    steps:
      - id: aliased
        run: *cmd
EOF
  run check-workflow-hermetic
  assert_success
}

# ---- rule 1: fails ----

@test 'fails: an unwrapped run step, named by its <file>::<id> key' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: bare
        name: do
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke .ci/in-devshell'
  assert_line '1 hermetic-boundary violation(s)'
}

@test 'fails: an unwrapped composite-action run step' {
  write_fixture .github/actions/myaction/action.yml << 'EOF'
runs:
  using: composite
  steps:
    - id: bare
      shell: bash
      run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/actions/myaction/action.yml::bare: run step does not invoke .ci/in-devshell'
}

@test 'fails: an unwrapped run step with no id names the fix instead of its name' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - name: Run BATS
        run: echo PAYLOAD
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  local -r fix='has no YAML id:; add one (.house-rules.yml exemptions are keyed <file>::<id>)'
  assert_stderr - << EOF
.github/workflows/a.yml: job 'build' step #0 (Run BATS) does not invoke .ci/in-devshell and ${fix}
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: an unnamed offending step is reported by job and index' {
  write_fixture .github/workflows/a.yml << 'EOF'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial ".github/workflows/a.yml: job 'build' step #1 does not invoke .ci/in-devshell"
}

@test 'fails: counts every offender and reports the total' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: one
        run: echo PAYLOAD
  other:
    steps:
      - id: two
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_line '2 hermetic-boundary violation(s)'
}

@test 'fails: the default wrapper does not satisfy a custom wrapper' {
  write_config << 'EOF'
check-workflow-hermetic:
  wrapper: ./gate
EOF
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: build
        run: ./.ci/in-devshell make
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::build: run step does not invoke ./gate'
}

@test 'fails: an unparsable workflow file' {
  write_fixture .github/workflows/a.yml << 'EOF'
jobs: [
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.github/workflows/a.yml: not valid YAML
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: an unparsable file does not stop the scan of the others' {
  write_fixture .github/workflows/a.yml << 'EOF'
jobs: [
EOF
  write_bare_step_workflow
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml: not valid YAML'
  assert_output --partial '.github/workflows/ci.yml::bare: run step does not invoke'
  assert_line '2 hermetic-boundary violation(s)'
}

@test 'fails: an unwrapped step in a nested .yaml action file' {
  write_fixture .github/actions/a/b/action.yaml << 'EOF'
runs:
  using: composite
  steps:
    - id: bare
      shell: bash
      run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/actions/a/b/action.yaml::bare: run step does not invoke'
}

@test 'fails: an unwrapped step in a nested workflows directory' {
  write_fixture .github/workflows/sub/a.yaml << 'EOF'
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/sub/a.yaml::bare: run step does not invoke'
}

@test 'fails: config errors stop the scan' {
  write_bare_step_workflow
  write_config << 'EOF'
check-workflow-hermetic:
  exempt: {}
EOF
  run check-workflow-hermetic
  assert_config_error 'check-workflow-hermetic: exempt must be a list'
  refute_output --partial 'run step does not invoke'
  refute_output --partial 'hermetic-boundary violation(s)'
}

# ---- rule 2 ----

@test 'fails: a workflow that enters the devShell directly' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: direct
        run: ./.ci/in-devshell true && @@DIRECT@@ --command ./check-scripts
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << EOF
.github/workflows/a.yml: spells "${DIRECT_SPELLING}"; only .ci/in-devshell may enter the devShell
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: the direct spelling is caught in a comment too, not only in a run block' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
# was: @@DIRECT@@ --command ./check-scripts
jobs:
  build:
    steps:
      - name: do
        run: ./.ci/in-devshell ./check-scripts
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial 'only .ci/in-devshell may enter the devShell'
}

@test 'passes: in-devshell does not itself match the forbidden spelling' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - name: do
        run: ./.ci/in-devshell nix flake check
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: the direct spelling folded across lines of a plain scalar' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: direct
        run: ./.ci/in-devshell true && nix
          develop --command ./check-scripts
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml: spells'
}

@test 'fails: the direct spelling written with a YAML escape' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: direct
        run: "./.ci/in-devshell true && nix\x20develop --command ./check-scripts"
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml: spells'
}

@test 'fails: the direct spelling in an action file' {
  write_fixture .github/actions/a/action.yml << 'EOF'
runs:
  using: composite
  steps:
    - id: direct
      shell: @@DIRECT@@ --command bash {0}
      run: ./.ci/in-devshell true
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/actions/a/action.yml: spells'
}

@test 'fails: the direct spelling split by a shell line continuation' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: direct
        run: |
          ./.ci/in-devshell true
          nix \
            develop --command ./check-scripts
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml: spells'
}

@test 'passes: nix-installer-action does not match the forbidden spelling' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - uses: DeterminateSystems/nix-installer-action@v1
      - name: do
        run: ./.ci/in-devshell nix-installer-action develop
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'passes: nixdevelop does not match the forbidden spelling' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - name: do
        run: ./.ci/in-devshell nixdevelop
EOF
  run check-workflow-hermetic
  assert_success
}

# ---- exemptions ----

@test 'passes: an exempt step may skip the wrapper' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: decide
        run: echo 'run=true' >> "${GITHUB_OUTPUT}"
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::decide
      reason: Decides whether the Nix jobs run.
EOF
  run check-workflow-hermetic
  assert_success
}

@test 'fails: an exemption naming no run step is stale' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - name: do
        run: ./.ci/in-devshell ./check-scripts
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::ghost
      reason: Runs before Nix is installed.
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
stale exemption in .house-rules.yml: .github/workflows/a.yml::ghost matches no run step
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: an exemption naming a step that does invoke the wrapper is stale' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: fixed
        run: ./.ci/in-devshell ./check-scripts
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::fixed
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial \
    'stale exemption in .house-rules.yml: .github/workflows/a.yml::fixed already invokes .ci/in-devshell'
}

@test 'fails: an exemption naming a step with no run: key is stale' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: checkout
        uses: actions/checkout@v7
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::checkout
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial 'stale exemption in .house-rules.yml: .github/workflows/a.yml::checkout matches no run step'
}

@test 'fails: an exemption keyed on the wrong file does not cover the step' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/b.yml::bare
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
  assert_output --partial 'stale exemption in .house-rules.yml: .github/workflows/b.yml::bare matches no run step'
  assert_line '2 hermetic-boundary violation(s)'
}

@test 'fails: an exemption shared by a wrapped and an unwrapped step of one id is ambiguous' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  one:
    steps:
      - id: build
        run: ./.ci/in-devshell make
  two:
    steps:
      - id: build
        run: echo PAYLOAD
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::build
      reason: Runs before Nix is installed.
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  local -r hint='give each step a unique id'
  assert_stderr - << EOF
.github/workflows/a.yml::build: run step does not invoke .ci/in-devshell
ambiguous exemption in .house-rules.yml: .github/workflows/a.yml::build matches 2 run steps; ${hint}
2 hermetic-boundary violation(s)
EOF
}

@test 'fails: an exemption for an id shared by two jobs is ambiguous' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  j:
    steps:
      - id: x
        run: echo PAYLOAD
  k:
    steps:
      - id: x
        run: echo PAYLOAD
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::x
      reason: Runs before Nix is installed.
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.github/workflows/a.yml::x: run step does not invoke .ci/in-devshell
.github/workflows/a.yml::x: run step does not invoke .ci/in-devshell
ambiguous exemption in .house-rules.yml: .github/workflows/a.yml::x matches 2 run steps; give each step a unique id
3 hermetic-boundary violation(s)
EOF
}

@test 'fails: an exemption for an id shared by two YAML documents is ambiguous' {
  write_fixture .github/workflows/a.yml << 'EOF'
jobs:
  j:
    steps:
      - id: x
        run: echo PAYLOAD
---
jobs:
  j:
    steps:
      - id: x
        run: echo PAYLOAD
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::x
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial \
    'ambiguous exemption in .house-rules.yml: .github/workflows/a.yml::x matches 2 run steps; give each step'
  assert_line '3 hermetic-boundary violation(s)'
}

@test 'fails: an exemption for an id shared by two wrapped steps is stale' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  j:
    steps:
      - id: x
        run: ./.ci/in-devshell make
  k:
    steps:
      - id: x
        run: ./.ci/in-devshell make
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::x
      reason: Runs before Nix is installed.
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
stale exemption in .house-rules.yml: .github/workflows/a.yml::x already invokes .ci/in-devshell
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: .github/workflows is a regular file' {
  mkdir --parents "${FIXTURE_REPO}/.github"
  printf 'not a dir\n' > "${FIXTURE_REPO}/.github/workflows"
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.github/workflows: not a directory
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: .github/actions is a symlink to a regular file' {
  mkdir --parents "${FIXTURE_REPO}/.github"
  printf 'not a dir\n' > "${FIXTURE_REPO}/actions-file"
  ln --symbolic ../actions-file "${FIXTURE_REPO}/.github/actions"
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.github/actions: not a directory
1 hermetic-boundary violation(s)
EOF
}

# ---- file discovery ----

@test 'fails: a file name with a pipe is keyed by its full path' {
  write_fixture '.github/workflows/a|b.yml' << 'EOF'
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a|b.yml::bare: run step does not invoke'
}

@test 'fails: a file name with a newline is scanned and printed escaped' {
  write_fixture $'.github/workflows/a\nb.yml' << 'EOF'
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.github/workflows/a\nb.yml::bare: run step does not invoke .ci/in-devshell
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: a symlinked workflow file is scanned' {
  write_fixture shared/a.yml << 'EOF'
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  mkdir --parents "${FIXTURE_REPO}/.github/workflows"
  ln --symbolic ../../shared/a.yml "${FIXTURE_REPO}/.github/workflows/a.yml"
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: a symlinked action directory is scanned' {
  write_fixture shared/setup/action.yml << 'EOF'
runs:
  using: composite
  steps:
    - id: bare
      shell: bash
      run: echo PAYLOAD
EOF
  mkdir --parents "${FIXTURE_REPO}/.github/actions"
  ln --symbolic ../../shared/setup "${FIXTURE_REPO}/.github/actions/setup"
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/actions/setup/action.yml::bare: run step does not invoke'
}

@test 'fails: an unreadable directory under the scan roots' {
  if ((EUID == 0)); then
    skip 'root reads a directory whatever its mode'
  fi
  write_bare_step_workflow
  mkdir --parents "${FIXTURE_REPO}/.github/workflows/locked"
  LOCKED_DIR="${FIXTURE_REPO}/.github/workflows/locked"
  chmod 000 "${LOCKED_DIR}"
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial 'check-workflow-hermetic: cannot list '
  refute_output --partial 'ERROR: line'
}

@test 'fails: a run step in a later YAML document is scanned' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
---
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

# ---- YAML constructs that could hide a run step ----

@test 'fails: an unwrapped step reached through a YAML alias' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
x-step: &step
  id: bare
  run: echo PAYLOAD
jobs:
  build:
    steps:
      - *step
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: an unwrapped step in a steps list reached through a YAML alias' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
x-steps: &steps
  - id: bare
    run: echo PAYLOAD
jobs:
  build:
    steps: *steps
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: a run key brought in by a merge key' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
x-step: &step
  run: echo PAYLOAD
jobs:
  build:
    steps:
      - <<: *step
        id: bare
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: a local run key overrides a wrapped one from a merge key' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
x-wrapped: &wrapped
  run: ./.ci/in-devshell make
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
        <<: *wrapped
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: the first of several merged maps wins' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
x-bare: &bare
  run: echo PAYLOAD
x-wrapped: &wrapped
  run: ./.ci/in-devshell make
jobs:
  build:
    steps:
      - <<: [*bare, *wrapped]
        id: bare
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: a duplicated run key in a step' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
        run: ./.ci/in-devshell make
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial \
    ".github/workflows/a.yml: not valid YAML: duplicate key 'run' in jobs.build.steps[0]"
}

@test 'fails: a duplicated jobs key hiding the first jobs map' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
jobs:
  other:
    steps:
      - id: wrapped
        run: ./.ci/in-devshell make
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial ".github/workflows/a.yml: not valid YAML: duplicate key 'jobs' in top level"
}

@test 'fails: a step id with a trailing newline is not covered by an exemption' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: "bare\n"
        run: echo PAYLOAD
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::bare
      reason: Runs before Nix is installed.
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  assert_stderr - << 'EOF'
.github/workflows/a.yml::bare\n: run step does not invoke .ci/in-devshell
stale exemption in .house-rules.yml: .github/workflows/a.yml::bare matches no run step
2 hermetic-boundary violation(s)
EOF
}

@test 'fails: a step id with a newline cannot forge a seen exemption' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: "x|0\n.github/workflows/a.yml::ghost"
        run: ./.ci/in-devshell make
EOF
  write_config << 'EOF'
check-workflow-hermetic:
  exempt:
    - step: .github/workflows/a.yml::ghost
      reason: Runs before Nix is installed.
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial 'stale exemption in .house-rules.yml: .github/workflows/a.yml::ghost matches no run step'
}

@test 'fails: a pipe and a newline in a job key do not break the step record' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  "a|b\nc":
    steps:
      - name: "x|y"
        run: echo PAYLOAD
EOF
  run --separate-stderr check-workflow-hermetic
  assert_failure 1
  local -r fix='has no YAML id:; add one (.house-rules.yml exemptions are keyed <file>::<id>)'
  assert_stderr - << EOF
.github/workflows/a.yml: job 'a|b\nc' step #0 (x|y) does not invoke .ci/in-devshell and ${fix}
1 hermetic-boundary violation(s)
EOF
}

@test 'fails: a run body with a custom tag is not trusted' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: tagged
        run: !custom ./.ci/in-devshell make
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::tagged: run step does not invoke'
}

@test 'fails: a run key with no value' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: empty
        run:
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::empty: run step does not invoke'
}

@test 'fails: a NUL in a run body does not join the wrapper' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - id: nul
        run: "./.ci/in-dev\0shell make"
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial '.github/workflows/a.yml::nul: run step does not invoke'
}

# ---- non-core YAML tags ----

# @description Assert the run failed on an unsupported tag at the given place
#              and still reported the unwrapped step `bare` in a.yml.
# @arg $1 where the tag's location as the message prints it
function assert_tag_rejected() {
  local -r where="$1"
  assert_failure 1
  assert_output --partial ".github/workflows/a.yml: YAML tag '!x' is not supported (in ${where})"
  assert_output --partial '.github/workflows/a.yml::bare: run step does not invoke'
}

@test 'fails: a custom tag on jobs' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs: !x
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_tag_rejected 'jobs'
}

@test 'fails: a custom tag on a job' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build: !x
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_tag_rejected 'jobs.build'
}

@test 'fails: a custom tag on steps' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps: !x
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_tag_rejected 'jobs.build.steps'
}

@test 'fails: a custom tag on a step' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build:
    steps:
      - !x
        id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_tag_rejected 'jobs.build.steps[0]'
}

@test 'fails: a custom tag on the document root' {
  write_fixture .github/workflows/a.yml << 'EOF'
--- !x
on: push
jobs:
  build:
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_tag_rejected 'top level'
}

@test 'fails: a custom tag on runs in an action' {
  write_fixture .github/actions/a/action.yml << 'EOF'
runs: !x
  using: composite
  steps:
    - id: bare
      shell: bash
      run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial ".github/actions/a/action.yml: YAML tag '!x' is not supported (in runs)"
  assert_output --partial '.github/actions/a/action.yml::bare: run step does not invoke'
}

@test 'fails: an !!omap tag on a job' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: push
jobs:
  build: !!omap
    steps:
      - id: bare
        run: echo PAYLOAD
EOF
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial ".github/workflows/a.yml: YAML tag '!!omap' is not supported (in jobs.build)"
}

@test 'fails: a custom tag does not stop the scan of other files' {
  write_fixture .github/workflows/a.yml << 'EOF'
on: !x push
EOF
  write_bare_step_workflow
  run check-workflow-hermetic
  assert_failure 1
  assert_output --partial ".github/workflows/a.yml: YAML tag '!x' is not supported (in on)"
  assert_output --partial '.github/workflows/ci.yml::bare: run step does not invoke'
  assert_line '2 hermetic-boundary violation(s)'
}
