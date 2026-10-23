# Agent instructions: luuna-ai-os (suite hub)

This repository is the distribution and architecture hub for the Luuna suite. It contains:

- pinned component submodules under `sources/`
- the POSIX native installer and the release-manifest format
- the public `luuna-suite` dispatcher
- the per-component ADW orchestration entrypoint

## Hard boundaries

- Edit only files inside this repository. Treat sibling repos (`../luuna-*`), `../.agents/`, and `sources/*` as read-only.
- Do not run `git submodule update`. Do not initialize, change or bump `sources/*` pins (`git status --porcelain sources` must stay empty).
- Do not commit, push, tag, publish, create releases or PRs, or change repository visibility. These are owner actions; see `docs/RELEASING.md`.
- Never invent release manifests or checksums. `releases/INDEX.tsv` stays header-only until the owner gate adds a real release.
- The public installer and dispatcher never install, link, or overwrite `luuna` or `lu`. Those names belong to the private runtime.
- Tests must not use the network, Bun, Go, Rust, npm, or a real `claude`. They run in throwaway sandboxes, never against the real `$HOME`.

## Layout

| Path | Purpose |
| --- | --- |
| `scripts/install.sh` | Native installer (install, upgrade, `--rollback`, `--uninstall`, `--dry-run`) |
| `scripts/lib/manifest.sh` | Shared manifest parse and validation |
| `scripts/luuna-suite` | Public dispatcher |
| `scripts/adw-component.sh` | Runs `adw.sh` in exactly one verified sibling component repo |
| `scripts/install-cli.ps1` | Private developer source install (Windows); not the public installer |
| `releases/` | Immutable manifests (`FORMAT.md`, header-only `INDEX.tsv`) |
| `tests/` | Dependency-free POSIX test suite (`tests/README.md`) |

## Conditional docs

- Read `docs/NATIVE-DISTRIBUTION.md` when you touch the installer, dispatcher, manifests, or ADW wrapper. It covers the public/private split, the transaction model, validation limits, and known race and recovery limits.
- Read `docs/RELEASING.md` for owner release gates.

## TAC validation commands

Run all of these from the repository root. All must pass.

```sh
sh tests/run.sh
sh tests/check-manifests.sh
sh -n scripts/install.sh && sh -n scripts/luuna-suite && sh -n scripts/lib/manifest.sh && sh -n scripts/adw-component.sh && for f in tests/*.sh; do sh -n "$f" || exit 1; done
sh scripts/install.sh --help >/dev/null && { sh scripts/install.sh --version 0.0.0; test $? -ne 0; }
test -z "$(git status --porcelain sources)"
```

These two are optional:

- `shellcheck -s sh scripts/install.sh scripts/luuna-suite scripts/lib/manifest.sh scripts/adw-component.sh tests/*.sh`, if shellcheck is installed.
- `dash tests/run.sh`, if dash is installed. It catches bashisms.

## Conventions

- Shell is POSIX `sh` with `set -eu`. Do not use bashisms: no `[[`, arrays, `local`, `pipefail` or `readlink -f`.
- Quote every expansion. Never `eval` data from manifests, receipts, or the environment.
- Every failure path in `tests/` asserts the exit code **and** that the filesystem is unchanged.
