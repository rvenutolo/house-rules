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

# The yq expressions below share two traps:
# - yq-go evaluates a string literal even when its input stream is empty, so
#   `[] | .[] | "x"` prints `x`. Every message therefore concatenates a value
#   drawn from its input, and `top level` is substituted for an empty path with
#   `sub` rather than written as a fallback literal.
# - yq-go's string escapes are unreliable, so a single quote cannot be spelled
#   inside a yq string. Each `'"'"'` ends the shell quote, adds a literal single
#   quote and reopens it.

# yq fragment printing a value, a key in particular, on one line: JSON string
# escaping without the surrounding quotes, so `a<newline>b` prints as `a\nb`.
# Keys are user data, and a raw newline in one would split a one-per-line
# listing into names that look allowed; a raw carriage return would garble the
# terminal line.
readonly HOUSE_RULES_ESCAPE_EXPR='(tostring | @json | sub("^.", "") | sub(".$", ""))'

# yq fragment turning a path array into a `where`: `section.key[index]`, with
# keys escaped, or `top level` for the root.
readonly HOUSE_RULES_WHERE_EXPR='(map(select(tag == "!!str") |= "." + '"${HOUSE_RULES_ESCAPE_EXPR}"')
  | map(select(tag == "!!int") |= "[" + tostring + "]") | join("") | sub("^\.", "") | sub("^$", "top level"))'

# yq fragment, applied to a tag string, that is true for a YAML core tag. Any
# other tag is lost in the JSON conversion, so `!custom wrapper: x` would set
# the wrapper unseen.
readonly HOUSE_RULES_CORE_TAG_EXPR='(. == "!!map" or . == "!!seq" or . == "!!str" or . == "!!null" or . == "!!int"
  or . == "!!bool" or . == "!!float")'

# yq expression listing every tag other than the core ones, on keys or on
# values, anywhere in the file, one message each. A read that tests a node's
# `type` sees its tag, so a structural map or list carrying a custom tag would
# read as neither, and the JSON conversion drops such tags unseen.
# shellcheck disable=SC2016 # $p is a yq variable, not a shell one
readonly HOUSE_RULES_UNSUPPORTED_TAGS_EXPR='
([.. | select(kind == "map") | {"path": path, "tags": [keys | .[] | tag
    | select(. != "!!merge") | select('"${HOUSE_RULES_CORE_TAG_EXPR}"' | not)]}]
  | map(.path as $p | .tags | map({"path": $p, "tag": .})) | flatten(1) | .[]
  | "YAML tag '"'"'" + (.tag | '"${HOUSE_RULES_ESCAPE_EXPR}"') + "'"'"' is not supported (in "
    + (.path | '"${HOUSE_RULES_WHERE_EXPR}"') + ")"),
(.. | select(kind != "alias") | select(tag | '"${HOUSE_RULES_CORE_TAG_EXPR}"' | not)
  | "YAML tag '"'"'" + (tag | '"${HOUSE_RULES_ESCAPE_EXPR}"') + "'"'"' is not supported (in "
    + (path | '"${HOUSE_RULES_WHERE_EXPR}"') + ")")
'

# yq expression listing every construct the JSON conversion would silently
# rewrite, anywhere in the file, one message each: merge keys (`<<`), aliases,
# and tags other than the core ones. An inline merge can add an unknown key or
# override `step` unseen, so none may reach that conversion.
# shellcheck disable=SC2016 # $p is a yq variable, not a shell one
readonly HOUSE_RULES_UNSUPPORTED_EXPR='
([.. | select(kind == "map") | {"path": path, "merges": [keys | .[] | select(tag == "!!merge")]}]
  | map(.path as $p | .merges | map($p)) | flatten(1) | .[]
  | '"${HOUSE_RULES_WHERE_EXPR}"'
  | "merge key '"'"'<<'"'"' is not supported (in " + . + ")"),
(.. | select(kind == "alias")
  | "YAML alias '"'"'*" + (alias | '"${HOUSE_RULES_ESCAPE_EXPR}"') + "'"'"' is not supported (in "
    + (path | '"${HOUSE_RULES_WHERE_EXPR}"') + ")"),
'"${HOUSE_RULES_UNSUPPORTED_TAGS_EXPR}"

# yq expression listing, escaped and one per line, every key of the map it is
# given that is not in the comma-separated HOUSE_RULES_ALLOWED environment
# variable. The comparison happens inside yq, on the keys themselves.
readonly HOUSE_RULES_UNKNOWN_KEYS_EXPR='(keys | unique) - (strenv(HOUSE_RULES_ALLOWED) | split(","))
  | .[] | '"${HOUSE_RULES_ESCAPE_EXPR}"

# yq expression listing every duplicate mapping key at the top level and inside
# the section named by the HOUSE_RULES_LINT environment variable, one message
# per key. yq-go keeps only the last of a duplicated key, so the duplicate is
# invisible to every later read.
# shellcheck disable=SC2016 # $where is a yq variable, not a shell one
readonly HOUSE_RULES_DUPLICATE_KEYS_EXPR='
(., (.[strenv(HOUSE_RULES_LINT)] | ..))
| select(kind == "map")
| select((keys | length) > (keys | unique | length))
| (path | '"${HOUSE_RULES_WHERE_EXPR}"') as $where
| keys | group_by(.) | map(select(length > 1) | .[0]) | .[]
| "duplicate key '"'"'" + '"${HOUSE_RULES_ESCAPE_EXPR}"' + "'"'"' in " + $where
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

