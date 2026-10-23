# Distribution plan

## The boundary

This repository is the suite entry point, not a source-code monorepo. Luuna and each component keep their own releases.

The public CLI cores are native:

- Go: Atlas, Beacon, Missions
- Rust: Roots

The desktop applications need native packaging of their own. The private Luuna runtime is a separate delivery surface. It is never part of the public install.

## Native releases first

1. **Component builds.** Each component repo owns `scripts/release/package.sh`, `scripts/release/check-archive.sh` and a `workflow_dispatch`-only `release.yml`.
   - The workflow builds `luuna-<component>_<version>_<os>_<arch>.tar.gz` archives for darwin/linux × arm64/amd64, along with `SHA256SUMS` and `provenance.json`.
   - It uploads them only as workflow artifacts. Nothing is published.
2. **Suite manifest.** A release is one immutable `releases/<v>/manifest.tsv` in this repository ([FORMAT.md](../releases/FORMAT.md)), indexed by hash in `releases/INDEX.tsv`.
3. **Installer.** `scripts/install.sh` is POSIX `sh` for macOS and Linux. It needs only `tar`, `gzip`, `sha256sum`/`shasum`, and `curl` or `wget`.
   - Unsupported platforms exit 3. The installer does not support Windows.
4. **Owner gates.** Tags, GitHub Releases, signing, notarization and attestations are listed in [RELEASING.md](RELEASING.md). None of them has happened yet.

### Install layout (per user, no sudo)

```text
${LUUNA_SUITE_HOME:-${XDG_DATA_HOME:-~/.local/share}/luuna-suite}/
  .luuna-suite-home       ownership marker (required before anything is removed)
  versions/<v>/bin/...    verified executables plus the luuna-suite dispatcher
  current, previous       one-line pointer files naming a version (regular files, replaced by rename)
  receipt.tsv             roots, current/previous, owned links, component rows
${LUUNA_SUITE_BIN:-~/.local/bin}/<name> -> .../versions/<v>/bin/<name>
```

- Upgrades keep exactly one `previous`. `--rollback` swaps the two versions.
- `--uninstall` removes only receipt-listed links that still point into the suite home, then the suite home itself.
- Project stores (`<repo>/.luuna/**`, `~/.luuna`) are never enumerated or touched.
- The installer refuses to replace any bin entry it does not own.

### Command names and the private runtime

| Component | Primary | Public alias | Not shipped publicly |
| --- | --- | --- | --- |
| Atlas | `luuna-atlas` | `lat` | `la` |
| Beacon | `luuna-beacon` | `lbc` | `lb` |
| Missions | `luuna-missions` | `lms` | `lm`, `missions` |
| Roots | `luuna-roots` | `lrt` | — |
| Dispatcher | `luuna-suite` | — | `luuna`, `lu` |

`luuna-suite <atlas|beacon|missions|roots> [args]` runs the sibling executable from the same installed version. `luuna-suite doctor` reports, read-only, where every public name resolves on `PATH`, and whether `luuna` resolves outside the suite. `luuna` and `lu` belong to the private Luuna runtime: the public installer and dispatcher never install, link or shadow them.

## Windows

Windows is not supported by the public installer in this phase, and no Windows archives are built.

`scripts/install-cli.ps1` is the *private developer source install*:

- It needs Bun 1.4.3 and access to the private Luuna repository.
- It uses the pinned Luuna checkout's installer.
- It also installs the private runtime's `luuna`/`lu`.

Windows `.zip` assets and a PowerShell installer are a follow-up, once the POSIX path is proven on real releases.

## npm (deferred, optional)

The `@luuna-ai-os/*` npm packages are not published, and the npm scope `luuna-ai-os` is unclaimed. Do not advertise any npm install command until packages are published and an end-to-end install is verified. If the owner pursues npm later:

1. Confirm control of the npm organization or user scope `luuna-ai-os`. Decide who owns releases, and configure provenance and two-factor publishing. Do not put credentials in this repository.
2. Publish each CLI from its own source repository under `@luuna-ai-os/{atlas,beacon,missions,roots}`. Keep its executable names stable. Verify the package contents, a clean install, and actual CLI behavior on each claimed platform.
3. Publish `@luuna-ai-os/cli` only after the component packages exist. Its executable must be the public dispatcher `luuna-suite`, never the private runtime's `luuna`/`lu`.
4. Keep the Luuna workbench/runtime and the Luuna-AI desktop on their own native release paths. An npm meta-package does not prove that a Tauri or Rust application installs and runs.

The umbrella GitHub repository cannot create or grant an npm scope.
