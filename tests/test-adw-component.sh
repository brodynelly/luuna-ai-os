#!/bin/sh
# H6: adw-component.sh runs a fake adw.sh only in a verified sibling repo, with bounded claude args.
# Uses a fake CLAUDE_BIN and a fake LUUNA_ADW_SCRIPT; never a real claude or network.
. "$TESTS_DIR/lib.sh"

WRAP="$HUB_ROOT/scripts/adw-component.sh"

setup() { # [PLUGIN_OUTPUT]
  ROOT="$CASE_DIR/components"; mkdir -p "$ROOT" "$CASE_DIR/fake"
  for c in atlas beacon; do
    git init -q "$ROOT/luuna-$c"
    git -C "$ROOT/luuna-$c" remote add origin "https://github.com/brodynelly/luuna-$c.git"
  done
  cat > "$CASE_DIR/fake/claude" <<EOF
#!/bin/sh
if [ "\$1" = plugin ] && [ "\$2" = list ]; then printf '%s\n' "${1-tac-final@luuna-marketplace (enabled)}"; exit 0; fi
printf '%s\n' "\$@" >> "$CASE_DIR/claude.argv"
EOF
  chmod 755 "$CASE_DIR/fake/claude"
  cat > "$CASE_DIR/fake/adw.sh" <<EOF
pwd -P > "$CASE_DIR/adw.cwd"
for a in "\$@"; do printf '%s\n' "\$a"; done > "$CASE_DIR/adw.argv"
printf '%s\n' "\$TAC_CLAUDE_ARGS" > "$CASE_DIR/adw.claude_args"
printf '%s\n' "\$CLAUDE_BIN" > "$CASE_DIR/adw.claude_bin"
EOF
  LUUNA_COMPONENTS_ROOT=$ROOT LUUNA_ADW_SCRIPT="$CASE_DIR/fake/adw.sh" CLAUDE_BIN="$CASE_DIR/fake/claude"
  export LUUNA_COMPONENTS_ROOT LUUNA_ADW_SCRIPT CLAUDE_BIN
  unset TAC_CLAUDE_ARGS LUUNA_ADW_MAX_TURNS LUUNA_ADW_ALLOWED_TOOLS 2>/dev/null || true
}
refused() { # MESSAGE ARGS...
  _m=$1; shift
  rm -f "$CASE_DIR/adw.cwd"
  run_cmd "$SH" "$WRAP" "$@"; assert_rc 2; assert_out_contains "$_m"
  assert_absent "$CASE_DIR/adw.cwd"
}

