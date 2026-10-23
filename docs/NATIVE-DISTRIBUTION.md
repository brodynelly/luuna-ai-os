# Native distribution (installer, dispatcher, ADW wrapper)

**Status: no suite release has been published.** `releases/INDEX.tsv` is header-only, so `install.sh --version V` always fails. The `@luuna-ai-os/*` npm packages are not published. Owner steps are listed in [RELEASING.md](RELEASING.md). The specs are `specs/feature-native-cli-distribution.md` and `specs/patch-native-cli-transaction-safety.md`.

## Public suite vs private runtime

- **Public:** `luuna-atlas`/`lat`, `luuna-beacon`/`lbc`, `luuna-missions`/`lms`, `luuna-roots`/`lrt` and the `luuna-suite` dispatcher (`scripts/luuna-suite`: `<component> [args]`, `version`, `doctor`). Only names in `PUBLIC_NAMES` are ever linked.
- **Private:** `luuna` and `lu` belong to the private runtime. The installer and dispatcher never install, link, invoke or shadow them. `doctor` only reports how they resolve on PATH. `scripts/install-cli.ps1` is a private developer source install, not the public installer.
- Project stores (`.luuna/`, `~/.luuna`, `~/.pi`) and repositories are never written.

## Installer (`scripts/install.sh`)

Modes are `--manifest PATH` or `--version V` (optionally with `--asset-dir DIR` for offline use), `--rollback`, `--uninstall` and `--dry-run`. Exit codes: 2 usage, 3 platform, 4 checksum, 5 archive, 6 ownership, 7 fetch, 8 lock.

- **Manifest:** a tab-separated `releases/<v>/manifest.tsv` ([FORMAT.md](../releases/FORMAT.md)), validated by `scripts/lib/manifest.sh`. `--version` also requires the manifest's SHA256 to match `INDEX.tsv`. Each archive is checksum-verified and its listing is allow-listed before extraction. All components are staged before anything visible changes.
- **Layout under `LUUNA_SUITE_HOME`:**
  - `.luuna-suite-home` marker
  - `versions/<v>/bin/*` plus `versions/<v>/.luuna-suite-version.tsv`
  - `current` and `previous`: regular pointer files, replaced by rename
  - `receipt.tsv`: records home, bin, current, previous and the owned links
  - The command links go in `LUUNA_SUITE_BIN`.
- **Ownership:**
  - Every mutation holds a `mkdir` lock, and the marker is written only after the lock is taken.
  - Install, rollback and uninstall, including `--dry-run`, refuse (exit 6) if the receipt names a different home or bin, or if `current` exists without a receipt.
  - Bin entries that the installer does not own are never replaced.
- **Transaction undo:** the commit phase (version dir, pointers, bin links, receipt) is journaled in a `.trash.*` directory under the lock. A failure, or HUP/INT/TERM, before the receipt is written replays the journal and restores the pointers, receipt and links byte for byte. The receipt write is the commit point. Garbage collection after it is non-fatal.
- **`--rollback`** swaps `current` and `previous`. **`--uninstall`** removes the receipt-owned links and the marked home only.

## Per-repo ADW wrapper (`scripts/adw-component.sh`)

`adw-component.sh <atlas|beacon|missions|roots> [options] <task>` runs `adw.sh` in exactly one verified sibling repo, `luuna-<component>`. The repo must be the top of its own work tree, must not be a submodule, and its origin must be `github.com/brodynelly/luuna-<component>`. It is never the hub and never under `sources/`.

- **The TAC plugin is required.** `claude plugin list` must show `tac-final`, otherwise the wrapper exits 2. It never installs plugins.
- **Bounds:** the wrapper owns `TAC_CLAUDE_ARGS`, with bounded `--max-turns`. Push, commit, tag, `gh`, publish, `curl` and `wget` are disallowed.
- **Refused:** `--pr`, `--issue` and `-w sdlc`.
- It runs in a worktree by default.

See [RELEASING.md](RELEASING.md#agent-orchestration) for details.

## Owner release gates

Building, signing, notarization, attestation, tags, GitHub Releases, manifests, `INDEX.tsv` entries and npm publication are all manual owner gates ([RELEASING.md](RELEASING.md)). Agents and CI never do them, and never invent manifests or checksums.

## How to test

Run from the repo root. The full TAC validation list is in `AGENTS.md`.

```sh
sh tests/run.sh                 # each test file runs in an env -i sandbox; never touches the real $HOME
TEST_SHELL=dash dash tests/run.sh
sh tests/check-manifests.sh
test -z "$(git status --porcelain sources)"
```

`tests/README.md` describes the fixtures, fault-injection shims, FIFO race barriers, and what the tests do not prove.

## Validation limits (as of this change)

- **Hub tests:** 154 cases passed under `sh` and `dash`. They use stub binaries and local archives, with no network.
- **Real integration:** run on **macOS arm64 only**. All four real native binaries were built, installed into a sandbox, exercised and uninstalled, and project stores were preserved. macOS amd64, Linux amd64/arm64 and GNU tar still need CI or the owner's clean-machine gate.
- **Not available:** no published manifests, GitHub Releases or npm packages exist. `gh` is unauthenticated; Git transport can use SSH. Platform CI is a separate verification gate.
- **Atlas:** full `verify` passed with a checksum-verified, repo-local Go 1.27.0 SDK and Bun 1.4.3. A test-only canonical-path fix resolved the default macOS `TMPDIR` mismatch; no product semantics or version pins changed.
- **ADW wrapper:** tested only with a fake `claude` and a fake `adw.sh`. A real run needs the TAC plugin.

## Known limits (not a full sandbox, not fully atomic)

- **Residual POSIX races:** `mv` has no no-replace rename. Every check-then-rename or check-then-unlink on a bin entry leaves a narrowed but open window in which a foreign entry created at that instant can be replaced or removed. This applies to `link_bin` relink, undo's link restore and removal, stale-link removal, and uninstall.
- **Double fault:** if the undo itself fails, the journal (`.trash.*`, including any `old-version`) and the marker are retained. Install and `--rollback` may then refuse. Recovery is manual: inspect the retained directory and move `old-version` back to `versions/<v>`. Do not run `--uninstall` first, because it deletes the journal. A later locked run with valid pointers sweeps the journal without notice.
- **Out of scope:** the installer is not a privilege sandbox, and it does not cover signing, notarization, or Windows.
