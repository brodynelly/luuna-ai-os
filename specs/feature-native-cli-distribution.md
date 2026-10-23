# Feature: Public native CLI distribution for the Luuna suite

## Summary

Give the public Luuna CLIs (Atlas, Beacon, Missions, Roots) a native, checksum-verified distribution path that does not depend on npm, Bun, or the private Luuna runtime:

- **Each component repo** (`luuna-atlas`, `luuna-beacon`, `luuna-missions` in Go, `luuna-roots` in Rust) owns its own build. It gets a packaging script and a release workflow. The workflow builds platform archives, checksums and a provenance record, then uploads them only as workflow artifacts. **Nothing is published.**
- **This hub** (`luuna-ai-os`) gets the following:
  - an offline-testable POSIX installer for macOS and Linux
  - an immutable, versioned release-manifest format
  - a public dispatcher (`luuna-suite`) that cannot collide with the private `luuna`/`lu`
  - upgrade, rollback and uninstall that never touch project stores
  - a controlled per-repo `claude -p` orchestration entrypoint around the existing `adw.sh`
  - documentation and release gates
- The plan defers these deliberate owner actions: npm scope/packages, GitHub Releases, signing/notarization, GitHub attestations, and advertising a public one-line install.

## Current state (read, not assumed)

| Location | Fact | Consequence |
| --- | --- | --- |
| `README.md`, `docs/PACKAGING.md` | They describe the components as "private Bun TypeScript sources" and the only install as the Windows source installer. They say the npm scope is unclaimed. | These docs are stale for the Go/Rust native cores. They must be rewritten without claiming that published installs exist. |
| `scripts/install-cli.ps1` | It is Windows-only and needs Bun 1.4.3, the **private** `luuna` checkout and its installer. It writes `%LOCALAPPDATA%\Luuna\bin`, which also installs the private `luuna`/`lu`. | It cannot be the public path. Windows public install is **explicitly unsupported** in this scope (see Windows decision). |
| `.gitmodules` / `sources/*` | Seven submodules, uninitialized. | Hub tasks must not need them. Tests must not run `git submodule update`. Pins must stay unchanged. |
| No `tests/`, `specs/`, CI or validation commands in the hub | — | **Prerequisite P0**: create the dependency-free test surface before anything else. |
| `../luuna-atlas` | `go.mod` (go 1.27.0, vendored), `cmd/luuna-atlas/main.go`. Bun `package.json` bins: `luuna-atlas`, `lat`, `la`. CI: `bun run verify` on ubuntu and windows. | The Go binary is built from `./cmd/luuna-atlas` with `-mod=vendor`. Public aliases: `lat`. |
| `../luuna-beacon` | `go.mod`, `cmd/{luuna-beacon,lbc,lb}`. `Makefile` verify = test+vet+build. | Public aliases: `lbc`. |
| `../luuna-missions` | `go.mod`, `cmd/luuna-missions/main.go`. Bun bins: `luuna-missions`, `lms`, `lm`, `missions`. | Public aliases: `lms`. |
| `../luuna-roots` | Cargo workspace (edition 2024, rust 1.85), `roots-cli` bins `luuna-roots`, `lrt`. Version `0.0.0`. | Public aliases: `lrt`. |
| `/Users/bnelly/github/luuna-ai-os-main/.agents/skills/adw/scripts/adw.sh` | It runs `claude -p` steps with `--permission-mode acceptEdits` by default (`TAC_CLAUDE_ARGS`). It works on `git rev-parse --show-toplevel` of the cwd. `--pr` commits, pushes and opens a PR. It writes `.tac/` in the target repo and pre-approves `Skill(tac-final:*)`. | The hub wrapper must pin the cwd, forbid `--pr`, add turn and tool bounds, and check that the tac-final plugin is installed before running. |

### Public executable set (frozen by this spec)

| Component | Primary | Public alias | Deliberately excluded (generic or collision-prone) |
| --- | --- | --- | --- |
| Atlas | `luuna-atlas` | `lat` | `la` |
| Beacon | `luuna-beacon` | `lbc` | `lb` |
| Missions | `luuna-missions` | `lms` | `lm`, `missions` |
| Roots | `luuna-roots` | `lrt` | — |
| Dispatcher (hub) | `luuna-suite` | — | `luuna`, `lu` (owned by the private runtime and **never installed** by the public installer) |

Component repos may keep their extra Bun aliases for source use. The public archives contain only the primary and the public alias.

