# Releasing the Luuna suite (owner gates)

**No suite release has been published.** Releases, tags, signing, attestations and registry publication are deliberate owner actions. Agents and CI in this repository never perform them.

## Owner gate checklist

Do these in order. Each step is a human decision.

1. **Build artifacts (component owners).** In each component repo (`luuna-atlas`, `luuna-beacon`, `luuna-missions`, `luuna-roots`):
   - Run `release.yml` via `workflow_dispatch` with the component version.
   - Download the workflow artifacts: archives, `SHA256SUMS` and `provenance.json`.
   - Runners: `macos-14` (darwin/arm64), `macos-15-intel` (darwin/amd64), `ubuntu-latest` (linux/amd64), `ubuntu-24.04-arm` (linux/arm64).
2. **Verify locally** on each claimed platform:
   - `sha256sum -c SHA256SUMS` (or `shasum -a 256 -c`)
   - `scripts/release/check-archive.sh <archive>`
   - Review `provenance.json`. It is self-reported metadata, not an attestation.
3. *(Owner)* **Decide on signing, notarization and attestations.**
   - Apple Developer ID notarization for the darwin binaries.
   - GitHub `attest-build-provenance`, which needs `id-token: write` and `attestations: write`.
   - These steps are commented out in the component workflows until the owner enables them.
4. *(Owner)* **Create the tag and the GitHub Release** in each component repo, and upload the verified assets.
5. **Add the suite manifest** through a reviewed PR to this repository:
   - Write `releases/<v>/manifest.tsv` per [releases/FORMAT.md](../releases/FORMAT.md). Copy the URLs and SHA256s from the released assets; never retype or invent them.
   - Append `<v><TAB><sha256 of manifest.tsv>` to `releases/INDEX.tsv`.
   - Relax the "no 64-hex strings under releases/" check in `tests/test-docs.sh` in the same PR.
   - CI must pass, including `sh tests/check-manifests.sh --base origin/main`.
6. *(Owner, networked)* **Clean-machine install** on macOS arm64, macOS amd64, Linux amd64 and Linux arm64. From a checkout of this repository at the merged commit, run:

   ```sh
   sh scripts/install.sh --version <v>
   luuna-suite doctor
   lat --help
   sh scripts/install.sh --uninstall
   ```

7. **Only then** update the README with the verified install command.
8. **npm** (`@luuna-ai-os/*`) is a separate, later decision. It follows [PACKAGING.md](PACKAGING.md). The packages are not published, and the npm scope is unclaimed.

## Agent orchestration

`scripts/adw-component.sh` runs the tac-final ADW (`adw.sh`) for one component repository at a time:

```sh
scripts/adw-component.sh atlas "add a --json flag to lat status"
scripts/adw-component.sh roots --spec specs/chore-native-release.md --dry-run
LUUNA_ADW_ALLOWED_TOOLS='Bash(go test *);Bash(make verify)' scripts/adw-component.sh beacon -w plan_build "task"
```

What it enforces:

- **Exactly one verified sibling repo.** The repo must be `${LUUNA_COMPONENTS_ROOT:-<hub parent>}/luuna-<component>`, resolved with `pwd -P`. It must be the top of its own git work tree and not a submodule. Its `origin` must be `github.com/brodynelly/luuna-<component>`. It is never the hub and never under `sources/`.
- **The plugin fails closed.** `claude plugin list` must show `tac-final`. Otherwise the wrapper exits 2 with install guidance. It never installs plugins.
- **Bounds.** The wrapper owns `TAC_CLAUDE_ARGS` and refuses any caller-set value. It always passes:
  - `--permission-mode acceptEdits`
  - `--max-turns ${LUUNA_ADW_MAX_TURNS:-40}` (1–200)
  - `--disallowedTools` for `git push`, `git commit`, `git tag`, `gh`, `npm publish`, `cargo publish`, `curl` and `wget`
  - optional `LUUNA_ADW_ALLOWED_TOOLS` rules for the repo's validation commands, restricted to a metacharacter-free charset
- **Refused options:** `--pr`, `--issue` (pulls remote content), `-w sdlc`, `--base` with `--no-worktree`, and any unknown option.
- **Worktree by default.** `--worktree` is the default, so your checkout is untouched. `--no-worktree` requires a clean tree. `--dry-run` passes through to `adw.sh`.

Upstream `adw.sh` `eval`s `CLAUDE_BIN` and `TAC_CLAUDE_ARGS`, so every value reaching them is charset-validated. Task text is passed as a plain argument.

Notes:

- `adw.sh` writes `.tac/runs/` and `.tac/kpis.md` in the component repo.
- Review, commit and merge stay human.
- The turn bound and tool denials rely on Claude Code honoring `--max-turns` and `--disallowedTools`. The hub tests use a fake `claude` and a fake `adw.sh`.

## What the hub tests do not prove

See [tests/README.md](../tests/README.md#what-the-tests-do-not-prove).
