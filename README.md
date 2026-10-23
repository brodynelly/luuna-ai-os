# Luuna AI OS

The distribution and architecture hub for the Luuna suite.

- Each component remains an independent repository with its own history, license, release and CLI.
- This repository pins the existing apps and tools as Git submodules under `sources/`.
- It provides a native installer, an immutable release-manifest format, and the public `luuna-suite` dispatcher.
- It does not claim that any unpublished release or package can be installed.

| Product | Responsibility | Repository | Current delivery |
| --- | --- | --- | --- |
| Luuna | Supervised runtime, approvals, scope, checks, review, and workbench | [luuna](https://github.com/brodynelly/luuna) | Private source and Windows development installer; not part of the public install |
| Atlas | Verified expertise and project memory | [luuna-atlas](https://github.com/brodynelly/luuna-atlas) | Public source (Go core); `luuna-atlas` / `lat` |
| Beacon | Versioned prompts and composition | [luuna-beacon](https://github.com/brodynelly/luuna-beacon) | Public source (Go core); `luuna-beacon` / `lbc` |
| Missions | Tickets, dependencies, and plans | [luuna-missions](https://github.com/brodynelly/luuna-missions) | Public source (Go core); `luuna-missions` / `lms` |
| Roots | Human-owned project intent and goal graph | [luuna-roots](https://github.com/brodynelly/luuna-roots) | Public source fork (Rust); `luuna-roots` / `lrt` |
| Luuna-AI | Separate Pi desktop client | [luuna-ai](https://github.com/brodynelly/luuna-ai) | Source build; not part of the public CLI install |
| Documentation | Published product documentation source | [luuna-documentation](https://github.com/brodynelly/luuna-documentation) | Documentation site |

## Install status

**No suite release has been published yet.** There is no working public install command today.

- **Public native install: macOS and Linux (x86_64, arm64).** [`scripts/install.sh`](scripts/install.sh) is a per-user POSIX installer and needs no sudo. Each release is described by a checksummed manifest in [`releases/`](releases/README.md). The installer:
  - verifies every archive's SHA256
  - rejects unsafe archive entries
  - stages all components before switching versions
  - supports `--rollback`, `--uninstall` and `--dry-run`

  It installs only `luuna-suite`, `luuna-atlas`/`lat`, `luuna-beacon`/`lbc`, `luuna-missions`/`lms` and `luuna-roots`/`lrt`, into `~/.local/share/luuna-suite` with links in `~/.local/bin`. It never installs `luuna` or `lu`, and never touches project stores (`.luuna/`). Once a release exists, you will run it from a checkout against that release (`sh scripts/install.sh --version <v>`). Until then, `releases/INDEX.tsv` is empty and that command fails clearly.
- **Windows: not supported by the public installer.** No Windows native archives exist. [`scripts/install-cli.ps1`](scripts/install-cli.ps1) is a private developer source install. It requires access to the private Luuna repository and Bun 1.4.3, and it also installs the private runtime's `luuna`/`lu`.
- The private Luuna runtime and the Luuna-AI desktop app are outside the public install path.

Release gates are listed in [docs/RELEASING.md](docs/RELEASING.md) and the distribution design in [docs/PACKAGING.md](docs/PACKAGING.md). To get all seven source repositories without installing anything, use `git submodule update --init`.

## Package plan

npm is a deferred, optional channel. The proposed names are:

- `@luuna-ai-os/atlas`, `@luuna-ai-os/beacon`, `@luuna-ai-os/missions` and `@luuna-ai-os/roots`
- a dispatcher package, `@luuna-ai-os/cli`

These names are not reserved and not published, so `npm install -g @luuna-ai-os/cli` does not work today. The npm scope `luuna-ai-os` is unclaimed, and owning a GitHub repository name does not confer it. See [PACKAGING.md](docs/PACKAGING.md).

## Luuna Roots

[Luuna Roots](https://github.com/brodynelly/luuna-roots) is an optional intent layer adapted from [jayminwest/roots](https://github.com/jayminwest/roots). The original MIT attribution and history are preserved.

- Human-authored goals and accepted relationships can explain *why* a Missions ticket exists.
- The fork reads `.luuna/missions/` and `.luuna/atlas/` and is pinned in this suite.
- Runtime integration still needs qualification.

See [INTENT.md](docs/INTENT.md).