## Design decisions

1. **The manifest is line-oriented TSV, not JSON.** A POSIX `sh` installer can parse it without `jq` or Python. Path: `releases/<suite-version>/manifest.tsv`.
   - Line 1: `luuna-suite-manifest	1`.
   - Line 2: `suite	<suite-version>`.
   - Then one row per asset: `asset	<component>	<component-version>	<os>	<arch>	<https-url>	<sha256>	<archive-file-name>	<comma-separated executables>`.
   - Allowed values:
     - `os` ∈ {`darwin`,`linux`}
     - `arch` ∈ {`arm64`,`amd64`}
     - `component` ∈ {`atlas`,`beacon`,`missions`,`roots`}
     - executables must be a subset of the public executable set
     - sha256 is 64 lowercase hex characters
     - URL must start with `https://github.com/brodynelly/luuna-<component>/releases/download/`
2. **Immutability.**
   - `releases/INDEX.tsv` lists `<suite-version>	<sha256 of manifest.tsv>`.
   - `tests/check-manifests.sh` checks:
     - every manifest validates
     - every manifest matches its index hash
     - versions are unique
     - against a base ref (`git diff --name-status <base> -- releases/`), only additions (`A`) are allowed under `releases/<v>/`, and only appended lines in `INDEX.tsv`
   - **No real manifest is committed in this scope.** `releases/` contains only `README.md`, an empty `INDEX.tsv` header, and the format spec. Real checksums are never invented.
3. **Install layout (per user, no sudo):**
   - `LUUNA_SUITE_HOME` (default `${XDG_DATA_HOME:-$HOME/.local/share}/luuna-suite`) contains:
     - `versions/<suite-version>/bin/…`
     - `current -> versions/<v>`
     - `previous -> versions/<old>`
     - `receipt.tsv`
   - `LUUNA_SUITE_BIN` (default `$HOME/.local/bin`) gets symlinks only for executables the receipt owns.
   - The installer never writes `.luuna/`, `~/.luuna`, `~/.pi`, any repo, or any path outside these two roots. It refuses to replace a bin entry it does not own: an existing file, or a symlink that does not point into `LUUNA_SUITE_HOME`.
4. **Safety pipeline per asset:**
   1. Resolve the manifest row for the detected `uname -s/-m` (normalize `x86_64→amd64`, `aarch64→arm64`). If no row matches, exit 3 with "unsupported platform", and the filesystem stays unchanged.
   2. Fetch into a private `mktemp -d` staging dir inside `LUUNA_SUITE_HOME` (same filesystem). The source is either a local `--asset-dir` (offline/test) or an https URL fetched with `curl --proto =https --tlsv1.2 -fsSL` or `wget --https-only`.
   3. Verify SHA256 with `sha256sum` or `shasum -a 256`. On mismatch, exit 4.
   4. List the archive with `tar -tzvf`. Reject absolute paths, any `..` segment, symlinks, hardlinks, devices, and any entry other than `bin/<listed executable>` (exit 5). Extract only after the listing is clean, then verify every listed executable is a regular, executable file.
   5. After **all** components pass staging, swap atomically:
      - `mv` stage → `versions/<v>`
      - `ln -s` to a temporary name, then `mv -f` over `current`
      - relink bin entries
      - write the receipt last
   6. On any failure before the swap, delete the staging dir. `current`, `previous` and the bin links stay byte-identical.
5. **Upgrade/rollback/uninstall:**
   - `install.sh --manifest M` upgrades in place and keeps one `previous`.
   - `install.sh --rollback` swaps `current`/`previous`.
   - `install.sh --uninstall` removes only receipt-listed bin links that still point into `LUUNA_SUITE_HOME`, then `LUUNA_SUITE_HOME` itself.
   - `--uninstall --keep-versions` is not needed and is not added.
   - Project stores (`<repo>/.luuna/**`) are never enumerated. A test proves they survive.
6. **The dispatcher `luuna-suite`** is a POSIX sh script shipped from the hub (`scripts/luuna-suite`), not from a component archive. It supports:
   - `luuna-suite <atlas|beacon|missions|roots> [args]`, which runs `exec`s the sibling primary in its own `bin` dir.
   - `luuna-suite version`, which prints the suite version and receipt rows.
   - `luuna-suite doctor`, which reports the PATH resolution of every public name and of `luuna`/`lu`. It only reports; it never modifies anything. It says whether `luuna` resolves outside `LUUNA_SUITE_HOME` (expected: private runtime or absent).