# @description Run yq with its stdout in out_file and its stderr in err_file,
#              so no yq warning reaches the lint's output. Dies with yq's
#              stderr when yq fails.
# @arg $1 out_file where to write yq's stdout
# @arg $2 err_file where to write yq's stderr
# @arg $@ args yq's arguments, after the first two
function house_rules::yq() {
  local -r out_file="$1"
  local -r err_file="$2"
  shift 2
  if ! yq "$@" > "${out_file}" 2> "${err_file}"; then
    house_rules::die "yq failed: $(< "${err_file}")"
  fi
}

# @description Fail loudly when a file a loop is about to read is missing.
#              Errexit is off in the validators, so a missing file would
#              otherwise read as zero errors.
# @arg $1 file the file that must exist
function house_rules::require_file() {
  local -r file="$1"
  [[ -f "${file}" ]] || house_rules::die "missing ${file}"
}

# @description Validate the file level of `<repo_root>/.house-rules.yml` and
#              write the lint's section to out_file as JSON. File level means:
#              it parses, holds one document, uses no merge key, alias or
#              non-core tag, its top level is a map, every top-level key is a
#              known lint, and no map at the top level or in the lint's section
#              repeats a key. The section's own schema is the lint's to check.
#              Every key in a message is escaped onto one line. out_file gets
#              `null` when there is no file, the file is empty, or the section
#              is missing or empty, and also when the file is too broken to
#              read a section from. out_file and `<out_file>.stderr` double as
#              scratch space while validating.
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
  local -r err_file="${out_file}.stderr"
  local -r config_file="${repo_root}/${HOUSE_RULES_CONFIG}"

  # A dangling symlink is not "no file": it goes on to yq, which reports it.
  if [[ ! -e "${config_file}" && ! -L "${config_file}" ]]; then
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    return 0
  fi

  # Counting documents parses every one of them, so this is the parse check too.
  local doc_count
  if ! yq eval-all '[.] | length' "${config_file}" > "${out_file}" 2> "${err_file}"; then
    local yq_error
    yq_error="$(< "${err_file}")" || house_rules::die "cannot read ${err_file}"
    house_rules::config_error "not valid YAML: ${yq_error}"
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    return 1
  fi
  doc_count="$(< "${out_file}")" || house_rules::die "cannot read ${out_file}"
  if [[ "${doc_count}" != '1' ]]; then
    house_rules::config_error "holds ${doc_count} YAML documents; expected one"
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    return 1
  fi

  local errors=0
  local line

  # Checked before anything else reads the file, and fatal: every later read
  # would see merged, aliased or untagged content instead of what was written.
  house_rules::yq "${out_file}" "${err_file}" "${HOUSE_RULES_UNSUPPORTED_EXPR}" "${config_file}"
  house_rules::require_file "${out_file}"
  while IFS= read -r line; do
    house_rules::config_error "${line}"
    errors=$((errors + 1))
  done < "${out_file}"
  if ((errors > 0)); then
    printf 'null\n' > "${out_file}" || house_rules::die "cannot write ${out_file}"
    house_rules::return_count "${errors}"
    return
  fi

  local top_type
  house_rules::yq "${out_file}" "${err_file}" 'type' "${config_file}"
  top_type="$(< "${out_file}")" || house_rules::die "cannot read ${out_file}"
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

  HOUSE_RULES_LINT="${lint}" house_rules::yq "${out_file}" "${err_file}" \
    "${HOUSE_RULES_DUPLICATE_KEYS_EXPR}" "${config_file}"
  house_rules::require_file "${out_file}"
  while IFS= read -r line; do
    house_rules::config_error "${line}"
    errors=$((errors + 1))
  done < "${out_file}"

  local known_list allowed
  printf -v known_list '%s, ' "${HOUSE_RULES_LINTS[@]}"
  known_list="${known_list%, }"
  printf -v allowed '%s,' "${HOUSE_RULES_LINTS[@]}"
  allowed="${allowed%,}"
  HOUSE_RULES_ALLOWED="${allowed}" house_rules::yq "${out_file}" "${err_file}" \
    "${HOUSE_RULES_UNKNOWN_KEYS_EXPR}" "${config_file}"
  house_rules::require_file "${out_file}"
  while IFS= read -r line; do
    house_rules::config_error "unknown lint '${line}'; known: ${known_list}"
    errors=$((errors + 1))
  done < "${out_file}"

  HOUSE_RULES_LINT="${lint}" house_rules::yq "${out_file}" "${err_file}" \
    --output-format=json '.[strenv(HOUSE_RULES_LINT)]' "${config_file}"

  house_rules::return_count "${errors}"
}

# @description Return an error count as an exit status, capped at 255 so that
#              256 errors cannot wrap to success.
# @arg $1 errors the error count
# @exitcode * the capped count
function house_rules::return_count() {
  local -r errors="$1"
  if ((errors > HOUSE_RULES_MAX_STATUS)); then
    return "${HOUSE_RULES_MAX_STATUS}"
  fi
  return "${errors}"
}
