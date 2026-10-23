#!/bin/sh
# H3: upgrade keeps exactly one previous, failed upgrades leave current intact, rollback swaps.
. "$TESTS_DIR/lib.sh"

install_v() { # VERSION [MUTATION...]
  _v=$1; shift
  make_fixture_release "$CASE_DIR/rel-$_v" "$_v" "$@"
  run_cmd "$SH" "$INSTALL" --manifest "$CASE_DIR/rel-$_v/manifest.tsv" --asset-dir "$CASE_DIR/rel-$_v/assets"
}
current() { cat "$LUUNA_SUITE_HOME/current"; }
previous() { cat "$LUUNA_SUITE_HOME/previous" 2>/dev/null || echo none; }
versions() { ls "$LUUNA_SUITE_HOME/versions" | tr '\n' ' '; }

t_upgrade() {
  install_v 1.0.0; assert_rc 0
  install_v 2.0.0; assert_rc 0
  assert_eq "$(current)" 2.0.0; assert_eq "$(previous)" 1.0.0
  run_cmd lat; assert_out_contains "stub:lat:2.0.0"
  install_v 3.0.0; assert_rc 0
  assert_eq "$(current)" 3.0.0; assert_eq "$(previous)" 2.0.0
  assert_eq "$(versions)" "2.0.0 3.0.0 "
  assert_file_contains "$LUUNA_SUITE_HOME/receipt.tsv" "previous${TAB}2.0.0"
}

t_failed_upgrade_keeps_current() {
  install_v 1.0.0; assert_rc 0
  install_v 2.0.0; assert_rc 0
  take_snapshot home "$HOME"
  install_v 3.0.0 roots:corrupt; assert_rc 4
  assert_unchanged home "$HOME"
  install_v 3.0.0 roots:symlink; assert_rc 5
  assert_unchanged home "$HOME"
  assert_eq "$(current)" 2.0.0; assert_eq "$(previous)" 1.0.0
  run_cmd lrt; assert_rc 0; assert_out_contains "stub:lrt:2.0.0"
}

t_rollback_twice() {
  install_v 1.0.0; assert_rc 0
  install_v 2.0.0; assert_rc 0
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 0
  assert_eq "$(current)" 1.0.0; assert_eq "$(previous)" 2.0.0
  run_cmd lbc x; assert_out_contains "stub:lbc:1.0.0"
  run_cmd luuna-suite version; assert_out_contains "luuna-suite 1.0.0"
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 0
  assert_eq "$(current)" 2.0.0; assert_eq "$(previous)" 1.0.0
  run_cmd lbc x; assert_out_contains "stub:lbc:2.0.0"
}

t_rollback_without_previous() {
  install_v 1.0.0; assert_rc 0
  take_snapshot home "$HOME"
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 2; assert_out_contains "no previous version"
  assert_unchanged home "$HOME"
}
t_rollback_nothing_installed() {
  take_snapshot home "$HOME"
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 2
  assert_unchanged home "$HOME"
}
t_rollback_dry_run() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  take_snapshot home "$HOME"
  run_cmd "$SH" "$INSTALL" --rollback --dry-run; assert_rc 0; assert_out_contains "would roll back"
  assert_unchanged home "$HOME"
}
t_rollback_conflict() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  rm "$LUUNA_SUITE_BIN/lms"; echo mine > "$LUUNA_SUITE_BIN/lms"
  take_snapshot home "$HOME"
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 6
  assert_unchanged home "$HOME"
}
t_reinstall_previous() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  install_v 1.0.0; assert_rc 0
  assert_eq "$(current)" 1.0.0; assert_eq "$(previous)" 2.0.0
  run_cmd lat; assert_out_contains "stub:lat:1.0.0"
}

# install_with SHIM_DIR VERSION: install VERSION with SHIM_DIR prepended to the installer's PATH only.
install_with() {
  make_fixture_release "$CASE_DIR/rel-$2" "$2"
  run_cmd env "PATH=$1:$PATH" "$SH" "$INSTALL" --manifest "$CASE_DIR/rel-$2/manifest.tsv" --asset-dir "$CASE_DIR/rel-$2/assets"
}
LRT_GLOB='*/.luuna-suite.tmp.*.lrt'

t_rollback_bin_mismatch() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  take_snapshot home "$HOME"
  run_cmd env "LUUNA_SUITE_BIN=$HOME/other-bin" "$SH" "$INSTALL" --rollback
  assert_rc 6; assert_out_contains "rerun with"
  assert_unchanged home "$HOME"
  run_cmd env "LUUNA_SUITE_BIN=$HOME/other-bin" "$SH" "$INSTALL" --rollback --dry-run
  assert_rc 6
  assert_unchanged home "$HOME"
}

t_upgrade_relink_failure_restores() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  make_shim "$CASE_DIR/shim" ln "$LRT_GLOB" 'exit 1'
  take_snapshot home "$HOME"
  install_with "$CASE_DIR/shim" 3.0.0
  assert_rc 6; assert_out_contains "restored the previous installation"
  assert_exists "$CASE_DIR/fault.ln.fired"
  assert_unchanged home "$HOME"
  run_cmd lrt; assert_out_contains "stub:lrt:2.0.0"
  run_cmd lat; assert_out_contains "stub:lat:2.0.0"
  assert_eq "$(versions)" "1.0.0 2.0.0 "
  install_v 3.0.0; assert_rc 0
  assert_eq "$(current)" 3.0.0; assert_eq "$(previous)" 2.0.0
}

