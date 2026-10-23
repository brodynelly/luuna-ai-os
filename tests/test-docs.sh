#!/bin/sh
# H7: documentation and release-directory guards. Docs must not advertise installs that do not exist.
. "$TESTS_DIR/lib.sh"

DOCS="$HUB_ROOT/README.md $HUB_ROOT/docs/PACKAGING.md $HUB_ROOT/docs/RELEASING.md $HUB_ROOT/docs/INTENT.md $HUB_ROOT/releases/README.md $HUB_ROOT/releases/FORMAT.md"

# npm_unpublished FILE: every paragraph mentioning `npm install -g @luuna-ai-os` also says "not published".
npm_unpublished() {
  awk 'BEGIN { RS = "" } /npm install -g @luuna-ai-os/ { if (tolower($0) !~ /not published/) { print FILENAME ": " substr($0, 1, 120); bad = 1 } } END { exit bad }' "$1"
}
t_npm() {
  for f in $DOCS; do [ -f "$f" ] || continue; npm_unpublished "$f" || fail "npm install advertised without 'not published' in $f"; done
  # The guard itself catches an unqualified claim.
  printf 'Install with npm install -g @luuna-ai-os/cli today.\n' > "$CASE_DIR/bad.md"
  if npm_unpublished "$CASE_DIR/bad.md" >/dev/null; then fail "npm guard missed an unqualified claim"; fi
}

pipe_to_shell() { grep -nE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([^A-Za-z0-9_-]|$)' "$1"; }
t_no_curl_pipe() {
  for f in $DOCS; do [ -f "$f" ] || continue; if pipe_to_shell "$f"; then fail "pipe-to-shell install line in $f"; fi; done
  printf 'curl -fsSL https://example.invalid/install.sh | sh\n' > "$CASE_DIR/bad.md"
  pipe_to_shell "$CASE_DIR/bad.md" >/dev/null || fail "pipe guard missed curl | sh"
}

t_no_checksums_in_releases() {
  if grep -rnE '[0-9a-fA-F]{64}' "$HUB_ROOT/releases"; then fail "64-hex string under releases/ (real checksums arrive only through the owner gate)"; fi
  assert_eq "$(wc -l < "$HUB_ROOT/releases/INDEX.tsv" | tr -d ' ')" 1
  for d in "$HUB_ROOT/releases"/*/; do [ -d "$d" ] && fail "release directory present: $d"; done
  true
}

t_windows_claims() {
  # Distribution docs only (docs/INTENT.md lists Windows qualification as open work, not a claim).
  for f in "$HUB_ROOT/README.md" "$HUB_ROOT/docs/PACKAGING.md" "$HUB_ROOT/docs/RELEASING.md" "$HUB_ROOT/releases/README.md" "$HUB_ROOT/releases/FORMAT.md"; do
    [ -f "$f" ] || continue
    if grep -niE 'windows' "$f" | grep -iE 'native|public installer|support' | grep -viE 'not|unsupported|no windows|private|follow-up|nothing'; then
      fail "possible Windows support claim in $f"
    fi
  done
  grep -F "Windows: not supported by the public installer" "$HUB_ROOT/README.md" >/dev/null || fail "README must state the Windows posture"
  grep -F "Public native install: macOS and Linux (x86_64, arm64)" "$HUB_ROOT/README.md" >/dev/null || fail "README must state the public platforms"
  if grep -rniE '_windows_|windows_(amd64|arm64)' "$HUB_ROOT/releases" "$HUB_ROOT/scripts/lib/manifest.sh"; then fail "Windows asset naming present"; fi
  true
}

t_no_private_link_targets() {
  for f in "$HUB_ROOT/scripts/install.sh" "$HUB_ROOT/scripts/luuna-suite" "$HUB_ROOT/scripts/lib/manifest.sh"; do
    if grep -nE '(BIN|bin)[A-Za-z_]*\}?/(luuna|lu)(["'"'"' ]|$)|ln -s[^#]*[/ ](luuna|lu)(["'"'"' ]|$)' "$f"; then
      fail "$f references luuna/lu as a link target"
    fi
  done
  # The public name lists contain neither luuna nor lu.
  for f in "$HUB_ROOT/scripts/install.sh" "$HUB_ROOT/scripts/luuna-suite"; do
    names=$(sed -n 's/^PUBLIC_NAMES="\(.*\)"$/\1/p' "$f")
    [ -n "$names" ] || fail "no PUBLIC_NAMES in $f"
    case " $names " in *" luuna "*|*" lu "*) fail "PUBLIC_NAMES includes a private name in $f" ;; esac
  done
}

t_ps1_header() {
  head -5 "$HUB_ROOT/scripts/install-cli.ps1" | grep -F "NOT the public installer" >/dev/null || fail "install-cli.ps1 header missing"
}

t_workflow_read_only() {
  wf="$HUB_ROOT/.github/workflows/distribution-tests.yml"
  grep -E '^permissions:' "$wf" >/dev/null && grep -E '^  contents: read$' "$wf" >/dev/null || fail "workflow must be contents: read"
  if grep -nE 'secrets\.|gh release|action-gh-release|npm publish|cargo publish|attest|id-token|contents: write' "$wf"; then fail "workflow has a publish or secret step"; fi
  true
}

run_case "npm install only appears with 'not published'" t_npm
run_case "no curl/wget pipe-to-shell lines" t_no_curl_pipe
run_case "no checksums or release directories under releases/" t_no_checksums_in_releases
run_case "no Windows native or public-installer claims" t_windows_claims
run_case "installer and dispatcher never target luuna/lu" t_no_private_link_targets
run_case "install-cli.ps1 is marked private" t_ps1_header
run_case "distribution workflow is read-only" t_workflow_read_only
finish_tests