7. **Windows decision.**
   - The public native installer does **not** support Windows in this scope.
   - `scripts/install-cli.ps1` stays as the *private developer source install*. It requires private Luuna access and Bun. A header comment and the docs say so.
   - The script's behavior is unchanged: modernizing it would touch the private runtime installer and is not independently justified here.
   - Docs must not imply Windows native archives exist. Windows `.zip` assets plus a PowerShell installer become a follow-up spec once the POSIX path is proven.
8. **Provenance without publication.** Component workflows emit `provenance.json` as an artifact. It records repo, commit, ref, workflow run id, runner OS/arch, toolchain versions, build flags and the archive SHA256s. GitHub `attest-build-provenance` needs `id-token`/`attestations: write` and creates a stored attestation. It is **deferred** to the owner release gate and goes in the workflow only as a commented, disabled step.
9. **Orchestration entrypoint** is `scripts/adw-component.sh` (details in task H6). It runs `adw.sh` with cwd set to exactly one sibling repo. It never runs inside the hub, and it never lets `--pr` through.

## Prerequisites (dependency order)

- **P0 (first; blocks everything in the hub):** set up the dependency-free test surface (task H0). It needs only the following on macOS and Linux: `sh`, `tar`, `gzip`, `mktemp`, `sha256sum` or `shasum`, `grep`, `sed`, `awk`, `ln`, `mv`. No network, Bun, Go, Rust, npm, or submodule checkout.
- **P1:** the manifest format and validator (H1) come before the installer (H2), because the installer reuses the validator logic.
- **P2:** the component subplans (C-atlas, C-beacon, C-missions, C-roots) are independent of each other and of the hub. The hub can merge first because the tests use generated fixtures only. The first **real** manifest needs component archives from a real owner-run release, so it is out of scope.
- **Toolchains (component repos only):** Go 1.27.0 (already pinned in CI), Rust ≥1.85 with `cargo`, and the existing Bun 1.4.3 for those repos' existing `verify`. The release workflows do not require Bun.
- **Owner-only, deferred:** GitHub Releases creation, tag pushing, signing/notarization (Apple Developer ID), GitHub attestations, npm scope control, `@luuna-ai-os/*` publication, and any public "curl | sh" URL.

## Repo boundaries (hard rule for agents)

Each task block below names exactly **one** repository. An agent working a block:

- may only edit files inside that repository's root
- must run its validation from that root
- must treat every other repository as read-only

Hub agents never edit `../luuna-*`. Component agents never edit the hub, the `.agents/` skill directory, `sources/` submodules, or the private `luuna`/`luuna-ai` repos. No task commits, pushes, tags, creates releases or PRs, publishes, or changes visibility. `sources/*` submodule pins must not change.

## Relevant files

### Hub (`luuna-ai-os`), new
- `tests/run.sh`: the test runner. Runs every `tests/test-*.sh` in a fresh `mktemp -d` sandbox with `HOME`, `XDG_DATA_HOME`, `LUUNA_SUITE_HOME`, `LUUNA_SUITE_BIN` and `PATH` isolated. Prints `ok`/`not ok` per case and exits non-zero on any failure.
- `tests/lib.sh`: assertion helpers, plus `make_fixture_release <dir> <version> [mutations]`, which builds stub archives with tiny `#!/bin/sh` executables and computes real SHA256s of those generated stubs at test time. It also offers malicious archive builders for traversal, absolute paths, symlinks and extra entries.
- `tests/test-manifest.sh`, `tests/test-install.sh`, `tests/test-upgrade-rollback.sh`, `tests/test-uninstall.sh`, `tests/test-dispatcher.sh`, `tests/test-adw-component.sh`, `tests/test-docs.sh`.
- `tests/check-manifests.sh`: validates `releases/` (format, index hash, append-only against `--base <ref>`).
- `tests/README.md`: how to run, the required tools, and what the tests do not prove.
- `scripts/lib/manifest.sh`: shared POSIX manifest parse and validate.
- `scripts/install.sh`: the installer, `--manifest PATH | --version V`, `--asset-dir DIR`, `--rollback`, `--uninstall`, `--dry-run`, `--help`.
- `scripts/luuna-suite`: the dispatcher.
- `scripts/adw-component.sh`: the orchestration entrypoint.
- `releases/README.md`, `releases/FORMAT.md`, `releases/INDEX.tsv` (header only).
- `docs/RELEASING.md`: the owner release gates.
- `.github/workflows/distribution-tests.yml`: `ubuntu-latest` and `macos-latest`, `permissions: contents: read`, runs `sh tests/run.sh` and `sh tests/check-manifests.sh --base origin/main`. No secrets, no publish steps.

