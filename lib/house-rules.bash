#!/usr/bin/env bash

# Shared helpers for the house-rules lints. Sourced by each lint through a store
# path substituted at build time, never through an environment variable.
#
# Callers run under `set -Eeuo pipefail` and `shopt -s inherit_errexit`, but a
# function whose status is tested (`fn || n=$?`) runs with errexit off, so every
# command here that can fail checks its own status and dies rather than relying
# on errexit.

# Every known lint, and so every valid top-level key of .house-rules.yml. Adding
# a lint adds its name here.
readonly HOUSE_RULES_LINTS=('check-workflow-hermetic')

# The config file's name, relative to the repo root.
readonly HOUSE_RULES_CONFIG='.house-rules.yml'

# Exit statuses are 8 bits wide, so a larger error count would wrap, and 256
# errors would read as success.
readonly HOUSE_RULES_MAX_STATUS=255

# yq expression listing every duplicate mapping key at the top level and inside
# the section named by the HOUSE_RULES_LINT environment variable, one message
# per key. yq-go keeps only the last of a duplicated key, so the duplicate is
# invisible to every later read. The `where` part is `top level` for the root,
# otherwise the path in `section.key[index]` form. Each `'"'"'` ends the shell
# quote, adds a literal single quote and reopens it: yq-go's string escapes are
# unreliable, so the quote cannot be spelled inside the yq string.
# shellcheck disable=SC2016 # $where and $key are yq variables, not shell ones
readonly HOUSE_RULES_DUPLICATE_KEYS_EXPR='
(., (.[strenv(HOUSE_RULES_LINT)] | ..))
| select(type == "!!map")
| select((keys | length) > (keys | unique | length))
| ([(path | map(select(tag == "!!int") |= "[" + tostring + "]") | join(".") | sub("\.\[", "[")
    | select(. != "")), "top level"] | .[0]) as $where
| (keys | group_by(.) | map(select(length > 1) | .[0]) | .[]) as $key
| "duplicate key '"'"'" + ($key | tostring) + "'"'"' in " + $where
'

# @description Print `<script-name>: <message>` to stderr and exit 1. Inside a
#              command substitution it exits only that subshell, so callers
#              test the substitution's status.
# @arg $1 message what went wrong
# @stderr the message, prefixed with the script's name
# @exitcode 1 always
function house_rules::die() {
  local -r message="$1"
  printf '%s: %s\n' "${0##*/}" "${message}" >&2
  exit 1
}

# @description Print one config error as `.house-rules.yml: <problem>`. This is
#              the lint's report output, not a log line.
# @arg $1 problem the problem with the config file
# @stderr the prefixed problem
function house_rules::config_error() {
  local -r problem="$1"
  printf '%s: %s\n' "${HOUSE_RULES_CONFIG}" "${problem}" >&2
}

# @description Print the absolute root of the enclosing git repository. Call it
#              as `if ! root="$(house_rules::repo_root)"; then exit 1; fi`: the
#              die inside runs in the substitution's subshell.
# @noargs
# @stdout the absolute repo root
# @exitcode 1 not inside a git repository
function house_rules::repo_root() {
  local root
  if ! root="$(git rev-parse --show-toplevel 2> '/dev/null')"; then
    house_rules::die 'not inside a git repository'
  fi
  printf '%s\n' "${root}"
}

# @description Validate the file level of `<repo_root>/.house-rules.yml` and
#              write the lint's section to out_file as JSON. File level means:
#              it parses, holds one document, its top level is a map, every
#              top-level key is a known lint, and no map at the top level or in
#              the lint's section repeats a key. The section's own schema is the
#              lint's to check. out_file gets `null` when there is no file, the
#              file is empty, or the section is missing or empty, and also when
#              the file is too broken to read a section from. out_file doubles
#              as scratch space while validating.
# @arg $1 lint the lint whose section to extract
# @arg $2 repo_root absolute path of the repo root
# @arg $3 out_file where to write the section as JSON
# @stderr one `.house-rules.yml: <problem>` line per file-level error
# @exitcode 0 the file level is valid
# @exitcode * the number of file-level errors, capped at 255
function house_rules::load_config() {
  local -r lint="$1"
  local -r repo_root="$2"
  local -r out_file="$3"
  local -r config_file="${repo_root}/${HOUSE_RULES_CONFIG}"

  # A dangling symlink is not "no file": it goes on to yq, which reports it.
  if [[ ! -e "${config_file}" && ! -L "${config_file}" ]]; then
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    return 0
  fi

  # Counting documents parses every one of them, so this is the parse check too.
  local doc_count
  if ! doc_count="$(yq eval-all '[.] | length' "${config_file}" 2> "${out_file}")"; then
    local yq_error
    yq_error="$(< "${out_file}")" || house_rules::die "cannot read ${out_file}"
    house_rules::config_error "not valid YAML: ${yq_error}"
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    return 1
  fi
  if [[ "${doc_count}" != '1' ]]; then
    house_rules::config_error "holds ${doc_count} YAML documents; expected one"
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    return 1
  fi

  local top_type
  top_type="$(yq 'type' "${config_file}")" || house_rules::die "yq failed reading ${config_file}"
  case "${top_type}" in
    '!!map') ;;
    '!!null')
      printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
      return 0
      ;;
    *)
      house_rules::config_error 'top level must be a map'
      printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
      return 1
      ;;
  esac

  local errors=0
  local line

  HOUSE_RULES_LINT="${lint}" yq "${HOUSE_RULES_DUPLICATE_KEYS_EXPR}" "${config_file}" > "${out_file}" \
    || house_rules::die "yq failed reading ${config_file}"
  while IFS= read -r line; do
    house_rules::config_error "${line}"
    errors=$((errors + 1))
  done < "${out_file}"

  # `unique` so a duplicated unknown key is reported once here; the duplicate
  # itself is reported above.
  yq 'keys | unique | .[]' "${config_file}" > "${out_file}" || house_rules::die "yq failed reading ${config_file}"
  local known known_list
  printf -v known_list '%s, ' "${HOUSE_RULES_LINTS[@]}"
  known_list="${known_list%, }"
  while IFS= read -r line; do
    for known in "${HOUSE_RULES_LINTS[@]}"; do
      if [[ "${line}" == "${known}" ]]; then
        continue 2
      fi
    done
    house_rules::config_error "unknown lint '${line}'; known: ${known_list}"
    errors=$((errors + 1))
  done < "${out_file}"

  HOUSE_RULES_LINT="${lint}" yq --output-format=json '.[strenv(HOUSE_RULES_LINT)]' "${config_file}" > "${out_file}" \
    || house_rules::die "yq failed reading ${config_file}"

  if ((errors > HOUSE_RULES_MAX_STATUS)); then
    return "${HOUSE_RULES_MAX_STATUS}"
  fi
  return "${errors}"
}
