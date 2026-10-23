#!/bin/sh
# H2: installer success, failure paths (each proves the filesystem is unchanged) and attack cases.
. "$TESTS_DIR/lib.sh"

ALL_NAMES="luuna-suite luuna-atlas lat luuna-beacon lbc luuna-missions lms luuna-roots lrt"

fixture() { make_fixture_release "$CASE_DIR/rel" "$@"; MF="$CASE_DIR/rel/manifest.tsv"; AD="$CASE_DIR/rel/assets"; }
install_fixture() { run_cmd "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"; }

# expect_install_failure EXIT_CODE MUTATION...: fresh install of a mutated release fails and changes nothing.
expect_install_failure() {
  _code=$1; shift
  fixture 1.0.0 "$@"
  take_snapshot home "$HOME"
  install_fixture
  assert_rc "$_code"
  assert_unchanged home "$HOME"
  assert_absent "$LUUNA_SUITE_HOME"
  assert_absent "$LUUNA_SUITE_BIN"
}

t_success() {
  fixture 1.0.0
  install_fixture; assert_rc 0
  for n in $ALL_NAMES; do
    [ -L "$LUUNA_SUITE_BIN/$n" ] || fail "missing link $n"
    case "$(readlink "$LUUNA_SUITE_BIN/$n")" in "$LUUNA_SUITE_HOME/versions/1.0.0/bin/$n") ;; *) fail "bad target for $n" ;; esac
  done
  run_cmd lat --help; assert_rc 0; assert_out_contains "stub:lat:1.0.0"; assert_out_contains "arg:[--help]"
  run_cmd lrt "two words" ""; assert_rc 0; assert_out_contains "arg:[two words]"; assert_out_contains "arg:[]"
  assert_absent "$LUUNA_SUITE_BIN/luuna"; assert_absent "$LUUNA_SUITE_BIN/lu"
  assert_eq "$(cat "$LUUNA_SUITE_HOME/current")" 1.0.0
  assert_absent "$LUUNA_SUITE_HOME/previous"
  assert_file_contains "$LUUNA_SUITE_HOME/.luuna-suite-home" "luuna-suite-home 1"
  assert_file_contains "$LUUNA_SUITE_HOME/receipt.tsv" "current${TAB}1.0.0"
  [ ! -L "$LUUNA_SUITE_HOME/current" ] && [ -f "$LUUNA_SUITE_HOME/current" ] || fail "current must be a regular pointer file"
  for f in "$LUUNA_SUITE_HOME"/.stage.* "$LUUNA_SUITE_HOME"/.tmp.* "$LUUNA_SUITE_HOME"/.trash.* "$LUUNA_SUITE_HOME/.lock"; do assert_absent "$f"; done
  # Only the suite roots were written.
  assert_eq "$(ls -A "$HOME" | tr '\n' ' ')" ".local "
  assert_eq "$(ls -A "$HOME/.local" | tr '\n' ' ')" "bin share "
}

t_reinstall_same() { fixture 1.0.0; install_fixture; assert_rc 0; take_snapshot h "$HOME"; install_fixture; assert_rc 0; assert_out_contains "already"; assert_unchanged h "$HOME"; }

t_corrupt() { expect_install_failure 4 atlas:corrupt; }
t_badsha() { expect_install_failure 4 beacon:badsha; }
t_traversal() { expect_install_failure 5 atlas:traversal; assert_absent "$SANDBOX/evil"; assert_absent "$CASE_DIR/evil"; }
t_absolute() { expect_install_failure 5 missions:absolute; assert_absent "$SANDBOX/absolute-evil"; }
t_symlink() { expect_install_failure 5 roots:symlink; }
t_hardlink() { expect_install_failure 5 atlas:hardlink; }
t_device() { expect_install_failure 5 beacon:device; }
t_extra() { expect_install_failure 5 missions:extra; }
t_missing() { expect_install_failure 5 roots:missing; }
t_noexec() { expect_install_failure 5 atlas:noexec; }
t_duplicate_entry() { expect_install_failure 5 beacon:dup; }
t_last_component_fails() { expect_install_failure 5 roots:traversal; }