### Hub, modified
- `README.md`: replaces the "Install" section with the status as it stands: native installer exists, **no releases published yet**, install from a checkout against a manifest once one exists, Windows unsupported for public install. Removes or downgrades the stale "Bun TypeScript" description.
- `docs/PACKAGING.md`: native releases first; npm is a deferred optional channel. Documents the dispatcher naming and the separation from the private runtime.
- `scripts/install-cli.ps1`: header comment only ("private developer source install; requires private Luuna access; not the public installer"). No logic change.

### Component repos, new (each only in its own repo)
- `scripts/release/package.sh`: builds the public executables for one `--os/--arch` (or host), writes `dist/luuna-<component>_<version>_<os>_<arch>.tar.gz` with entries `bin/<primary>` and `bin/<alias>` (regular files, mode 0755, no directories other than `bin/`, deterministic `--owner 0 --group 0` where supported), `dist/SHA256SUMS`, and `dist/provenance.json`.
- `scripts/release/check-archive.sh`: re-verifies an archive (entry allow-list, no links, executables run `--version` or `--help` exit 0 on host-matching archives).
- `.github/workflows/release.yml`:
  - triggered by `workflow_dispatch` (input `version`) only; **no tag trigger** until the owner enables it
  - `permissions: contents: read`
  - runner matrix: `macos-14` (darwin/arm64), `macos-15-intel` (darwin/amd64), `ubuntu-latest` (linux/amd64), `ubuntu-24.04-arm` (linux/arm64). **Deviation (build time):** the original draft named `macos-13` for darwin/amd64. That GitHub-hosted image is retired, so it was replaced with `macos-15-intel`. The runner remains native per platform and needs no cross toolchain.
  - steps: run tests → `package.sh` → `check-archive.sh` → `actions/upload-artifact`
  - no `gh release`, `softprops/action-gh-release`, `npm publish`, `cargo publish`, or attestations (the attest step is present but commented out and marked as an owner gate)
- `docs/RELEASING.md` (component-local): how to dry-run locally and which owner steps are deferred.

## Step by Step Tasks

Execute in order. H-tasks are hub-only. C-tasks are one-repo-each and may run in parallel after H0, or before it.

### H0 — Hub test surface (FIRST; repo: luuna-ai-os)
1. Create `tests/run.sh` and `tests/lib.sh`. They are POSIX `sh` (`set -eu`), contain no bashisms, and use a sandbox per test file. They abort if `HOME` would resolve to the real home: `LUUNA_SUITE_HOME` must be under the sandbox.
2. Add `tests/test-smoke.sh`, which asserts that the required tools exist, and `tests/README.md`.
3. Add `.github/workflows/distribution-tests.yml` (read-only permissions).
4. Validation: `sh tests/run.sh` passes with the smoke test alone.

### H1 — Manifest format and validator (repo: luuna-ai-os)
1. Write `releases/FORMAT.md` (design decision 1), `releases/README.md` ("no releases are published; manifests are added only through the owner gate in docs/RELEASING.md"), and `releases/INDEX.tsv` with header `#suite-version	manifest-sha256`.
2. Implement `scripts/lib/manifest.sh`. Functions: `manifest_validate FILE`, and `manifest_select FILE OS ARCH` (prints rows; fails if any of the four components is missing for the platform).
3. Implement `tests/check-manifests.sh [--base REF]`.
4. Add `tests/test-manifest.sh` cases:
   - valid fixture
   - bad header
   - bad sha (63 characters, uppercase)
   - non-https URL
   - URL for the wrong repo
   - unknown component
   - non-public executable name (`luuna`, `lu`, `la`)
   - duplicate row
   - CRLF line endings rejected
   - index hash mismatch
   - modified-existing-manifest rejection using a throwaway `git init` repo in the sandbox

