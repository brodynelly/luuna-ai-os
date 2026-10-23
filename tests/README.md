# Hub tests

```sh
sh tests/run.sh                      # every tests/test-*.sh, each in its own sandbox
sh tests/run.sh tests/test-install.sh
TEST_SHELL=dash dash tests/run.sh    # optional: catch bashisms
sh tests/check-manifests.sh [--base origin/main]
```

## Tools

The tests need only POSIX `sh`, `tar`, `gzip`, `mktemp`, `sha256sum` or `shasum`, `grep`, `sed`, `awk`, `ln`, `mv`, `find`, `cksum`, `readlink`, `dd`, `tr` and `od`.

They do not need network access, Bun, Go, Rust, npm, a real `claude`, or initialized `sources/` submodules. `git` and `bash` are needed for the manifest-immutability and `adw-component` cases, which skip if those tools are missing.

## Isolation

`run.sh` gives each test file a fresh `mktemp -d` sandbox. It points `HOME`, `XDG_DATA_HOME`, `LUUNA_SUITE_HOME`, `LUUNA_SUITE_BIN`, `TMPDIR` and `PATH` into the sandbox, and starts the test with `env -i`. It aborts if the sandbox `HOME` would be the real home.

The installer's platform detection is pinned to `Linux/x86_64` through `LUUNA_SUITE_UNAME_S` and `LUUNA_SUITE_UNAME_M`, and fixtures are generated for that platform.

## Fixtures

`tests/lib.sh` writes ustar archives byte for byte, so tests can build malicious entries with any host tar: traversal, absolute paths, symlinks, hardlinks, devices and duplicate entries. Each stub executable is a tiny `#!/bin/sh` script that echoes its arguments. SHA256s are computed from these generated stubs at test time. No real checksum is ever committed.

Every failure-path case asserts the exit code and that a snapshot of the case's `HOME` (and any victim directory) is byte-identical afterwards. The snapshot records type, mode, link target and checksum.

## Fault injection and concurrency

Commit-phase failures are injected with one-shot PATH shims (`make_shim` in `lib.sh`): a shim for `ln`, `mv`, `cp` or `mkdir` fires once, when its last argument matches a glob, and otherwise execs the real tool, so the installer's own undo steps run unaffected. Only the command under test gets the shim directory on its `PATH`. Concurrency cases use `mkfifo` barriers (`start_paused` / `release_paused`) instead of sleeps, polling or timeouts. They need `mkfifo`; without it the race case is reported as `# SKIP`, never as a pass. The race case proves the ordering at two specific pause points (the loser just before `mkdir .lock`, the winner at its first asset copy), not every interleaving.

## What the tests do not prove

- **Real binaries and real downloads.** The tests prove the installer logic with stub executables and local archives. They do not show that the real Go and Rust binaries run on every platform, or that real network download, TLS, redirects and GitHub release URLs behave correctly. The fetch path is exercised only up to a stubbed `curl`/`wget` failing.
- **GNU tar.** It is exercised only when CI runs on Linux. Local macOS runs use bsdtar.
- **Gatekeeper, signing and notarization.** These are not covered.
- **`adw-component.sh` against a real run.** Its tests use a fake `claude` and a fake `adw.sh`. A real run depends on Claude Code honoring `--max-turns` and `--disallowedTools`.
- **Windows.** Nothing here validates Windows. The PowerShell script is untested and unchanged.