unsupported() { # UNAME_S UNAME_M
  fixture 1.0.0
  take_snapshot home "$HOME"
  LUUNA_SUITE_UNAME_S=$1 LUUNA_SUITE_UNAME_M=$2 run_cmd "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"
  assert_rc 3; assert_out_contains "unsupported platform"
  assert_unchanged home "$HOME"
}
t_windows() { unsupported Windows_NT x86_64; assert_out_contains "Windows is not supported"; }
t_freebsd() { unsupported FreeBSD amd64; }
t_riscv() { unsupported Linux riscv64; }
t_no_rows() { unsupported Darwin arm64; }

t_foreign_bin_file() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_BIN"; echo "user tool" > "$LUUNA_SUITE_BIN/lat"
  take_snapshot home "$HOME"
  install_fixture; assert_rc 6; assert_out_contains "$LUUNA_SUITE_BIN/lat"
  assert_unchanged home "$HOME"
}
t_foreign_bin_symlink_to_dir() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_BIN" "$CASE_DIR/victim"; echo keep > "$CASE_DIR/victim/file"
  ln -s "$CASE_DIR/victim" "$LUUNA_SUITE_BIN/lbc"
  take_snapshot home "$HOME"; take_snapshot victim "$CASE_DIR/victim"
  install_fixture; assert_rc 6
  assert_unchanged home "$HOME"; assert_unchanged victim "$CASE_DIR/victim"
}
t_bin_link_with_dotdot() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_BIN"
  ln -s "$LUUNA_SUITE_HOME/versions/../../../victim" "$LUUNA_SUITE_BIN/lms"
  take_snapshot home "$HOME"
  install_fixture; assert_rc 6; assert_unchanged home "$HOME"
}
t_private_names_untouched() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_BIN"; printf '#!/bin/sh\necho private\n' > "$LUUNA_SUITE_BIN/luuna"; chmod 755 "$LUUNA_SUITE_BIN/luuna"
  before=$(cksum < "$LUUNA_SUITE_BIN/luuna")
  install_fixture; assert_rc 0
  assert_eq "$(cksum < "$LUUNA_SUITE_BIN/luuna")" "$before"
  [ ! -L "$LUUNA_SUITE_BIN/luuna" ] || fail "luuna became a link"
  assert_absent "$LUUNA_SUITE_BIN/lu"
  assert_absent "$LUUNA_SUITE_HOME/versions/1.0.0/bin/luuna"
  assert_absent "$LUUNA_SUITE_HOME/versions/1.0.0/bin/lu"
}

t_dry_run() {
  fixture 1.0.0
  take_snapshot home "$HOME"
  run_cmd "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD" --dry-run; assert_rc 0
  assert_out_contains "would install atlas"
  assert_unchanged home "$HOME"; assert_absent "$LUUNA_SUITE_HOME"
}

t_fetch_failure() {
  fixture 1.0.0
  mkdir -p "$CASE_DIR/stubs"
  for tool in curl wget; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/fetch.log"\nexit 22\n' "$tool" "$CASE_DIR" > "$CASE_DIR/stubs/$tool"
    chmod 755 "$CASE_DIR/stubs/$tool"
  done
  take_snapshot home "$HOME"
  PATH="$CASE_DIR/stubs:$PATH" run_cmd "$SH" "$INSTALL" --manifest "$MF"
  assert_rc 7; assert_out_contains "download failed"
  assert_unchanged home "$HOME"
  assert_file_contains "$CASE_DIR/fetch.log" "--proto =https"
  assert_file_contains "$CASE_DIR/fetch.log" "https://github.com/brodynelly/luuna-atlas/releases/download/"
}

t_version_unpublished() {
  take_snapshot home "$HOME"
  run_cmd "$SH" "$INSTALL" --version 0.0.0; assert_rc 2
  assert_out_contains "No suite releases are published"
  assert_unchanged home "$HOME"
}
t_version_traversal() { run_cmd "$SH" "$INSTALL" --version ../../etc; assert_rc 2; assert_out_contains "invalid suite version"; }
t_invalid_manifest() {
  fixture 1.0.0
  sed '1s/.*/bogus/' "$MF" > "$CASE_DIR/bad.tsv"
  run_cmd "$SH" "$INSTALL" --manifest "$CASE_DIR/bad.tsv" --asset-dir "$AD"; assert_rc 2; assert_absent "$LUUNA_SUITE_HOME"
}
t_usage() {
  run_cmd "$SH" "$INSTALL"; assert_rc 2
  run_cmd "$SH" "$INSTALL" --bogus; assert_rc 2
  run_cmd "$SH" "$INSTALL" --rollback --uninstall; assert_rc 2
  run_cmd "$SH" "$INSTALL" --help; assert_rc 0; assert_out_contains "Exit codes"
}