### H2 — Installer (repo: luuna-ai-os)
1. Implement `scripts/install.sh` following design decisions 3–5.
   - Use `umask 022` and `trap` cleanup of staging.
   - Without `--asset-dir`, require https URLs from the validated manifest.
   - `--version V` resolves to `releases/V/manifest.tsv` relative to the script's checkout. It fails clearly when that file is missing, which it currently always is.
   - Never `eval` manifest content. Quote every expansion.
   - Exit codes: 0 ok, 2 usage, 3 unsupported platform, 4 checksum, 5 unsafe archive, 6 ownership conflict, 7 fetch failure.
   - Install `scripts/luuna-suite` into `versions/<v>/bin/luuna-suite`.
2. Allow `LUUNA_SUITE_UNAME_S`/`LUUNA_SUITE_UNAME_M` overrides for platform detection. These exist for tests and are documented as such.
3. Add `tests/test-install.sh` cases, each asserting the exit code **and** that the filesystem is unchanged on failure:
   - success: all five commands linked and `lat --help` runs the stub
   - corrupted archive: byte flipped, so the checksum fails
   - wrong checksum in the manifest
   - path traversal (`bin/../../evil`)
   - absolute path entry
   - symlink entry
   - extra unexpected entry
   - missing listed executable
   - unsupported platform (`Windows_NT`, `FreeBSD`, `riscv64`)
   - pre-existing foreign `$LUUNA_SUITE_BIN/lat` file, giving exit 6 with the file untouched
   - pre-existing `$LUUNA_SUITE_BIN/luuna`, which is never touched or linked
   - `--dry-run` writes nothing
   - an https URL without `--asset-dir`, run with `curl`/`wget` stubbed to fail on `PATH`, giving exit 7 and proving no real network is used

### H3 — Upgrade, rollback, uninstall (repo: luuna-ai-os)
1. Add `tests/test-upgrade-rollback.sh`:
   - install v1 then v2: `current`→v2, `previous`→v1
   - v3 with a corrupted *last* component fails, and v2 stays current and intact (proves the atomic swap)
   - `--rollback` returns to v1
   - a second `--rollback` returns to v2
   - `--rollback` with no `previous` exits non-zero with no change
2. Add `tests/test-uninstall.sh`:
   - create `$SANDBOX/project/.luuna/{missions,atlas}/data` and `$HOME/.luuna/keep`
   - install, then uninstall
   - assert both project stores are byte-identical, the receipt-owned links are gone, a foreign file in the bin dir survives, and `LUUNA_SUITE_HOME` is removed
   - uninstall when nothing is installed exits 0 with no changes

### H4 — Dispatcher (repo: luuna-ai-os)
1. Implement `scripts/luuna-suite` per design decision 6. It resolves its own real directory without `readlink -f`, which is missing on older macOS; it uses a `cd`/`pwd -P` loop.
2. Add `tests/test-dispatcher.sh`:
   - routes each component and passes arguments through with spaces
   - unknown subcommand gives exit 2
   - `doctor` reports a sandbox fake `luuna` as "outside suite (private runtime or other)" and does not modify it
   - `version` prints the receipt

### H5 — Windows posture (repo: luuna-ai-os)
1. Add the header comment to `scripts/install-cli.ps1`. No logic change.
2. Docs state "Public native install: macOS and Linux (x86_64, arm64). Windows: not supported by the public installer; the PowerShell script is a private developer source install."

### H6 — Orchestration entrypoint (repo: luuna-ai-os)
1. Implement `scripts/adw-component.sh <atlas|beacon|missions|roots> [adw options] <task|--spec PATH>`.
   - **Repo resolution:** resolve `${LUUNA_COMPONENTS_ROOT:-<hub parent dir>}/luuna-<component>` with `pwd -P`. Require all of the following:
     - it is a git work tree whose toplevel equals that path
     - `origin` is one of `https://github.com/brodynelly/luuna-<component>(.git)` or `git@github.com:brodynelly/luuna-<component>.git`
     - it is not the hub
     - it is not a path under `sources/`
   - **ADW script:** `${LUUNA_ADW_SCRIPT:-/Users/bnelly/github/luuna-ai-os-main/.agents/skills/adw/scripts/adw.sh}` must exist and be readable. Run it with `bash`, never `source`.
   - **Plugin preflight:**
     - `CLAUDE_BIN` (default `claude`) must be on PATH
     - `"$CLAUDE_BIN" plugin list` output must contain `tac-final`
     - otherwise exit 2 with install guidance
     - the preflight never installs the plugin
   - **Rejected options:** `--pr`, `--base` without `--worktree`, `--issue` (it would pull remote content, so it is out of scope; documented), and any `-w sdlc`. Allowed workflows: `plan_build`, `plan_build_test`, `plan_build_review_fix`.
   - **Bounds:**
     - export `TAC_CLAUDE_ARGS="--permission-mode acceptEdits --max-turns ${LUUNA_ADW_MAX_TURNS:-40} --disallowedTools \"Bash(git push *)\" \"Bash(git commit *)\" \"Bash(git tag *)\" \"Bash(gh *)\" \"Bash(npm publish *)\" \"Bash(cargo publish *)\" \"Bash(curl *)\" \"Bash(wget *)\""` plus an optional `LUUNA_ADW_ALLOWED_TOOLS` appended as `--allowedTools …` for that repo's validation commands
     - `LUUNA_ADW_MAX_TURNS` must be an integer from 1 to 200
     - refuse if the caller already set `TAC_CLAUDE_ARGS` containing `bypassPermissions` or `dangerously`
   - **Execution:** `cd "$repo"` then `exec bash "$adw" "$@"`. Default to `--worktree` so the user's checkout stays untouched; `--no-worktree` opts out and then requires a clean tree.
   - **Logging:** print the resolved repo, ADW path, workflow and bounds before running. `--dry-run` passes through to `adw.sh`.
