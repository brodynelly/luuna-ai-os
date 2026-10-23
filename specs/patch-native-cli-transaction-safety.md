# Patch: Native CLI installer transaction safety

## Summary

Review-1 (`.tac/runs/9f32a7c1/review-1.log`) passed `scripts/install.sh` but recorded three findings as `tech_debt`. The installer's acceptance criteria require transactional behavior, so all three must be fixed before the feature is complete:

1. **The marker is written before the lock is taken.** Two first installs can race. The one that loses the lock (exit 8) deletes the `.luuna-suite-home` marker that the winner wrote or relies on, because it set `CREATED_MARKER=1` before calling `acquire_lock`. After that, installs and uninstalls refuse with exit 6 until someone cleans up by hand.
2. **Only uninstall checks that the receipt's roots match the configured roots.** Install and rollback do not check `receipt.tsv`'s `home`/`bin` against the resolved `LUUNA_SUITE_HOME`/`LUUNA_SUITE_BIN`. Changing `LUUNA_SUITE_BIN` between runs leaves owned links in the old bin directory, and uninstall can never remove them.
3. **Nothing undoes a failure after staging.** In install, `COMMITTED=1` is set once the stage is moved into `versions/<v>`. In rollback, nothing is set at all. If `write_pointer`, `relink` or `write_receipt` fails after that, the pointers, bin links and receipt can be left half-updated. There is also a smaller bug: a failure between `mv "$dest" "$trash/old"` and `mv "$STAGE" "$dest"` deletes the previous copy of a reinstalled version, even if `previous` still names it.

This is the smallest safe fix. There is no architecture redesign: the layout, receipt format, pointer files, exit codes and CLI stay the same. The fix reorders the first-install steps, adds one shared receipt-roots check, and adds a small undo journal that `cleanup()` replays when a run fails after its first visible mutation.

## Problem statement / current behavior (from `scripts/install.sh`)

| Finding | Location | Current behavior |
| --- | --- | --- |
| 1 | lines 464-469, 135, 172-176 | `mkdir_tracked "$H"`, then `printf … > "$H/$MARKER_NAME"` and `CREATED_MARKER=1`, then `acquire_lock`. `cleanup` removes the marker whenever `rc≠0 && COMMITTED=0 && CREATED_MARKER=1`, including when this process never held the lock. `mkdir_tracked` uses a plain `mkdir`, so a concurrent creator of the same directory makes it fail. |
| 2 | lines 393-410 (rollback), 438-449 (install preflight), 469-473 (install under lock) | `receipt_field home/bin` is compared only in `do_uninstall` (lines 362-364). |
| 3 | lines 518-536 (install), 403-407 (rollback) | Swap order: move `dest` to trash, move the stage to `dest`, set `COMMITTED=1`, write `previous`, write `current`, `relink`, write the receipt, run `gc_versions`. Any `die` or signal in between exits with no undo. `cleanup` skips marker and directory cleanup because `COMMITTED=1`. Rollback has no commit tracking. `old_cur`/`old_prev` are read before the lock and never re-read under it. |

## Design (minimal)

### D1 — Lock before marker; only the lock owner may remove the marker
- Create `$H` with `mkdir_tracked`, made race-tolerant: `mkdir "$_d" 2>/dev/null || [ -d "$_d" ] || die 6 …`. A directory goes into `CREATED_DIRS` only if this process's `mkdir` succeeded.
- Call `acquire_lock` **before** any marker write.
- Under the lock, re-check ownership:
  - If `marker_ok` passes, continue.
  - Otherwise `$H` must contain nothing except `.lock`. If it does, exit 6 with the existing "exists, is not empty, and has no Luuna suite marker" message. Then write the marker and set `CREATED_MARKER=1`.
- `CREATED_MARKER=1` can therefore be set only while `LOCKED=1`. `cleanup` removes the marker only when `LOCKED=1 && CREATED_MARKER=1`, the run failed, and the transaction did not commit (D3), or it committed and then fully undid itself. It removes the marker before it releases the lock, as today.
- A process that loses the lock exits 8 and has written nothing in `$H` except directories it created itself. `cleanup` only `rmdir`s those, and `rmdir` fails harmlessly when another run has populated them.
- Keep the existing read-only, pre-lock preflight (lines 438-449) so `--dry-run` and early refusals still happen without writes. The checks under the lock are the authoritative ones.