# bad_root VAR VALUE MESSAGE: installer refuses the root (exit 2) and writes nothing.
bad_root() {
  fixture 1.0.0
  take_snapshot sb "$CASE_DIR"
  run_cmd env "$1=$2" "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"
  assert_rc 2; assert_out_contains "$3"
  assert_unchanged sb "$CASE_DIR"
}
t_root_home() { bad_root LUUNA_SUITE_HOME "$HOME" "must not be HOME"; }
t_root_home_slash() { bad_root LUUNA_SUITE_HOME "$HOME/" "must not be HOME"; }
t_root_slash() { bad_root LUUNA_SUITE_HOME / "must not be /"; }
t_root_ancestor() { bad_root LUUNA_SUITE_HOME "$CASE_DIR" "ancestor of HOME"; }
t_root_relative() { bad_root LUUNA_SUITE_HOME "rel/suite" "absolute"; }
t_root_dotdot() { bad_root LUUNA_SUITE_HOME "$HOME/a/../suite" "segments"; }
t_bin_home() { bad_root LUUNA_SUITE_BIN "$HOME" "must not be HOME"; }
t_bin_root() { bad_root LUUNA_SUITE_BIN "/" "must not be /"; }
t_bin_inside_home() { bad_root LUUNA_SUITE_BIN "$LUUNA_SUITE_HOME/bin" "inside LUUNA_SUITE_HOME"; }
t_home_inside_bin() { bad_root LUUNA_SUITE_HOME "$LUUNA_SUITE_BIN/suite" "inside LUUNA_SUITE_BIN"; }
t_root_control_char() { bad_root LUUNA_SUITE_HOME "$HOME/a$(printf '\t')b" "control characters"; }
t_root_symlink() {
  mkdir -p "$CASE_DIR/victim" "$HOME/.local/share"; echo keep > "$CASE_DIR/victim/file"
  ln -s "$CASE_DIR/victim" "$HOME/.local/share/luuna-suite"
  bad_root LUUNA_SUITE_HOME "$HOME/.local/share/luuna-suite" "must not be a symlink"
}
t_bin_symlink() {
  mkdir -p "$CASE_DIR/victim" "$HOME/.local"
  ln -s "$CASE_DIR/victim" "$HOME/.local/bin"
  bad_root LUUNA_SUITE_BIN "$HOME/.local/bin" "must not be a symlink"
}

t_foreign_home_dir() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_HOME"; echo data > "$LUUNA_SUITE_HOME/important"
  take_snapshot home "$HOME"
  install_fixture; assert_rc 6; assert_out_contains "no Luuna suite marker"
  assert_unchanged home "$HOME"
}
t_empty_existing_home() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_HOME"
  install_fixture; assert_rc 0
}
t_planted_current_symlink() {
  fixture 1.0.0
  install_fixture; assert_rc 0
  mkdir -p "$CASE_DIR/victim"; echo keep > "$CASE_DIR/victim/file"
  rm "$LUUNA_SUITE_HOME/current"; ln -s "$CASE_DIR/victim" "$LUUNA_SUITE_HOME/current"
  fixture 2.0.0
  take_snapshot home "$HOME"; take_snapshot victim "$CASE_DIR/victim"
  install_fixture; assert_rc 6
  assert_unchanged home "$HOME"; assert_unchanged victim "$CASE_DIR/victim"
}
t_lock_held() {
  fixture 1.0.0
  install_fixture; assert_rc 0
  mkdir "$LUUNA_SUITE_HOME/.lock"
  fixture 2.0.0
  take_snapshot home "$HOME"
  install_fixture; assert_rc 8; assert_out_contains "another install"
  assert_unchanged home "$HOME"
  run_cmd "$SH" "$INSTALL" --rollback; assert_rc 2
  run_cmd "$SH" "$INSTALL" --uninstall; assert_rc 8
  assert_unchanged home "$HOME"
}
t_unknown_entry_in_versions() {
  fixture 1.0.0
  install_fixture; assert_rc 0
  ln -s / "$LUUNA_SUITE_HOME/versions/9.9.9"
  fixture 2.0.0
  take_snapshot home "$HOME"
  install_fixture; assert_rc 6; assert_unchanged home "$HOME"
}