2. Add `tests/test-adw-component.sh`. It uses a fake `CLAUDE_BIN` script, which prints `tac-final` for `plugin list` and records argv otherwise, and a fake `LUUNA_ADW_SCRIPT`, which records cwd, argv and `TAC_CLAUDE_ARGS`. It also uses throwaway git repos with crafted origins. Cases:
   - correct cwd
   - wrong origin refused
   - missing repo refused
   - hub path refused
   - plugin missing refused
   - `--pr` refused
   - `sdlc` refused
   - `bypassPermissions` refused
   - bad max-turns refused
   - the bounds string contains the push/gh/publish denials
   - `--worktree` is the default
3. Document it in `docs/RELEASING.md` § "Agent orchestration". Note that `adw.sh` writes `.tac/` in the component repo and that review and merge stay human.

### H7 — Docs and public release gates (repo: luuna-ai-os)
1. Write `docs/RELEASING.md` with the owner gate checklist:
   1. Component owner runs `release.yml` via `workflow_dispatch` and downloads the artifacts.
   2. Verify `SHA256SUMS`, `check-archive.sh` and `provenance.json` locally on each claimed platform.
   3. *(Owner)* Decide on signing/notarization and attestations.
   4. *(Owner)* Create the tag and GitHub Release and upload the assets.
   5. Add `releases/<v>/manifest.tsv` with URLs and SHA256s copied from the released assets, plus an `INDEX.tsv` line, through a reviewed PR.
   6. *(Owner, networked)* Do a clean-machine install on macOS arm64/amd64 and Linux amd64/arm64 using `scripts/install.sh --version <v>`.
   7. Only then update the README with the verified install command.
   8. npm (`@luuna-ai-os/*`) remains a separate, later decision per the existing PACKAGING sequence.
2. Rewrite the README install section and `docs/PACKAGING.md` per the "Relevant files" section.
3. Add `tests/test-docs.sh`, which fails if any of the following holds:
   - README/docs present `npm install -g @luuna-ai-os` outside a "not yet published" context. The check requires the phrase `not published` within the same paragraph.
   - README contains a `curl … | sh` or `| bash` line.
   - Any 64-hex string appears under `releases/` (excluding the header). Real checksums only arrive through the owner gate, and this check is removed or relaxed in that PR.
   - Docs claim Windows native or public installer support.
   - The public installer or dispatcher references `luuna`/`lu` as a link target.

### C-atlas — repo: luuna-atlas only
1. Add `scripts/release/package.sh`. Build `CGO_ENABLED=0 GOOS GOARCH go build -mod=vendor -trimpath -ldflags "-s -w -X …version"` for `./cmd/luuna-atlas`, producing `bin/luuna-atlas`, plus a second build or copy as `bin/lat`. Confirm `lat` dispatch does not depend on argv[0] semantics that differ; if it does, record that. Then tar, write SHA256SUMS and write provenance.json.
2. Add `scripts/release/check-archive.sh`, `.github/workflows/release.yml` and `docs/RELEASING.md`, as described above.
3. Do not alter `package.json` bins, existing CI, or Bun sources. Do not edit any other repo.