t_correct_cwd() {
  setup
  run_cmd "$SH" "$WRAP" atlas fix the thing; assert_rc 0
  assert_eq "$(cat "$CASE_DIR/adw.cwd")" "$(cd "$ROOT/luuna-atlas" && pwd -P)"
  assert_file_contains "$CASE_DIR/adw.argv" "plan_build_test"
  assert_eq "$(tail -1 "$CASE_DIR/adw.argv")" "fix the thing"
  assert_eq "$(cat "$CASE_DIR/adw.claude_bin")" "$CASE_DIR/fake/claude"
}
t_worktree_default() {
  setup
  run_cmd "$SH" "$WRAP" beacon task; assert_rc 0
  assert_file_contains "$CASE_DIR/adw.argv" "--worktree"
  run_cmd "$SH" "$WRAP" beacon --no-worktree task; assert_rc 0
  if grep -Fx -e --worktree "$CASE_DIR/adw.argv" >/dev/null; then fail "--no-worktree still passed --worktree"; fi
}
t_bounds() {
  setup
  LUUNA_ADW_MAX_TURNS=17 run_cmd "$SH" "$WRAP" atlas task; assert_rc 0
  args=$(cat "$CASE_DIR/adw.claude_args")
  for want in "--permission-mode acceptEdits" "--max-turns 17" '"Bash(git push *)"' '"Bash(git commit *)"' \
    '"Bash(git tag *)"' '"Bash(gh *)"' '"Bash(npm publish *)"' '"Bash(cargo publish *)"' '"Bash(curl *)"' '"Bash(wget *)"'; do
    case "$args" in *"$want"*) ;; *) fail "bounds missing $want: $args" ;; esac
  done
  case "$args" in *bypass*|*dangerously*) fail "bounds contain a bypass" ;; esac
}
# Reproduce upstream adw.sh's step line: eval "\"$claude_bin\" -p \"\$prompt\" --allowedTools $skill_rules $claude_args"
t_eval_safe() {
  setup
  LUUNA_ADW_ALLOWED_TOOLS='Bash(go test ./...)' run_cmd "$SH" "$WRAP" atlas task; assert_rc 0
  cat > "$CASE_DIR/argv.sh" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '<%s>\n' "$a"; done
EOF
  chmod 755 "$CASE_DIR/argv.sh"
  claude_bin="$CASE_DIR/argv.sh" claude_args=$(cat "$CASE_DIR/adw.claude_args") prompt='p $(touch pwned)' \
    bash -c 'skill_rules=" \"Skill(tac-final:plan)\""; eval "\"$claude_bin\" -p \"\$prompt\" --allowedTools $skill_rules $claude_args"' \
    > "$CASE_DIR/eval.out"
  for want in '<p $(touch pwned)>' '<--max-turns>' '<40>' '<Bash(git push *)>' '<Bash(gh *)>' '<Bash(curl *)>' '<Bash(go test ./...)>'; do
    grep -Fx -e "$want" "$CASE_DIR/eval.out" >/dev/null || { cat "$CASE_DIR/eval.out" >&2; fail "eval did not yield token $want"; }
  done
  assert_absent pwned; assert_absent "$CASE_DIR/pwned"
}
t_default_max_turns() { setup; run_cmd "$SH" "$WRAP" atlas task; assert_rc 0; assert_file_contains "$CASE_DIR/adw.claude_args" "--max-turns 40"; }
t_allowed_tools() {
  setup
  LUUNA_ADW_ALLOWED_TOOLS='Bash(go test *);Bash(make verify)' run_cmd "$SH" "$WRAP" atlas task; assert_rc 0
  assert_file_contains "$CASE_DIR/adw.claude_args" '--allowedTools "Bash(go test *)" "Bash(make verify)"'
}
t_allowed_tools_injection() {
  setup
  for bad in 'Bash(go test $(touch pwned))' 'Bash(x" --dangerously-skip-permissions ")' 'Bash(a;b)' 'Bash(`id`)' 'Bash(*)' 'Bash' 'WebFetch'; do
    LUUNA_ADW_ALLOWED_TOOLS=$bad run_cmd "$SH" "$WRAP" atlas task; assert_rc 2; assert_out_contains "not allowed"
  done
  assert_absent "$CASE_DIR/adw.cwd"; assert_absent "$CASE_DIR/pwned"
}
t_task_is_literal() {
  setup
  run_cmd "$SH" "$WRAP" atlas -- 'fix $(touch '"$CASE_DIR"'/pwned) "quoted"'; assert_rc 0
  assert_absent "$CASE_DIR/pwned"
  assert_file_contains "$CASE_DIR/adw.argv" 'fix $(touch'
}
t_spec() {
  setup
  mkdir -p "$ROOT/luuna-atlas/specs"; echo "# Chore: x" > "$ROOT/luuna-atlas/specs/chore-x.md"
  refused "not committed" atlas --spec specs/chore-x.md
  git -C "$ROOT/luuna-atlas" add specs/chore-x.md
  run_cmd "$SH" "$WRAP" atlas --spec specs/chore-x.md; assert_rc 0
  assert_file_contains "$CASE_DIR/adw.argv" "specs/chore-x.md"
  refused "relative path" atlas --spec ../hub/specs/x.md
  refused "relative path" atlas --spec /etc/passwd
  refused "not both" atlas --spec specs/chore-x.md and text
}
t_wrong_origin() {
  setup
  git -C "$ROOT/luuna-atlas" remote set-url origin https://github.com/someone-else/luuna-atlas.git
  refused "origin is" atlas task
  git -C "$ROOT/luuna-atlas" remote set-url origin https://github.com/brodynelly/luuna-beacon.git
  refused "origin is" atlas task
}
t_missing_repo() { setup; refused "not found" missions task; }
t_unknown_component() { setup; refused "unknown component" luuna task; }
t_hub_refused() {
  setup
  rm -rf "$ROOT/luuna-atlas"; ln -s "$HUB_ROOT" "$ROOT/luuna-atlas"
  refused "hub itself" atlas task
}
t_sources_refused() {
  setup
  rm -rf "$ROOT/luuna-beacon"; ln -s "$HUB_ROOT/sources/luuna-beacon" "$ROOT/luuna-beacon"
  refused "inside the hub" beacon task
  mkdir -p "$CASE_DIR/x/sources"; git init -q "$CASE_DIR/x/sources/luuna-atlas"
  git -C "$CASE_DIR/x/sources/luuna-atlas" remote add origin https://github.com/brodynelly/luuna-atlas.git
  LUUNA_COMPONENTS_ROOT="$CASE_DIR/x/sources" refused "sources/" atlas task
}
t_not_toplevel() {
  setup
  mkdir -p "$CASE_DIR/outer"; git init -q "$CASE_DIR/outer"
  git -C "$CASE_DIR/outer" remote add origin https://github.com/brodynelly/luuna-atlas.git
  mkdir -p "$CASE_DIR/outer/luuna-atlas"
  LUUNA_COMPONENTS_ROOT="$CASE_DIR/outer" refused "not the top" atlas task
}
t_plugin_missing() {
  setup "some-other-plugin@market"
  refused "tac-final Claude Code plugin is not installed" atlas task
  assert_absent "$CASE_DIR/claude.argv"
}
t_claude_missing() { setup; CLAUDE_BIN=no-such-claude-binary refused "not found" atlas task; }
t_claude_bin_injection() { setup; CLAUDE_BIN='claude"; touch pwned; "' refused "unsupported characters" atlas task; assert_absent pwned; }
t_pr_refused() { setup; refused "--pr is refused" atlas --pr task; }
t_issue_refused() { setup; refused "--issue is refused" atlas --issue 3; refused "--issue is refused" atlas -i 3; }
t_sdlc_refused() { setup; refused "sdlc is refused" atlas -w sdlc task; refused "sdlc is refused" atlas --workflow sdlc task; }
t_unknown_option() { setup; refused "unknown or refused option" atlas --workflow=sdlc task; refused "unknown or refused option" atlas --yolo task; }
t_bypass_refused() {
  setup
  TAC_CLAUDE_ARGS="--permission-mode bypassPermissions" refused "permission bypass" atlas task
  TAC_CLAUDE_ARGS="--dangerously-skip-permissions" refused "permission bypass" atlas task
  TAC_CLAUDE_ARGS="--permission-mode acceptEdits" refused "set by this wrapper" atlas task
}
t_bad_max_turns() {
  setup
  for bad in 0 201 -1 abc 1e3 "4 0" 0040000; do
    LUUNA_ADW_MAX_TURNS=$bad refused "LUUNA_ADW_MAX_TURNS" atlas task
  done
  refused "--max-fix" atlas --max-fix 99 task
}
t_base() {
  setup
  refused "--base requires worktree" atlas --no-worktree --base HEAD task
  refused "plain ref" atlas --base 'HEAD;id' task
  refused "unknown ref" atlas --base no-such-branch task
}
t_dirty_no_worktree() {
  setup
  echo x > "$ROOT/luuna-atlas/dirty.txt"
  refused "clean working tree" atlas --no-worktree task
}
t_missing_adw() { setup; LUUNA_ADW_SCRIPT="$CASE_DIR/nope/adw.sh" refused "adw.sh not found" atlas task; }
t_dry_run_passthrough() { setup; run_cmd "$SH" "$WRAP" atlas --dry-run task; assert_rc 0; assert_file_contains "$CASE_DIR/adw.argv" "--dry-run"; }
t_help() { run_cmd "$SH" "$WRAP" --help; assert_rc 0; assert_out_contains "Refused"; }

