# house-rules

Shared lints for my Nix-based repos, published as a flake. A consuming repo adds one flake input, puts the lints it
wants in its devShell, and has its gate call them, so the lint runs the same locally and in CI.

## Lints

- [`check-workflow-hermetic`](#check-workflow-hermetic): every GitHub Actions `run:` step goes through the repo's
  devShell wrapper.

Each lint is a flake package named after the lint. There is no `default` package and no aggregate runner.

## Adding the flake to a consumer

1. Add the input to `flake.nix`, following the consumer's own nixpkgs:

   ```nix
   inputs.house-rules = {
     url = "github:rvenutolo/house-rules";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

2. Add the lint to the devShell's packages:

   ```nix
   house-rules.packages.${system}.check-workflow-hermetic
   ```

3. If the repo keeps a `.ci/required-tools` list, add `check-workflow-hermetic` there.
4. Call `check-workflow-hermetic` from the repo's gate, inside the devShell, so the pre-push hook, the `just` recipes
   and CI all run it.
5. Optionally add a `.house-rules.yml` at the repo root (see below).

Renovate's `nix` manager and `lockFileMaintenance` keep `flake.lock` current.

### External contract

The input URL `github:rvenutolo/house-rules` and the package name `check-workflow-hermetic` are checked by
`github-repos-audit`. Renaming either lands a matching change there first.

## `.house-rules.yml`

One optional file at the consuming repo's root holds every lint's config, under one top-level key per lint. Each lint
finds it at `<git repo root>/.house-rules.yml`, whatever directory it runs from.

- No file, an empty file, or a missing or empty section: the lint runs with its defaults and no exemptions.
- The file holds exactly one YAML document, and its top level is a map.
- Every top-level key is a known lint name (currently `check-workflow-hermetic`), so a misspelled section cannot
  silently disable a lint's exemptions.

### `check-workflow-hermetic` section

```yaml
check-workflow-hermetic:
  wrapper: .ci/in-devshell # optional; this is the default
  exempt:
    - step: .github/actions/changed-tests/action.yml::decide
      reason: >-
        Runs before setup installs Nix. It decides whether the Nix jobs run at all, so it cannot depend on them.
```

- `wrapper`: optional string, the repo-relative path a compliant `run:` body must name. Default `.ci/in-devshell`. It
  must be a single line and not blank. A bare `wrapper:` with no value is an error, not the default.
- `exempt`: optional list of entries; a bare `exempt:` with no value is an error, not an empty list. Each entry has
  exactly two keys:
  - `step`: `<repo-relative-file>::<step-id>`, a single-line string with exactly one `::` and a non-blank file part and
    id part. The id is the step's YAML `id:`.
  - `reason`: a non-blank string saying why the step cannot use the wrapper.

### Config errors

The lint reports config errors, one line each as `.house-rules.yml: <problem>`, then `<N> .house-rules.yml error(s)`,
and exits 1 without scanning. Keys in messages are escaped onto one line, so a key holding a newline or carriage
return prints as `\n` or `\r`.

File level:

- `not valid YAML: <yq's error>`
- `holds <N> YAML documents; expected one`
- merge keys, aliases and tags other than the core tags (`!!map`, `!!seq`, `!!str`, `!!null`, `!!int`, `!!bool`,
  `!!float`), anywhere in the file: `merge key '<<' is not supported (in <where>)`,
  `YAML alias '*<name>' is not supported (in <where>)` and
  `YAML tag '<tag>' is not supported (in <where>); quote the value or drop the tag`. Any of these would change what a
  later read sees, such as adding a key or overriding `step` unseen. They are reported alone: the checks below do not
  run while one is present.
- `top level must be a map`
- `unknown lint '<key>'; known: <names>` for a top-level key that is not a lint name
- `duplicate key '<key>' in <where>` for a mapping key repeated at the top level or anywhere inside the lint's section

Section level, each line prefixed with the lint's name and a colon (`check-workflow-hermetic:`), except the first:

- `check-workflow-hermetic must be a map` (no further prefix)
- `wrapper must be a string`, `wrapper must not be empty`, `wrapper must be a single line`
- `exempt must be a list`
- `unknown key '<key>'` in the section, and `exempt[<i>]: unknown key '<key>'` in an entry
- `exempt[<i>] must be a map`
- `exempt[<i>]: step is missing`, `step must be a string`, or `step '<step>' is not <file>::<id>` (exactly one `::`,
  both parts non-blank, no control characters)
- `exempt[<i>]: reason is missing or empty`, `reason must be a string`
- `exempt[<i>]: duplicate step '<step>'`

## `check-workflow-hermetic`

```bash
check-workflow-hermetic          # scan the repo containing the working directory
check-workflow-hermetic --help   # print usage, exit 0
```

It scans every `*.yml` and `*.yaml` file under `.github/workflows` and `.github/actions`, recursively, following
symlinks. It exits 0 when the config is valid and nothing is found, and 1 otherwise, with a final
`<N> hermetic-boundary violation(s)` line. Any other argument is an error.

- **Rule 1:** every step with a `run:` key names the wrapper in its run body, unless an exemption covers it. The test
  is a substring match on the whole body, and a body that is not a plain string never matches. A violation reads
  `<file>::<id>: run step does not invoke <wrapper>`. A step with no `id:` is reported as
  `<file>: job '<job>' step #<index> (<name>) does not invoke <wrapper> and has no YAML id:; add one (...)`, because a
  step's `name:` is free text and drifts. Steps in workflows (`jobs.<job>.steps`) and composite actions (`runs.steps`)
  are both checked.
- **Rule 2:** no scanned file enters the devShell directly, spelled `nix` and `develop` separated by whitespace. Only
  the wrapper may do that. A violation reads `<file>: spells "nix develop"; only <wrapper> may enter the devShell`. The
  match runs on the raw text, so a comment counts, and on each decoded string value, so a spelling folded across lines
  of a plain scalar or written with a YAML escape counts too. Runs of whitespace, newlines included, and a backslash
  line continuation count as the separating space. Names such as `in-devshell` and `nix-installer-action` do not match.
- **Stale exemptions** are violations: `stale exemption in .house-rules.yml: <key> matches no run step`, or
  `... <key> already invokes <wrapper>` when it names only steps that already invoke the wrapper.
- **Ambiguous exemptions** are violations: `ambiguous exemption in .house-rules.yml: <key> matches <N> run steps; give
  each step a unique id`. A `<file>::<id>` key that names an unwrapped step and at least one other run step in the file
  (the same id in two jobs, or in two YAML documents) exempts none of them. Give each exempted step a unique id.
- **Unparsable workflow files** are violations: `<file>: not valid YAML`. They do not stop the scan of other files. A
  duplicate mapping key in a scanned file is reported as `<file>: not valid YAML: duplicate key '<key>' in <where>`.
- **Non-core YAML tags** in a scanned file are violations:
  `<file>: YAML tag '<tag>' is not supported (in <where>); quote the value or drop the tag`. A custom tag changes what a
  node means to each parser that reads it. An unquoted date such as `RELEASE_DATE: 2024-01-01` carries the
  `!!timestamp` tag, so quote it.
- **A scan root that exists but is not a directory** (for example `.github/workflows` as a regular file, or a symlink
  to one) is a violation: `<root>: not a directory`. A missing root is fine.
- **Aliases and merge keys** in scanned files are resolved: a `run:` key reached through either is scanned, and a
  local key wins over a merged one.
- **Outside a git repository** the lint prints `check-workflow-hermetic: not inside a git repository` and exits 1.

## Developing this repo

### Local gate

Every command runs inside the repo's hermetic devShell through `.ci/in-devshell`. The `just` recipe beside each is an
optional shortcut.

- `./.ci/in-devshell ./run-all-checks`: `nix flake check`, the darwin evaluation check, `check-workflow-hermetic` on
  this repo's own workflows, the lints, then the tests (`just check`)
- `./.ci/in-devshell ./.ci/check-darwin-eval`: evaluates every package, without building, for each darwin system the
  flake exports. CI runs on Linux only, and some consumers' devShells evaluate on macOS, so a package that fails to
  evaluate there would break them. The systems come from the flake's own `packages` outputs, so exporting no darwin
  system is a failure, not a skip.
- `./.ci/in-devshell ./.ci/run-lint-checks`: the lints alone (`just lint`)
- `./.ci/in-devshell ./run-tests`: the BATS suite under `test/` (`just test`)
- `./.ci/in-devshell nix fmt`: treefmt over every tracked file (`just fmt`)

Entering the devShell (`nix develop`) points `core.hooksPath` at `.githooks`. `pre-push` runs the full gate and
`commit-msg` runs commitlint.

Nix evaluates only tracked files, so `git add` a new file before running anything through `.ci/in-devshell`.

### After editing a lint

Run the tests from a plain shell, through `./.ci/in-devshell ./run-tests`. Inside an existing wrapper session
`IN_DEVSHELL` short-circuits re-entry, so `PATH` still holds the package built before the edit and the tests run the
old lint. The tests exercise the built package, not the source file.

### Changes that would fail a consumer

A change to a lint that makes an existing consumer fail lands that consumer's fix first: its exemption, its config
correction or its workflow change. Then the lint change lands here and the consumer updates its `flake.lock`.