### C-beacon — repo: luuna-beacon only
Same as C-atlas, except:
- build `./cmd/luuna-beacon` → `bin/luuna-beacon` and `./cmd/lbc` → `bin/lbc`, and exclude `lb`
- no `-mod=vendor` unless a `vendor/` dir exists
- add `release-local` to the `Makefile` calling the script

### C-missions — repo: luuna-missions only
Same as C-atlas, except:
- build `./cmd/luuna-missions` → `bin/luuna-missions` and `bin/lms`
- exclude `lm` and `missions`

### C-roots — repo: luuna-roots only
1. `package.sh` runs `cargo build --release --locked -p roots-cli --target <triple>` for `aarch64-apple-darwin`, `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` (native runner per triple, so no cross toolchain is needed). It packages `bin/luuna-roots` and `bin/lrt`.
2. The version comes from the `--version` input. Do not bump `Cargo.toml` (`0.0.0`); a version bump is an owner release action.
3. Add `check-archive.sh`, `release.yml` (including `cargo test --workspace --locked` before packaging) and `docs/RELEASING.md`. Do not edit any other repo.

## Build deviations (recorded by the hub builder)

These changes from the draft above were made deliberately. Each one is safety-driven.

1. **Runner matrix.** `macos-13` is retired. darwin/amd64 now uses `macos-15-intel`, and darwin/arm64 stays on `macos-14`. This applies to the component `release.yml` files, which their own agents own.
2. **`current`/`previous` are regular pointer files, not symlinks.**
   - Each file holds one line with a version name.
   - On macOS, `mv -f tmp current` follows a destination symlink that points to a directory, and moves `tmp` *into* it. BSD `mv` has no `-T`.
   - A regular-file pointer is replaced with `rename(2)` through `mv`. The installer refuses to proceed if a pointer is a symlink or a directory.
   - Bin links point at `versions/<v>/bin/<exe>`, which are regular files. Each link is replaced the same way, after an ownership check, so no swap ever follows a destination symlink.
3. **Root validation.** `LUUNA_SUITE_HOME` and `LUUNA_SUITE_BIN` must be absolute. They must not:
   - contain `.`, `..` or `//` segments, or control characters
   - be `/`, `$HOME`, or an ancestor of `$HOME`
   - be a symlink themselves
   - equal each other or be nested in each other

   Violations exit 2.
4. **Ownership marker and lock.**
   - On first install, `LUUNA_SUITE_HOME/.luuna-suite-home` is written. An existing non-empty home without it is refused (exit 6).
   - Uninstall needs the marker, plus a receipt whose `home`/`bin` match the resolved roots. It also needs every top-level entry to be one the installer creates. Otherwise it exits 6 and removes nothing.
   - Uninstall deletes known entries one at a time and finishes with `rmdir`, rather than doing a blind `rm -rf` of the root.
   - Mutating commands hold `LUUNA_SUITE_HOME/.lock`, created with `mkdir`. A held lock gives the new exit code **8**.
5. **`--version V`** also checks the manifest's SHA256 against `releases/INDEX.tsv`.
6. **`adw-component.sh`:**
   - It refuses *any* caller-set `TAC_CLAUDE_ARGS`, not only bypass values, because the wrapper owns that variable.
   - It strictly charset-validates `CLAUDE_BIN`, `LUUNA_ADW_ALLOWED_TOOLS`, `--spec` and `--base`, because upstream `adw.sh` `eval`s `CLAUDE_BIN` and `TAC_CLAUDE_ARGS`.
   - It adds bare-command denials (`Bash(git push)` and so on) next to the `* ` forms.
   - The default ADW path is `<hub parent>/.agents/skills/adw/scripts/adw.sh`. In this checkout that is the same file as the absolute path in H6.

## Acceptance Criteria

- `sh tests/run.sh` passes on macOS and Linux with no network and no Bun/Go/Rust/npm installed, and with `sources/` uninitialized.
- Every failure-path test proves the filesystem is unchanged for these cases: corruption, bad checksum, traversal, absolute path, link entries, unsupported platform, ownership conflict and fetch failure.
- Upgrade keeps exactly one `previous`. A failed upgrade leaves `current` working, and rollback restores it.
- Uninstall removes only receipt-owned links and `LUUNA_SUITE_HOME`. `.luuna/` project stores, `~/.luuna`, and foreign bin files are byte-identical afterwards.
- No installer, dispatcher, or test path creates or overwrites `luuna` or `lu`.
- `scripts/adw-component.sh`:
  - runs `adw.sh` only with cwd equal to a verified sibling component repo
  - refuses `--pr`, `--issue`, `sdlc` and permission bypass
  - fails closed without the tac-final plugin
  - always passes `--max-turns` and the push/commit/gh/publish/network denials