t_reinstall_previous_relink_failure_restores_old_dir() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  make_shim "$CASE_DIR/shim" ln "$LRT_GLOB" 'exit 1'
  take_snapshot home "$HOME"
  install_with "$CASE_DIR/shim" 1.0.0
  assert_rc 6; assert_out_contains "restored the previous installation"
  assert_unchanged home "$HOME"
}

t_receipt_write_failure_restores() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  make_shim "$CASE_DIR/shim" mv '*/luuna-suite/receipt.tsv' 'exit 1'
  take_snapshot home "$HOME"
  install_with "$CASE_DIR/shim" 3.0.0
  assert_rc_nonzero; assert_out_contains "restored the previous installation"
  assert_exists "$CASE_DIR/fault.mv.fired"
  assert_unchanged home "$HOME"
}

t_pointer_write_failure_restores() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  make_shim "$CASE_DIR/shim" mv '*/luuna-suite/current' 'exit 1'
  take_snapshot home "$HOME"
  install_with "$CASE_DIR/shim" 3.0.0
  assert_rc_nonzero; assert_out_contains "restored the previous installation"
  assert_exists "$CASE_DIR/fault.mv.fired"
  assert_unchanged home "$HOME"
}

t_rollback_relink_failure_restores() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  make_shim "$CASE_DIR/shim" ln "$LRT_GLOB" 'exit 1'
  take_snapshot home "$HOME"
  run_cmd env "PATH=$CASE_DIR/shim:$PATH" "$SH" "$INSTALL" --rollback
  assert_rc 6; assert_out_contains "restored the previous installation"
  assert_unchanged home "$HOME"
  assert_eq "$(current)" 2.0.0; assert_eq "$(previous)" 1.0.0
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 0
  assert_eq "$(current)" 1.0.0
}

t_conflict_appears_mid_relink() {
  install_v 1.0.0; assert_rc 0; install_v 2.0.0; assert_rc 0
  # A racing writer replaces luuna-roots with a foreign file while lms is being relinked.
  make_shim "$CASE_DIR/shim" ln '*/.luuna-suite.tmp.*.lms' \
    'rm -f "$LUUNA_SUITE_BIN/luuna-roots"; echo foreign > "$LUUNA_SUITE_BIN/luuna-roots"'
  take_snapshot home "$HOME"
  install_with "$CASE_DIR/shim" 3.0.0
  assert_rc 6; assert_out_contains "left"; assert_out_contains "not owned"
  # Snapshot lines are "T MODE PATH ..."; PATH starts at column 14 and may contain spaces.
  drop="$LUUNA_SUITE_BIN/luuna-roots"
  only_other() { awk -v p="$drop" '!(substr($0, 14, length(p)) == p && substr($0, 14 + length(p), 1) == " ")'; }
  only_other < "$SANDBOX/snaps/home" > "$SANDBOX/snaps/home.filtered"
  snapshot "$HOME" | only_other > "$SANDBOX/snaps/home.filtered.after"
  [ "$(wc -l < "$SANDBOX/snaps/home")" -eq $(($(wc -l < "$SANDBOX/snaps/home.filtered") + 1)) ] || fail "filter did not drop exactly one line"
  if ! cmp -s "$SANDBOX/snaps/home.filtered" "$SANDBOX/snaps/home.filtered.after"; then
    diff "$SANDBOX/snaps/home.filtered" "$SANDBOX/snaps/home.filtered.after" >&2 || true
    fail "filesystem changed beyond the foreign luuna-roots entry"
  fi
  assert_eq "$(cat "$LUUNA_SUITE_BIN/luuna-roots")" foreign
  [ ! -L "$LUUNA_SUITE_BIN/luuna-roots" ] || fail "foreign luuna-roots was replaced"
  assert_eq "$(current)" 2.0.0
}

run_case "upgrade keeps exactly one previous" t_upgrade
run_case "failed upgrade (last component) leaves current intact" t_failed_upgrade_keeps_current
run_case "rollback swaps current and previous, twice" t_rollback_twice
run_case "rollback with no previous changes nothing" t_rollback_without_previous
run_case "rollback with nothing installed changes nothing" t_rollback_nothing_installed
run_case "rollback --dry-run writes nothing" t_rollback_dry_run
run_case "rollback refuses a foreign bin entry" t_rollback_conflict
run_case "reinstalling the previous version re-stages it" t_reinstall_previous
run_case "rollback with a different LUUNA_SUITE_BIN than the receipt refuses" t_rollback_bin_mismatch
run_case "upgrade undone after a relink failure" t_upgrade_relink_failure_restores
run_case "reinstall of the previous version undone, old copy restored" t_reinstall_previous_relink_failure_restores_old_dir
run_case "upgrade undone after a receipt write failure" t_receipt_write_failure_restores
run_case "upgrade undone after a pointer write failure" t_pointer_write_failure_restores
run_case "rollback undone after a relink failure" t_rollback_relink_failure_restores
run_case "foreign bin entry appearing mid-relink is left in place" t_conflict_appears_mid_relink
finish_tests