### D2 — One receipt-roots check for install, rollback and uninstall
Add `check_receipt_roots`. It replaces the inline uninstall checks at lines 361-364, and the uninstall messages stay the same:
- If `$H/receipt.tsv` is absent:
  - Pass if `$H/current` is also absent (fresh or pre-commit home).
  - Otherwise exit 6: "refusing: $H has a current version but no receipt.tsv".
- If present, it must be a regular file, not a symlink, with header `luuna-suite-receipt<TAB>1`.
- `receipt_field home` must equal `$H`, otherwise exit 6.
- `receipt_field bin` must equal `$B`, otherwise exit 6 with "receipt was written for LUUNA_SUITE_BIN=…; rerun with that value (or uninstall with it first)".

Call it:
- in install preflight when `marker_ok` passes, so `--dry-run` refuses too, and again under the lock
- in `do_rollback` before the dry-run branch, and again under the lock
- in `do_uninstall`, where it already runs before `--dry-run`, at the same place as the current inline checks

Uninstall keeps requiring a receipt (its existing "has no receipt.tsv" refusal stays ahead of the helper).

### D3 — Undo journal for the commit phase (install and rollback)
Add three helpers: `txn_begin`, `txn_undo` and `txn_done`. A global `TXN` holds `none`, `active` or `done`. `TXN_DIR` is a `mktemp -d "$H/.trash.XXXXXX"` directory, and the existing `.trash.*` sweep in `cleanup` removes it.

**`txn_begin`** runs under the lock, after the pointers have been **re-read under the lock**, and before the first visible mutation. It records:
- `current`, `previous` and `receipt.tsv`: copy each one that exists, as a regular file, with `cp -p "$H/$f" "$TXN_DIR/$f"`. For each one that is absent, `touch "$TXN_DIR/$f.absent"`.
- Bin link state for every name in `$PUBLIC_NAMES`, in `"$TXN_DIR/links.tsv"`:
  - `name<TAB>absent` when `bin_state` is 0
  - `name<TAB>owned<TAB><readlink target>` when it is 1
  - nothing when it is 2: preflight guarantees those entries are never touched
- `VERSIONS_CREATED=1` if this run is about to create `$H/versions`.
- `NEW_DEST` (install only): the `versions/<v>` path that is about to be placed. An existing `dest` is moved to `"$TXN_DIR/old-version"`, not to a separate trash directory.

`txn_begin` sets `TXN=active` only after all of these are written. A failure inside `txn_begin` is still a pre-mutation failure.

**Install order:**
1. `txn_begin`
2. `mkdir versions` if needed
3. move the existing `dest` to `$TXN_DIR/old-version`
4. move the stage to `dest`, then set `STAGE=""`
5. write `previous`
6. write `current`
7. `relink`
8. `write_receipt`
9. `txn_done` (sets `TXN=done`). The receipt is the commit point.
10. `gc_versions`, made non-fatal after the commit: `|| say "warning: …"`. The committed state is consistent, so a GC failure must not trigger undo or a misleading nonzero exit.

Remove `COMMITTED`. `cleanup` uses `TXN` instead.

**Rollback order:** `acquire_lock`, re-validate under the lock (marker, `check_home_entries`, `check_receipt_roots`, re-read both pointers and re-run `preflight_bins`), `txn_begin`, write the pointers, `relink`, `write_receipt`, `txn_done`.

**`txn_undo`** runs from `cleanup` when `rc≠0 && TXN=active && LOCKED=1`. It must be **non-fatal per step**. `cleanup` runs under `set -e`, so every step is written as `cmd || UNDO_FAILED=1`, and it never calls `die`, `link_bin` or `write_pointer`, which call `die`. Steps:
1. **Links.** For each `links.tsv` row:
   - Originally `absent`, now owned: `rm -f`.
   - Originally `owned→T`, now absent or owned with a different target: recreate the link with `ln -s T "$B/.luuna-suite.tmp.$$.undo.<name>"`, then `mv -f` over the link.
   - Now state 2 (a foreign entry appeared during the run): leave it untouched and print "left $B/<name> in place: not owned by this install". This is a warning, not an undo failure.
