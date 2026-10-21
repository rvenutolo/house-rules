#!/usr/bin/env bats

# `nix` is replaced by a stub placed first on PATH. The stub only prints or
# exits: it never runs anything else, so a wrong assumption about how the
# script calls nix cannot touch the host.

function setup() {
  load test_helper/common
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir --parents "${STUB_DIR}"
  export PATH="${STUB_DIR}:${PATH}"
}

# @description Write the nix stub. Its body is a `case` over the installable,
#              the third argument of both `nix eval --json <installable> ...`
#              (the attrNames listing) and `nix eval --raw <installable>`
#              (the drvPath read). Every installable is appended to
#              `calls` in the test's temp directory.
# @arg $1 body the case alternatives of the stub
function write_nix_stub() {
  local -r body="$1"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # the stub, not this shell, expands $3
    printf 'printf "%%s\\n" "$3" >> "%s/calls"\n' "${BATS_TEST_TMPDIR}"
    # shellcheck disable=SC2016 # the stub, not this shell, expands $3
    printf 'case "$3" in\n'
    printf '%s\n' "${body}"
    printf 'esac\n'
  } > "${STUB_DIR}/nix"
  chmod +x "${STUB_DIR}/nix"
}

@test 'exits 1 when given an argument' {
  run "${REPO_DIR}/.ci/check-darwin-eval" unexpected
  assert_failure 1
  assert_output --partial 'expected no arguments, got 1'
}

@test 'fails when no packages are defined for a darwin system' {
  write_nix_stub '  *packages) printf "[\"aarch64-darwin\"]\n" ;;
  *) printf "[]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_failure 1
  assert_output --partial 'no packages defined for aarch64-darwin'
}

@test 'fails naming the package that does not evaluate' {
  write_nix_stub '  *drvPath*) exit 1 ;;
  *packages) printf "[\"aarch64-darwin\", \"x86_64-darwin\"]\n" ;;
  *) printf "[\"x\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_failure 1
  assert_output --partial 'check-darwin-eval: aarch64-darwin.x does not evaluate'
  assert_output --partial 'check-darwin-eval: x86_64-darwin.x does not evaluate'
}

@test 'passes when every package evaluates' {
  write_nix_stub '  *drvPath*) printf "/nix/store/stub.drv" ;;
  *packages) printf "[\"aarch64-darwin\"]\n" ;;
  *) printf "[\"x\", \"y\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_success
  refute_output --partial 'does not evaluate'
}

@test 'reports every package that does not evaluate, not only the first' {
  write_nix_stub '  *packages.aarch64-darwin.x.drvPath*) exit 1 ;;
  *packages.aarch64-darwin.y.drvPath*) exit 1 ;;
  *drvPath*) printf "/nix/store/stub.drv" ;;
  *packages) printf "[\"aarch64-darwin\"]\n" ;;
  *) printf "[\"x\", \"y\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_failure 1
  assert_output --partial 'aarch64-darwin.x does not evaluate'
  assert_output --partial 'aarch64-darwin.y does not evaluate'
}

@test 'checks only the darwin systems the flake exports' {
  write_nix_stub '  *drvPath*) printf "/nix/store/stub.drv" ;;
  *packages) printf "[\"aarch64-darwin\", \"x86_64-linux\"]\n" ;;
  *) printf "[\"x\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_success
  run cat "${BATS_TEST_TMPDIR}/calls"
  assert_output --partial 'packages.aarch64-darwin.x.drvPath'
  refute_output --partial 'x86_64-linux'
  refute_output --partial 'x86_64-darwin'
}

@test 'fails when the flake exports no darwin system' {
  write_nix_stub '  *packages) printf "[\"x86_64-linux\"]\n" ;;
  *) printf "[\"x\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_failure 1
  assert_output --partial 'check-darwin-eval: the flake exports no darwin system'
}

@test 'fails when the system listing fails' {
  write_nix_stub '  *packages) exit 1 ;;
  *) printf "[\"x\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_failure 1
  assert_output --partial 'cannot list the systems the flake exports'
}

@test 'fails when the package listing fails for an exported system' {
  write_nix_stub '  *packages.aarch64-darwin) exit 1 ;;
  *packages) printf "[\"aarch64-darwin\"]\n" ;;
  *) printf "[\"x\"]\n" ;;'
  run "${REPO_DIR}/.ci/check-darwin-eval"
  assert_failure 1
  assert_output --partial 'cannot list packages for aarch64-darwin'
}
