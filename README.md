# Luuna AI OS

The distribution and architecture hub for the Luuna suite. Each component remains an independent repository with its own history, license, release, and CLI. This repository pins the existing apps and tools as Git submodules under `sources/` and provides a source installation path; it does not claim that unpublished npm packages can be installed.

| Product | Responsibility | Repository | Current delivery |
| --- | --- | --- | --- |
| Luuna | Supervised runtime, approvals, scope, checks, review, and workbench | [luuna](https://github.com/brodynelly/luuna) | Private source and Windows development installer |
| Atlas | Verified expertise and project memory | [luuna-atlas](https://github.com/brodynelly/luuna-atlas) | Public source; `lat` / `luuna atlas` |
| Beacon | Versioned prompts and composition | [luuna-beacon](https://github.com/brodynelly/luuna-beacon) | Public source; `lbc` / `luuna beacon` |
| Missions | Tickets, dependencies, and plans | [luuna-missions](https://github.com/brodynelly/luuna-missions) | Public source; `lms` / `luuna missions` |
| Roots | Human-owned project intent and goal graph | [luuna-roots](https://github.com/brodynelly/luuna-roots) | Public source fork; `luuna-roots` / `lrt` |
| Luuna-AI | Separate Pi desktop client | [luuna-ai](https://github.com/brodynelly/luuna-ai) | Source build; not an npm CLI |
| Documentation | Published product documentation source | [luuna-documentation](https://github.com/brodynelly/luuna-documentation) | Documentation site |

## Install the CLIs from source on Windows

With Git, Bun **1.4.3**, and access to the private Luuna repository:

```powershell
git clone https://github.com/brodynelly/luuna-ai-os.git
cd luuna-ai-os
.\scripts\install-cli.ps1
```

The script initializes missing pinned CLI submodules, refuses divergent or dirty component checkouts, and calls Luuna's maintained [CLI installer](https://github.com/brodynelly/luuna/blob/main/docs/CLI-INSTALL.md). It installs `luuna`/`lu`, `lat`, `lbc`, `lms`, and `luuna-roots`/`lrt` launchers. It does not install the desktop applications, initialize project stores, or publish packages. A new terminal picks up the PATH change. To get all seven source repositories without installing CLIs, use `git submodule update --init`.

## Package plan

The proposed public CLI package names are `@luuna-ai-os/atlas`, `@luuna-ai-os/beacon`, `@luuna-ai-os/missions`, `@luuna-ai-os/roots`, and a dispatcher package `@luuna-ai-os/cli`. The intended one-command CLI install is **`npm install -g @luuna-ai-os/cli`**, after that package actually exists. These names are **not reserved or published**. The npm account or organization named `luuna-ai-os` must be controlled before any of them can be published. A GitHub repository name does not confer npm scope ownership. See [PACKAGING.md](docs/PACKAGING.md) for release gates and the distinction between CLIs and native applications.

## Luuna Roots

[Luuna Roots](https://github.com/brodynelly/luuna-roots) is an optional intent layer adapted from [jayminwest/roots](https://github.com/jayminwest/roots) with the original MIT attribution and history preserved. Human-authored goals and accepted relationships can explain *why* a Missions ticket exists. The fork reads `.luuna/missions/` and `.luuna/atlas/` and is pinned in this suite. Its source CLI is included in the Windows installer; runtime integration and native Windows behavior still need qualification. See [INTENT.md](docs/INTENT.md).