if ! command -v git >/dev/null 2>&1 || ! command -v bash >/dev/null 2>&1; then
  skip_case "adw-component" "git and bash are required"
  finish_tests; exit $?
fi
run_case "runs adw.sh with cwd set to the verified repo" t_correct_cwd
run_case "--worktree is the default" t_worktree_default
run_case "bounds include max-turns and push/commit/tag/gh/publish/network denials" t_bounds
run_case "bounds survive the upstream adw.sh eval as single tokens" t_eval_safe
run_case "default max-turns is 40" t_default_max_turns
run_case "validated allowed tools are appended" t_allowed_tools
run_case "allowed-tools injection attempts refused" t_allowed_tools_injection
run_case "task text is passed literally" t_task_is_literal
run_case "--spec must be committed, relative and safe" t_spec
run_case "wrong origin refused" t_wrong_origin
run_case "missing repo refused" t_missing_repo
run_case "unknown component refused" t_unknown_component
run_case "hub path refused" t_hub_refused
run_case "sources/ paths refused" t_sources_refused
run_case "non-toplevel directory refused" t_not_toplevel
run_case "missing tac-final plugin fails closed" t_plugin_missing
run_case "missing claude refused" t_claude_missing
run_case "CLAUDE_BIN shell injection refused" t_claude_bin_injection
run_case "--pr refused" t_pr_refused
run_case "--issue refused" t_issue_refused
run_case "sdlc refused" t_sdlc_refused
run_case "unknown options refused" t_unknown_option
run_case "caller TAC_CLAUDE_ARGS (bypassPermissions) refused" t_bypass_refused
run_case "bad max-turns and max-fix refused" t_bad_max_turns
run_case "--base validated" t_base
run_case "--no-worktree requires a clean tree" t_dirty_no_worktree
run_case "missing adw.sh refused" t_missing_adw
run_case "--dry-run passes through" t_dry_run_passthrough
run_case "help" t_help
finish_tests