2. **Pointers and receipt.** For each of `current`, `previous` and `receipt.tsv`:
   - If a backup exists and the destination is absent or a regular non-symlink file, `mv -f` the backup back.
   - If it was originally absent and the destination is now a regular file, `rm -f` it.
   - Otherwise set `UNDO_FAILED=1`.
3. **Version directory (install).**
   - If `NEW_DEST` is a real directory, move it to `"$TXN_DIR/new-version"`.
   - Then, if `"$TXN_DIR/old-version"` exists, move it back to `NEW_DEST`.
   - If `VERSIONS_CREATED=1`, `rmdir "$H/versions"`, which fails harmlessly if it is non-empty.
4. **Result.** If `UNDO_FAILED` is unset, set `UNDONE=1` and print "restored the previous installation". Otherwise print "could not fully restore the previous installation; rerun install or --rollback" and keep the marker.

**`cleanup` order:**
1. Remove `STAGE`.
2. `txn_undo` if needed.
3. If `LOCKED=1`, sweep `.tmp.*` and `.trash.*`.
4. If `LOCKED=1 && CREATED_MARKER=1 && rc≠0 && (TXN≠done) && (TXN=none || UNDONE=1)`, remove the marker.
5. Release the lock.
6. `rmdir` the created directories under the same failure condition as step 4.
7. Exit with the **original** `rc`. Signals (129/130/143) take the same path. No new exit codes.

