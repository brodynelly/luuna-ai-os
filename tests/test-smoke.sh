#!/bin/sh
# Smoke test: the dependency-free tool set the suite relies on exists, and the sandbox is isolated.
. "$TESTS_DIR/lib.sh"

t_tools() {
  for tool in sh tar gzip mktemp grep sed awk ln mv cp rm find sort cksum readlink od dd tr wc cmp env; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool missing: $tool"
  done
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || fail "need sha256sum or shasum"
}

t_isolated() {
  case "$HOME" in "$SANDBOX"/*) ;; *) fail "HOME not sandboxed" ;; esac
  case "$LUUNA_SUITE_HOME" in "$HOME"/*) ;; *) fail "LUUNA_SUITE_HOME not under sandbox HOME" ;; esac
  case "$LUUNA_SUITE_BIN" in "$HOME"/*) ;; *) fail "LUUNA_SUITE_BIN not under sandbox HOME" ;; esac
  case "$TMPDIR" in "$SANDBOX"*) ;; *) fail "TMPDIR not sandboxed" ;; esac
}

t_tar_writer() {
  raw="$CASE_DIR/t.raw"; : > "$raw"
  tar_add "$raw" "bin/" 5 755
  tar_add "$raw" "bin/hello" 0 755 "hello world"
  tar_close "$raw" "$CASE_DIR/t.tar.gz"
  names=$(tar -tzf "$CASE_DIR/t.tar.gz" | tr '\n' ' ')
  assert_eq "$names" "bin/ bin/hello "
  mkdir "$CASE_DIR/x" && tar -xzf "$CASE_DIR/t.tar.gz" -C "$CASE_DIR/x"
  assert_eq "$(cat "$CASE_DIR/x/bin/hello")" "hello world"
}

run_case "required tools exist" t_tools
run_case "sandbox is isolated" t_isolated
run_case "portable ustar writer round-trips" t_tar_writer
if command -v git >/dev/null 2>&1; then run_case "git available" true; else skip_case "git available" "git not installed: git-based cases will skip"; fi
finish_tests
