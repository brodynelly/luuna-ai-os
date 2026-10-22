# Distribution plan

## The boundary

This repository is the suite entry point, not a source-code monorepo. Luuna and each component retain their own releases. The desktop applications require native packaging; `npm install -g` is intended for command-line tools only.

## Current installation

`scripts/install-cli.ps1` uses the private Luuna checkout's maintained installer and the three public component source checkouts. Its current command names are `luuna`/`lu`, `lat`, `lbc`, and `lms`. The component repositories currently mark their packages private and use Bun TypeScript entry points. They are not npm releases. The Luuna runtime is separate from the standalone component CLIs.

## npm release sequence

1. Confirm control of the npm organization or user scope `luuna-ai-os`; decide who owns releases and configure provenance and two-factor publishing. Do not put credentials in this repository.
2. Publish each CLI from its own source repository under `@luuna-ai-os/{atlas,beacon,missions}`. Remove `private: true` only as part of a reviewed release. Keep its executable names stable. Verify the package contents, Bun runtime requirement, clean install, and actual CLI behavior on each claimed platform.
3. Publish `@luuna-ai-os/cli` only after the three packages exist. It can depend on the component packages and expose the `luuna` dispatcher; its behavior and executable ownership must be reconciled with Luuna's current private workbench before publication.
4. Provide a separate native installer or release artifact for the Luuna workbench/runtime and Luuna-AI desktop. An npm meta-package does not prove a Tauri or Rust application installs and runs.
5. Pin the released component versions in Luuna's manifest and validate its submodule commits separately. The public CLI release and Luuna's governed runtime are different delivery surfaces.

Do not advertise `npm install -g @luuna-ai-os/...` until packages are actually published and an end-to-end install is verified. The umbrella GitHub repository cannot create or grant an npm scope.