# --- first-install race (FIFO barriers, one-shot shims) --------------------------------
t_first_install_race_loser_keeps_marker() {
  fixture 1.0.0
  make_shim "$CASE_DIR/shim-b" mkdir '*/luuna-suite/.lock' "$(pause_body B)"
  make_shim "$CASE_DIR/shim-a" cp '*/dl/*' "$(pause_body A)"
  # B (the loser) pauses just before taking the lock. It must not have claimed the home yet.
  start_paused B env "PATH=$CASE_DIR/shim-b:$PATH" "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"
  # A (the winner) takes the lock, writes the marker and pauses at its first asset copy.
  start_paused A env "PATH=$CASE_DIR/shim-a:$PATH" "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"
  release_paused B
  # Record B's outcome while A still holds the lock, then release A before asserting, so a
  # failed assertion never leaves A blocked at its barrier.
  rc_b=$RC
  marker_b=$(cat "$LUUNA_SUITE_HOME/.luuna-suite-home" 2>/dev/null || echo "(missing)")
  lock_b=0; if [ -d "$LUUNA_SUITE_HOME/.lock" ]; then lock_b=1; fi
  release_paused A
  rc_a=$RC
  RC=$rc_b OUT_FILE="$CASE_DIR/B.out"
  assert_rc 8; assert_out_contains "another install"
  assert_eq "$marker_b" "luuna-suite-home 1" "(marker after the lock loser exited)"
  assert_eq "$lock_b" 1 "(winner's lock while it was paused)"
  RC=$rc_a OUT_FILE="$CASE_DIR/A.out"
  assert_rc 0
  assert_eq "$(cat "$LUUNA_SUITE_HOME/current")" 1.0.0
  run_cmd lat; assert_rc 0; assert_out_contains "stub:lat:1.0.0"
  run_cmd "$SH" "$INSTALL" --uninstall; assert_rc 0
  assert_absent "$LUUNA_SUITE_HOME"
}
t_lock_before_marker_no_write() {
  fixture 1.0.0
  mkdir -p "$LUUNA_SUITE_HOME/.lock"
  take_snapshot home "$HOME"
  install_fixture; assert_rc 8
  assert_unchanged home "$HOME"
  assert_absent "$LUUNA_SUITE_HOME/.luuna-suite-home"
}

# --- receipt roots --------------------------------------------------------------------
t_install_bin_mismatch() {
  fixture 1.0.0; install_fixture; assert_rc 0
  fixture 2.0.0
  take_snapshot home "$HOME"
  run_cmd env "LUUNA_SUITE_BIN=$HOME/other-bin" "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"
  assert_rc 6; assert_out_contains "LUUNA_SUITE_BIN="; assert_out_contains "rerun with"
  assert_unchanged home "$HOME"; assert_absent "$HOME/other-bin"
  run_cmd env "LUUNA_SUITE_BIN=$HOME/other-bin" "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD" --dry-run
  assert_rc 6
  assert_unchanged home "$HOME"; assert_absent "$HOME/other-bin"
}
t_install_receipt_home_mismatch() {
  fixture 1.0.0; install_fixture; assert_rc 0
  r="$LUUNA_SUITE_HOME/receipt.tsv"
  sed "s|^home${TAB}.*|home${TAB}$CASE_DIR/elsewhere|" "$r" > "$CASE_DIR/receipt.new"
  cat "$CASE_DIR/receipt.new" > "$r"
  assert_file_contains "$r" "home${TAB}$CASE_DIR/elsewhere"
  fixture 2.0.0
  take_snapshot home "$HOME"
  install_fixture; assert_rc 6; assert_out_contains "receipt was written for home"
  assert_unchanged home "$HOME"
}
t_install_missing_receipt_with_current() {
  fixture 1.0.0; install_fixture; assert_rc 0
  rm "$LUUNA_SUITE_HOME/receipt.tsv"
  fixture 2.0.0
  take_snapshot home "$HOME"
  install_fixture; assert_rc 6; assert_out_contains "no receipt.tsv"
  assert_unchanged home "$HOME"
}