**Known residual (document, don't fix).** `link_bin`'s check-then-`mv -f` has a TOCTOU window: POSIX `mv` has no no-replace rename. Narrow it by re-running `bin_state` right after `ln -s` of the temp link and before `mv -f`, failing with exit 6 on state 2. Record the remaining window in the `install.sh` header comment.

## Relevant Files

- `scripts/install.sh`: all logic changes (D1-D3) and an updated header safety-model comment.
- `tests/lib.sh`: new helpers: `make_shim`, `start_paused`, `release_paused` and `real_tool`.
- `tests/test-install.sh`: first-install race tests, receipt-roots tests and an install fault-injection test.
- `tests/test-upgrade-rollback.sh`: upgrade and rollback fault-injection tests and a rollback receipt-roots test.
- `tests/test-uninstall.sh`: no behavior change expected. The existing `t_uninstall_*` cases must keep passing unchanged after the refactor to `check_receipt_roots`.
- `tests/README.md`: one paragraph on shims and FIFO barriers.
- Do **not** edit other specs (`specs/feature-native-cli-distribution.md` and the rest stay as they are), `sources/*`, `.tac/`, sibling repos or `releases/`.

## Step by Step Tasks

### 1. Test helpers (`tests/lib.sh`)
1. `real_tool NAME` prints `command -v NAME` resolved with the case's PATH before any shim directory is prepended. It must be an absolute path, otherwise `fail`.
2. `make_shim DIR NAME BODY`: writes an executable `#!/bin/sh` script `DIR/NAME`. The body runs with `REAL` set to the real tool's absolute path, passed in the environment and not interpolated into code. Shims are **one-shot**:
   - A shim fires only if `"$CASE_DIR/fault.<NAME>.fired"` is absent and its argument predicate matches.
   - When it fires, it creates that file first.
   - Otherwise it runs `exec "$REAL" "$@"`.

   One-shot shims keep undo steps that call the same tool unaffected.
3. `start_paused TAG CMD...` runs CMD in the background through a wrapper subshell that records `"$CASE_DIR/$TAG.rc"`. Barrier protocol, with no sleeps or timeouts:
   - `mkfifo "$CASE_DIR/$TAG.ready" "$CASE_DIR/$TAG.go"`.
   - The pausing shim runs `echo ready > "$CASE_DIR/$TAG.ready"; read -r _ < "$CASE_DIR/$TAG.go"`, then execs the real tool.
   - If CMD exits without the shim having fired, the wrapper writes `exit` to `.ready`, so the test never blocks forever.
   - The test runs `read -r line < "$CASE_DIR/$TAG.ready"` and fails the case unless `line = ready`. It saves the background PID.
4. `release_paused TAG` runs `echo go > "$CASE_DIR/$TAG.go"`, then `wait` on the saved PID, then sets `RC` from `$TAG.rc`.
5. Every helper is POSIX: no `local`, arrays or `[[`. Quote everything. Each shim directory lives under `$CASE_DIR`, and only the process under test gets it prepended to PATH, through an env prefix on that one command.

### 2. D1: lock before marker (`scripts/install.sh`)
1. Make `mkdir_tracked` race-tolerant and record only directories it actually created.
2. Reorder the install write phase: `mkdir_tracked "$H"`, then `acquire_lock`, then the ownership re-check under the lock (marker, or only `.lock` present), then the marker write with `CREATED_MARKER=1`, then the existing temp sweep, `check_home_entries` and `preflight_bins`.
3. Gate the marker removal in `cleanup` on `LOCKED=1` as well (D3 adds the final condition).

### 3. D2: receipt roots (`scripts/install.sh`)
1. Add `check_receipt_roots` per D2. Replace the inline checks at lines 361-364 with it, keeping uninstall's messages, including "rerun with", which `t_uninstall_wrong_bin` asserts.
2. Call it in the install preflight (when `marker_ok`) and under the lock, and in `do_rollback` before the dry-run branch and under the lock.

### 4. D3: undo journal (`scripts/install.sh`)
1. Add `TXN`, `TXN_DIR`, `NEW_DEST`, `VERSIONS_CREATED`, `UNDONE` and `UNDO_FAILED` to the globals, and remove `COMMITTED`.
2. Implement `txn_begin`, `txn_done` and `txn_undo` per D3. They must not call `die`-ing helpers from inside `txn_undo`.
3. Under the lock, in install, re-read `old_cur` and `old_prev`. If `old_cur` now equals `suite_v`, print the "already the current version" message and exit 0. Then follow the install order in D3, and make `gc_versions` non-fatal after `txn_done`.
4. Make the rollback changes from D3: re-validate under the lock, then `txn_begin` … `txn_done`.
5. Reorder `cleanup` per D3, keeping the original exit code.
6. In `link_bin`, re-check `bin_state` after creating the temp link and before `mv -f`. If it is 2, remove the temp link and `die 6`.
7. Update the header safety-model comment: the lock comes before the marker, receipt roots are checked for every mutating mode, the commit is journaled and undone on failure, and the residual rename TOCTOU is noted.

### 5. Regression tests: first-install race (`tests/test-install.sh`)
1. **`t_first_install_race_loser_keeps_marker`** must fail on the current code and pass after the fix. Roots are fresh; there is no `$LUUNA_SUITE_HOME`.
   - Start **B**, the loser, with `start_paused B` and a `mkdir` shim. The shim pauses only when its last argument matches `*/luuna-suite/.lock`; it passes every other `mkdir` through. Wait until B is ready. On the old code, B has already written the marker at this point. On the new code, it has written none.
   - Start **A**, the winner, with `start_paused A` and a one-shot `cp` shim that pauses on the first asset copy. A holds the lock (and, on the new code, the marker it wrote) at that point. Wait until A is ready.
   - `release_paused B`. Assert `RC=8`, output contains "another install", and `$LUUNA_SUITE_HOME/.luuna-suite-home` exists with exactly `luuna-suite-home 1`. Also assert `$LUUNA_SUITE_HOME/.lock` still exists, because A holds it.
   - `release_paused A`. Assert `RC=0`, `current` = the fixture version and `lat` runs the stub.
   - `--uninstall` gives `RC=0` and `$LUUNA_SUITE_HOME` is absent. On the old code this step fails with exit 6, because the marker is gone.
2. **`t_lock_before_marker_no_write`**: a pre-created `$LUUNA_SUITE_HOME/.lock` in an otherwise empty `$LUUNA_SUITE_HOME` without a marker. Take a snapshot, run install, assert `RC=8` and the snapshot is unchanged. In particular, no marker is ever written.
3. The existing `t_lock_held` must still pass unchanged.

### 6. Regression tests: receipt roots
1. In `tests/test-install.sh`, **`t_install_bin_mismatch`**:
   - Install 1.0.0. Then, with `LUUNA_SUITE_BIN="$HOME/other-bin"`, take a `$HOME` snapshot and install 2.0.0.
   - Assert `RC=6`, output contains `LUUNA_SUITE_BIN=` and "rerun with", the snapshot is unchanged, and `$HOME/other-bin` is absent.
   - Repeat with `--dry-run`: `RC=6`, snapshot unchanged.
2. In `tests/test-install.sh`, **`t_install_receipt_home_mismatch`**: rewrite the `home` line in `receipt.tsv` to another absolute path, take a snapshot, install 2.0.0, assert `RC=6` and the snapshot is unchanged.
3. In `tests/test-install.sh`, **`t_install_missing_receipt_with_current`**: delete `receipt.tsv` after a successful install, take a snapshot, install 2.0.0, assert `RC=6` and the snapshot is unchanged.
4. In `tests/test-upgrade-rollback.sh`, **`t_rollback_bin_mismatch`**:
   - Install 1.0.0 and 2.0.0, take a snapshot, then run `LUUNA_SUITE_BIN="$HOME/other-bin" … --rollback`. Assert `RC=6` and the snapshot is unchanged.
   - Repeat with `--rollback --dry-run`: `RC=6`, snapshot unchanged.

### 7. Regression tests: injected commit failure, no changed state
All of these take `take_snapshot home "$HOME"` immediately before the failing run and call `assert_unchanged home "$HOME"` after it. The snapshot covers pointers, receipt, marker, versions, bin links and their targets, and the absence of `.lock`, `.trash.*`, `.tmp.*` and `.stage.*`. The fixture releases live in `$CASE_DIR/rel-*`, outside `$HOME`.

1. In `tests/test-upgrade-rollback.sh`, **`t_upgrade_relink_failure_restores`**:
   - Install 1.0.0 and 2.0.0. Install 3.0.0 with a one-shot `ln` shim that exits 1 when its last argument matches `*/.luuna-suite.tmp.*.lrt`. This fails mid-relink, after `lat`, `lbc` and `lms` have been relinked to 3.0.0.
   - Assert `RC=6`, output contains "restored the previous installation", and the snapshot is unchanged.
   - `lrt` and `lat` print `stub:…:2.0.0`, and `versions` = `1.0.0 2.0.0`.
   - A following plain install of 3.0.0 succeeds (`RC=0`).
2. **`t_first_install_relink_failure_restores`**: fresh roots, the same `ln` shim, install 1.0.0. Assert `RC=6` and the snapshot is unchanged: `$LUUNA_SUITE_HOME`, `$LUUNA_SUITE_BIN` and the created `.local` directories are all absent again.
3. **`t_reinstall_previous_relink_failure_restores_old_dir`**: install 1.0.0 and 2.0.0, take a snapshot, then reinstall 1.0.0 (whose `dest` exists) with the `ln` shim. Assert `RC=6` and the snapshot is unchanged. This proves the old `versions/1.0.0` came back byte-identical.
4. **`t_receipt_write_failure_restores`**: install 1.0.0 and 2.0.0, then install 3.0.0 with a one-shot `mv` shim that exits 1 when its last argument matches `*/luuna-suite/receipt.tsv`. Assert a nonzero `RC` and an unchanged snapshot. The undo's own `mv` back onto `receipt.tsv` passes through because the shim is one-shot.
5. **`t_pointer_write_failure_restores`**: the same as test 4, but the one-shot `mv` fails on `*/luuna-suite/current`, after `previous` has been written. Assert a nonzero `RC` and an unchanged snapshot.
6. **`t_rollback_relink_failure_restores`**: install 1.0.0 and 2.0.0, then run `--rollback` with the `ln` shim on `lrt`. Assert `RC=6` and an unchanged snapshot (current 2.0.0, previous 1.0.0). A following plain `--rollback` gives `RC=0` and current 1.0.0.
7. **`t_conflict_appears_mid_relink`**:
   - Install 1.0.0 and 2.0.0, take a snapshot, then install 3.0.0 with a one-shot `ln` shim. When its last argument matches `*/.luuna-suite.tmp.*.lms`, the shim first replaces `$LUUNA_SUITE_BIN/luuna-roots` with a regular file containing `foreign`, simulating a racing writer, then runs the real `ln`.
   - Assert `RC=6`, and that output contains "left" and "not owned".
   - Remove the `luuna-roots` line from both the before and after snapshots, then compare. They must be equal, and `$LUUNA_SUITE_BIN/luuna-roots` still contains `foreign`.
   - `current` = 2.0.0.
8. Success paths stay covered by the existing tests: `t_upgrade`, `t_rollback_twice` and the install success case, which already asserts that no `.stage.*`, `.tmp.*` or `.lock` remains. Extend that success-case loop to also assert no `.trash.*` remains.

### 8. Docs
- `tests/README.md`: one short paragraph. Fault injection uses one-shot PATH shims, and concurrency uses `mkfifo` barriers with no sleeps. The FIFO tests need `mkfifo`. If `mkfifo` is missing, use `skip_case` with a reason; never report it as a pass.

### 9. Validate
Run every command in **Validation Commands**. Up to three repair attempts per failing command. Report any optional tool that is absent as "not run", never as passing.

## Validation Commands

Run from `/Users/bnelly/github/luuna-ai-os-main/luuna-ai-os`. All required commands must pass.

```sh
sh tests/run.sh
sh tests/check-manifests.sh
sh -n scripts/install.sh && sh -n scripts/luuna-suite && sh -n scripts/lib/manifest.sh && sh -n scripts/adw-component.sh && for f in tests/*.sh; do sh -n "$f" || exit 1; done
sh scripts/install.sh --help >/dev/null && { sh scripts/install.sh --version 0.0.0; test $? -ne 0; }
test -z "$(git status --porcelain sources)"
```

Targeted, for faster iteration:

```sh
sh tests/run.sh tests/test-install.sh tests/test-upgrade-rollback.sh tests/test-uninstall.sh
```

Optional (report "not run" if the tool is absent):

```sh
dash tests/run.sh            # dash is present at /bin/dash on this machine: run it
TEST_SHELL=dash dash tests/run.sh
shellcheck -s sh scripts/install.sh scripts/luuna-suite scripts/lib/manifest.sh scripts/adw-component.sh tests/*.sh
```

## Acceptance Criteria

- **Finding 1.**
  - `t_first_install_race_loser_keeps_marker` passes on the patched code.
  - Reverting only the D1 reorder makes that test fail. Check this once by reasoning or by a local throwaway experiment, and do not keep the revert.
  - A process that exits 8 never creates or removes the marker, and never removes anything it did not create.
- **Finding 2.** Install, install `--dry-run`, rollback and rollback `--dry-run` all exit 6 with an unchanged filesystem when the receipt's `bin` or `home` differs from the resolved roots, or when `current` exists without a receipt. Uninstall behavior and messages are unchanged.
- **Finding 3.**
  - Install and rollback restore the previous `current`/`previous`, owned bin links and `receipt.tsv` byte-for-byte when any step after staging fails, including `HUP`/`INT`/`TERM`. On install, the newly placed `versions/<v>` is removed and a replaced older copy is put back.
  - Every case in task 7 passes with `assert_unchanged home "$HOME"` (or the documented single-entry exclusion in 7.7).
  - Foreign bin entries that appear during a run are never removed or overwritten by undo.
- Failures keep their original exit code, and no new exit codes are added. Committed state is never undone, and GC after the commit is non-fatal.
- Tests are deterministic: no `sleep`, no polling loops, no timeouts. They use only one-shot shims and FIFO barriers, with no network, Bun, Go, Rust, npm or real `claude`. They run in the `tests/run.sh` sandbox only.
- POSIX `sh` only. Every expansion is quoted, and nothing is `eval`ed.
- All required validation commands pass. `git status --porcelain sources` is empty. No commits, pushes, tags, PRs or publications. `.tac/` is unchanged. Other specs are unchanged. `releases/INDEX.tsv` stays header-only.

## Notes / limits

- POSIX `mv` cannot refuse to replace its destination, so a foreign entry created in the instant between the post-`ln` ownership re-check and `mv -f` can still be overwritten. The window is narrowed, not closed. This is documented in the `install.sh` header.
- If undo itself fails (a double fault, such as a full disk), the installer prints a diagnostic, keeps the marker and exits with the original code. The next `install` or `--rollback` will refuse or repair through the normal checks. Recovery state in `.trash.*` is swept on the next locked run.
- The race test proves the ordering at two specific barrier points (the loser at `mkdir .lock`, the winner at its first `cp`). It is not an exhaustive interleaving proof.