- `releases/` contains no real manifest and no checksum. `INDEX.tsv` is header-only.
- README and docs:
  - advertise no working published install command
  - mark npm as unpublished
  - state that Windows is unsupported for the public installer
  - keep the private Luuna runtime and Luuna-AI desktop out of the public path
- Each component repo can run `scripts/release/package.sh` and `check-archive.sh` for its host platform. Its `release.yml` is `workflow_dispatch`-only, has `contents: read`, and contains no publish, release, attestation or registry step.
- `git status --porcelain sources` is empty, so submodule pins are unchanged. No commits, tags, pushes, releases or packages were created.

## Validation Commands

Hub (run from `/Users/bnelly/github/luuna-ai-os-main/luuna-ai-os`):
- `sh tests/run.sh`
- `sh tests/check-manifests.sh`
- `sh -n scripts/install.sh && sh -n scripts/luuna-suite && sh -n scripts/lib/manifest.sh && sh -n scripts/adw-component.sh && for f in tests/*.sh; do sh -n "$f" || exit 1; done`
- `sh scripts/install.sh --help && sh scripts/install.sh --version 0.0.0 ; test $? -ne 0` (it must fail clearly: no manifest is published)
- `test -z "$(git status --porcelain sources)"`
- Optional, if installed: `shellcheck -s sh scripts/install.sh scripts/luuna-suite scripts/lib/manifest.sh scripts/adw-component.sh tests/*.sh`. Shellcheck is not required, so its absence is not a failure.

Component (each run only inside its own repo):
- luuna-atlas: `go test -mod=vendor ./... && sh scripts/release/package.sh --version 0.0.0-local --out "$(mktemp -d)" && sh scripts/release/check-archive.sh <produced archive>`
- luuna-beacon: `make verify && sh scripts/release/package.sh --version 0.0.0-local --out "$(mktemp -d)" && sh scripts/release/check-archive.sh <produced archive>`
- luuna-missions: `go test ./... && sh scripts/release/package.sh --version 0.0.0-local --out "$(mktemp -d)" && sh scripts/release/check-archive.sh <produced archive>`
- luuna-roots: `cargo test --workspace --locked && sh scripts/release/package.sh --version 0.0.0-local --out "$(mktemp -d)" && sh scripts/release/check-archive.sh <produced archive>`
- Each repo: `grep -nE 'gh release|action-gh-release|npm publish|cargo publish|attest-build-provenance' .github/workflows/release.yml` prints only commented lines.

## Validation limits (what passing does NOT prove)

- The hub tests use generated `#!/bin/sh` stub executables and local fixture archives. They prove the installer logic, not that the real Go/Rust binaries run on every platform, and not real network download, TLS, or GitHub URL behavior.
- Local component packaging proves only the host platform. The other three platforms are proven only when `release.yml` runs on GitHub runners, which is an owner-triggered action not done here. Linux binaries are glibc-linked (Rust) or static (Go with `CGO_ENABLED=0`); musl and Alpine are unclaimed.
- macOS Gatekeeper/quarantine: unsigned, un-notarized binaries fetched by `curl` are normally not quarantined, but behavior when the archive is downloaded via a browser is not covered. Signing and notarization are deferred.
- `provenance.json` is self-reported metadata, not a verifiable attestation, until the owner enables GitHub attestations or signing.
- Atlas/Missions alias behavior (`lat`, `lms`) assumes the Go binary does not branch on argv[0]. Task C-atlas/C-missions must check this and report it.
- Immutability is enforced by tests and review, not by GitHub branch protection, which is an owner setting.
- The `adw-component.sh` tests use a fake `claude` and a fake `adw.sh`. A real run's turn bound and tool denials rely on Claude Code honoring `--max-turns`/`--disallowedTools`. `.tac/` artifacts land in the component repo.
- Windows is not validated by any of this. The PowerShell script's behavior is unchanged and untested.

## Out of scope / deferred owner actions

npm scope and packages, GitHub Releases, tags, signing and notarization, attestations, Homebrew taps, Windows archives and installer, a hosted `curl | sh` URL, integrating Roots into the runtime, any change to the private `luuna` runtime or the `luuna-ai` desktop app, and submodule pin updates.
