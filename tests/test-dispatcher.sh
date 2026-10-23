#!/bin/sh
# H4: luuna-suite dispatcher routing, argument passing, version and read-only doctor.
. "$TESTS_DIR/lib.sh"

setup() {
  make_fixture_release "$CASE_DIR/rel" 1.0.0
  run_cmd "$SH" "$INSTALL" --manifest "$CASE_DIR/rel/manifest.tsv" --asset-dir "$CASE_DIR/rel/assets"
  assert_rc 0
}

t_routes() {
  setup
  for pair in atlas:luuna-atlas beacon:luuna-beacon missions:luuna-missions roots:luuna-roots; do
    run_cmd luuna-suite "${pair%%:*}" "with space" '$HOME' '*' ""
    assert_rc 0
    assert_out_contains "stub:${pair#*:}:1.0.0"
    assert_out_contains "arg:[with space]"
    assert_out_contains 'arg:[$HOME]'
    assert_out_contains "arg:[*]"
    assert_out_contains "arg:[]"
  done
}
t_relative_symlink_invocation() {
  setup
  mkdir -p "$CASE_DIR/alt"
  ln -s "../home/.local/bin/luuna-suite" "$CASE_DIR/alt/ls-link"
  run_cmd "$CASE_DIR/alt/ls-link" atlas ok; assert_rc 0; assert_out_contains "stub:luuna-atlas:1.0.0"
}
t_unknown() {
  setup
  run_cmd luuna-suite compass; assert_rc 2; assert_out_contains "unknown command"
  run_cmd luuna-suite; assert_rc 2
  run_cmd luuna-suite help; assert_rc 0; assert_out_contains "doctor"
}
t_doctor() {
  setup
  mkdir -p "$CASE_DIR/private"
  printf '#!/bin/sh\necho private-runtime\n' > "$CASE_DIR/private/luuna"
  chmod 755 "$CASE_DIR/private/luuna"
  take_snapshot private "$CASE_DIR/private"; take_snapshot home "$HOME"
  PATH="$CASE_DIR/private:$PATH" run_cmd luuna-suite doctor
  assert_rc 0
  assert_out_contains "luuna: $CASE_DIR/private/luuna"
  assert_out_contains "outside suite (private runtime or other)"
  assert_out_contains "lat: $LUUNA_SUITE_BIN/lat"
  assert_out_contains "[suite]"
  assert_out_contains "lu: not found"
  assert_unchanged private "$CASE_DIR/private"; assert_unchanged home "$HOME"
}
t_version() {
  setup
  run_cmd luuna-suite version; assert_rc 0
  assert_out_contains "luuna-suite 1.0.0"
  assert_out_contains "current${TAB}1.0.0"
  assert_out_contains "link${TAB}lat${TAB}"
  assert_out_contains "component${TAB}roots${TAB}1.0.0"
}
t_uninstalled_checkout() {
  run_cmd "$SH" "$HUB_ROOT/scripts/luuna-suite" version; assert_rc 0; assert_out_contains "not installed"
  run_cmd "$SH" "$HUB_ROOT/scripts/luuna-suite" atlas; assert_rc 127
}

run_case "routes every component and passes arguments verbatim" t_routes
run_case "works through a relative symlink" t_relative_symlink_invocation
run_case "unknown subcommand exits 2" t_unknown
run_case "doctor reports a private luuna as outside the suite, read-only" t_doctor
run_case "version prints the suite version and receipt" t_version
run_case "dispatcher from the checkout is not an install" t_uninstalled_checkout
finish_tests