# --- injected commit failure ----------------------------------------------------------
t_first_install_relink_failure_restores() {
  fixture 1.0.0
  make_shim "$CASE_DIR/shim" ln '*/.luuna-suite.tmp.*.lrt' 'exit 1'
  take_snapshot home "$HOME"
  run_cmd env "PATH=$CASE_DIR/shim:$PATH" "$SH" "$INSTALL" --manifest "$MF" --asset-dir "$AD"
  assert_rc 6; assert_out_contains "restored the previous installation"
  assert_exists "$CASE_DIR/fault.ln.fired"
  assert_unchanged home "$HOME"
  assert_absent "$LUUNA_SUITE_HOME"; assert_absent "$LUUNA_SUITE_BIN"; assert_absent "$HOME/.local"
}

run_case "install links every public command and runs the stub" t_success
run_case "reinstalling the current version changes nothing" t_reinstall_same
run_case "corrupted archive (byte flipped) fails checksum" t_corrupt
run_case "wrong manifest checksum fails" t_badsha
run_case "path traversal entry rejected" t_traversal
run_case "absolute path entry rejected" t_absolute
run_case "symlink entry rejected" t_symlink
run_case "hardlink entry rejected" t_hardlink
run_case "device entry rejected" t_device
run_case "extra unexpected entry rejected" t_extra
run_case "missing listed executable rejected" t_missing
run_case "non-executable entry rejected" t_noexec
run_case "duplicate entry (file then symlink) rejected" t_duplicate_entry
run_case "unsafe last component leaves nothing behind" t_last_component_fails
run_case "Windows_NT unsupported" t_windows
run_case "FreeBSD unsupported" t_freebsd
run_case "riscv64 unsupported" t_riscv
run_case "platform without manifest rows unsupported" t_no_rows
run_case "foreign bin file is an ownership conflict" t_foreign_bin_file
run_case "bin symlink to a foreign directory is not followed" t_foreign_bin_symlink_to_dir
run_case "bin symlink with .. into the home is not owned" t_bin_link_with_dotdot
run_case "pre-existing luuna is never touched or linked" t_private_names_untouched
run_case "--dry-run writes nothing" t_dry_run
run_case "https fetch failure exits 7 without network" t_fetch_failure
run_case "--version for an unpublished release fails clearly" t_version_unpublished
run_case "--version path traversal rejected" t_version_traversal
run_case "invalid manifest rejected before any write" t_invalid_manifest
run_case "usage errors" t_usage
run_case "LUUNA_SUITE_HOME=HOME rejected" t_root_home
run_case "LUUNA_SUITE_HOME=HOME/ rejected" t_root_home_slash
run_case "LUUNA_SUITE_HOME=/ rejected" t_root_slash
run_case "LUUNA_SUITE_HOME ancestor of HOME rejected" t_root_ancestor
run_case "relative LUUNA_SUITE_HOME rejected" t_root_relative
run_case "LUUNA_SUITE_HOME with .. rejected" t_root_dotdot
run_case "LUUNA_SUITE_BIN=HOME rejected" t_bin_home
run_case "LUUNA_SUITE_BIN=/ rejected" t_bin_root
run_case "LUUNA_SUITE_BIN inside LUUNA_SUITE_HOME rejected" t_bin_inside_home
run_case "LUUNA_SUITE_HOME inside LUUNA_SUITE_BIN rejected" t_home_inside_bin
run_case "control characters in a root rejected" t_root_control_char
run_case "symlinked LUUNA_SUITE_HOME rejected" t_root_symlink
run_case "symlinked LUUNA_SUITE_BIN rejected" t_bin_symlink
run_case "existing foreign home directory refused" t_foreign_home_dir
run_case "existing empty home directory accepted" t_empty_existing_home
run_case "planted current symlink is not followed" t_planted_current_symlink
run_case "held lock blocks every mutation" t_lock_held
run_case "unknown entry in versions/ refused" t_unknown_entry_in_versions
if command -v mkfifo >/dev/null 2>&1; then
  run_case "first-install race, the lock loser keeps the winner's marker" t_first_install_race_loser_keeps_marker
else
  skip_case "first-install race, the lock loser keeps the winner's marker" "mkfifo not available"
fi
run_case "lock is taken before the marker; a held lock writes nothing" t_lock_before_marker_no_write
run_case "install with a different LUUNA_SUITE_BIN than the receipt refuses" t_install_bin_mismatch
run_case "install with a receipt for another home refuses" t_install_receipt_home_mismatch
run_case "install with current but no receipt refuses" t_install_missing_receipt_with_current
run_case "first install undone after a relink failure" t_first_install_relink_failure_restores
finish_tests
