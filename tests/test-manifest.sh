#!/bin/sh
# H1: manifest format validation, platform selection, index hashes and append-only immutability.
. "$TESTS_DIR/lib.sh"
. "$HUB_ROOT/scripts/lib/manifest.sh"

CHECK="$HUB_ROOT/tests/check-manifests.sh"

valid_manifest() { make_fixture_release "$CASE_DIR/rel" 1.0.0; M="$CASE_DIR/rel/manifest.tsv"; }

# edit_row3 SED_EXPR: copy the valid manifest with the first asset row rewritten.
edit_row3() { sed "3$1" "$M" > "$CASE_DIR/bad.tsv"; }
expect_invalid() { # MESSAGE_FRAGMENT
  if cmp -s "$M" "$CASE_DIR/bad.tsv"; then fail "mutation did not change the manifest"; fi
  run_cmd manifest_validate "$CASE_DIR/bad.tsv"
  assert_rc_nonzero
  assert_out_contains "$1"
}

t_valid() { valid_manifest; run_cmd manifest_validate "$M"; assert_rc 0; assert_eq "$(manifest_suite "$M")" 1.0.0; }
t_bad_header() { valid_manifest; sed '1s/.*/luuna-suite-manifest\t2/' "$M" > "$CASE_DIR/bad.tsv"; expect_invalid "header"; }
t_bad_suite() { valid_manifest; sed '2s/.*/suite\tv1/' "$M" > "$CASE_DIR/bad.tsv"; expect_invalid "suite"; }
t_sha_63() { valid_manifest; edit_row3 's/\t\([0-9a-f]\{63\}\)[0-9a-f]\t/\t\1\t/'; expect_invalid "sha256"; }
t_sha_upper() {
  valid_manifest
  awk -F '\t' 'BEGIN{OFS="\t"} NR==3{$7=toupper($7)} {print}' "$M" > "$CASE_DIR/bad.tsv"
  expect_invalid "sha256"
}
t_http_url() { valid_manifest; edit_row3 's#https://#http://#'; expect_invalid "url must start with"; }
t_wrong_repo() { valid_manifest; edit_row3 's#brodynelly/luuna-atlas/#brodynelly/luuna-beacon/#'; expect_invalid "url must start with"; }
t_other_owner() { valid_manifest; edit_row3 's#github.com/brodynelly/#github.com/someone/#'; expect_invalid "url must start with"; }
t_url_name_mismatch() { valid_manifest; edit_row3 's#\.tar\.gz\t#.tgz\t#'; expect_invalid "url must be"; }
t_unknown_component() { valid_manifest; edit_row3 's/^asset\tatlas\t/asset\tcompass\t/'; expect_invalid "unknown component"; }
t_bad_os() {
  valid_manifest
  awk -F '\t' 'BEGIN{OFS="\t"} NR==3{$4="windows"} {print}' "$M" > "$CASE_DIR/bad.tsv"
  expect_invalid "unsupported os"
}
t_exe_luuna() { valid_manifest; edit_row3 's/luuna-atlas,lat$/luuna-atlas,luuna/'; expect_invalid "not a public executable"; }
t_exe_lu() { valid_manifest; edit_row3 's/luuna-atlas,lat$/luuna-atlas,lu/'; expect_invalid "not a public executable"; }
t_exe_la() { valid_manifest; edit_row3 's/luuna-atlas,lat$/luuna-atlas,la/'; expect_invalid "not a public executable"; }
t_exe_no_primary() { valid_manifest; edit_row3 's/luuna-atlas,lat$/lat/'; expect_invalid "must include luuna-atlas"; }
t_duplicate_row() { valid_manifest; { cat "$M"; sed -n 3p "$M"; } > "$CASE_DIR/bad.tsv"; expect_invalid "duplicate asset row"; }
t_crlf() { valid_manifest; sed 's/$/\r/' "$M" > "$CASE_DIR/bad.tsv"; expect_invalid "CRLF"; }
t_extra_field() { valid_manifest; edit_row3 's/$/\textra/'; expect_invalid "9 tab-separated"; }
t_blank_line() { valid_manifest; { cat "$M"; echo; } > "$CASE_DIR/bad.tsv"; expect_invalid "9 tab-separated"; }
t_shell_meta() { valid_manifest; edit_row3 's#/v1\.0\.0/#/v1.0.0$(id)/#'; expect_invalid "url"; }

t_select() {
  valid_manifest
  run_cmd manifest_select "$M" linux amd64; assert_rc 0
  assert_eq "$(wc -l < "$OUT_FILE" | tr -d ' ')" 4
  run_cmd manifest_select "$M" darwin arm64; assert_rc 3
  sed '/\troots\t/d' "$M" > "$CASE_DIR/partial.tsv"
  run_cmd manifest_select "$CASE_DIR/partial.tsv" linux amd64; assert_rc 3; assert_out_contains "no roots asset"
}

t_version_ids() {
  manifest_is_version 1.2.3 || fail "1.2.3 rejected"
  manifest_is_version 1.2.3-rc.1 || fail "rc rejected"
  for bad in "" v1.2.3 1.2 "1.2.3 " "../1.2.3" "1.2.3/../x" "1.2.3-" "1.2.3
1.2.4"; do
    if manifest_is_version "$bad"; then fail "accepted bad version [$bad]"; fi
  done
}

t_repo_header_only() {
  run_cmd sh "$CHECK"; assert_rc 0; assert_out_contains "ok (0 release"
  assert_eq "$(wc -l < "$HUB_ROOT/releases/INDEX.tsv" | tr -d ' ')" 1
}

# make_releases_repo: throwaway checkout layout with releases/ for check-manifests --root.
make_releases_repo() {
  R="$CASE_DIR/repo"
  mkdir -p "$R/releases"
  printf '#suite-version\tmanifest-sha256\n' > "$R/releases/INDEX.tsv"
}
add_release() { # VERSION
  make_fixture_release "$CASE_DIR/fx-$1" "$1"
  mkdir -p "$R/releases/$1"
  cp "$CASE_DIR/fx-$1/manifest.tsv" "$R/releases/$1/manifest.tsv"
  printf '%s\t%s\n' "$1" "$(sha256_of "$R/releases/$1/manifest.tsv")" >> "$R/releases/INDEX.tsv"
}

t_index_ok() { make_releases_repo; add_release 1.0.0; run_cmd sh "$CHECK" --root "$R"; assert_rc 0; }
t_index_mismatch() {
  make_releases_repo; add_release 1.0.0
  printf '#suite-version\tmanifest-sha256\n1.0.0\t%064d\n' 0 > "$R/releases/INDEX.tsv"
  run_cmd sh "$CHECK" --root "$R"; assert_rc 1; assert_out_contains "does not match its INDEX.tsv hash"
}
t_index_duplicate() {
  make_releases_repo; add_release 1.0.0
  sed -n 2p "$R/releases/INDEX.tsv" >> "$R/releases/INDEX.tsv"
  run_cmd sh "$CHECK" --root "$R"; assert_rc 1; assert_out_contains "duplicate version"
}
t_unindexed_dir() {
  make_releases_repo; add_release 1.0.0
  printf '#suite-version\tmanifest-sha256\n' > "$R/releases/INDEX.tsv"
  run_cmd sh "$CHECK" --root "$R"; assert_rc 1; assert_out_contains "not listed in INDEX.tsv"
}
t_suite_dir_mismatch() {
  make_releases_repo; add_release 1.0.0
  mv "$R/releases/1.0.0" "$R/releases/1.0.1"
  printf '#suite-version\tmanifest-sha256\n1.0.1\t%s\n' "$(sha256_of "$R/releases/1.0.1/manifest.tsv")" > "$R/releases/INDEX.tsv"
  run_cmd sh "$CHECK" --root "$R"; assert_rc 1; assert_out_contains "suite line does not match"
}

git_repo() {
  make_releases_repo
  git -C "$R" init -q
  git -C "$R" config user.email test@example.invalid
  git -C "$R" config user.name test
  git -C "$R" config commit.gpgsign false
  add_release 1.0.0
  git -C "$R" add -A && git -C "$R" commit -q -m base
}
t_append_ok() {
  git_repo; add_release 1.1.0
  run_cmd sh "$CHECK" --root "$R" --base HEAD; assert_rc 0
}
t_modified_manifest_rejected() {
  git_repo
  # Rewrite the published manifest (and its index line, so only immutability can catch it).
  sed '3s/luuna-atlas,lat$/luuna-atlas/' "$R/releases/1.0.0/manifest.tsv" > "$R/m" && mv "$R/m" "$R/releases/1.0.0/manifest.tsv"
  printf '#suite-version\tmanifest-sha256\n1.0.0\t%s\n' "$(sha256_of "$R/releases/1.0.0/manifest.tsv")" > "$R/releases/INDEX.tsv"
  run_cmd sh "$CHECK" --root "$R"; assert_rc 0
  run_cmd sh "$CHECK" --root "$R" --base HEAD; assert_rc 1
  assert_out_contains "published release file changed (M): releases/1.0.0/manifest.tsv"
  assert_out_contains "INDEX.tsv may only gain appended lines"
}
t_deleted_release_rejected() {
  git_repo
  rm -rf "$R/releases/1.0.0"
  printf '#suite-version\tmanifest-sha256\n' > "$R/releases/INDEX.tsv"
  run_cmd sh "$CHECK" --root "$R" --base HEAD; assert_rc 1; assert_out_contains "(D)"
}
t_unknown_base() { git_repo; run_cmd sh "$CHECK" --root "$R" --base no-such-ref; assert_rc 2; }

run_case "valid fixture manifest" t_valid
run_case "bad header rejected" t_bad_header
run_case "bad suite line rejected" t_bad_suite
run_case "63-character sha rejected" t_sha_63
run_case "uppercase sha rejected" t_sha_upper
run_case "non-https url rejected" t_http_url
run_case "url for the wrong component repo rejected" t_wrong_repo
run_case "url for another owner rejected" t_other_owner
run_case "url not ending in the archive name rejected" t_url_name_mismatch
run_case "unknown component rejected" t_unknown_component
run_case "unsupported os rejected" t_bad_os
run_case "executable luuna rejected" t_exe_luuna
run_case "executable lu rejected" t_exe_lu
run_case "executable la rejected" t_exe_la
run_case "missing primary executable rejected" t_exe_no_primary
run_case "duplicate row rejected" t_duplicate_row
run_case "CRLF line endings rejected" t_crlf
run_case "extra field rejected" t_extra_field
run_case "blank line rejected" t_blank_line
run_case "shell metacharacters in url rejected" t_shell_meta
run_case "platform selection requires all four components" t_select
run_case "version identifiers are validated" t_version_ids
run_case "repository releases/ is header-only and valid" t_repo_header_only
run_case "indexed manifest passes" t_index_ok
run_case "index hash mismatch rejected" t_index_mismatch
run_case "duplicate index version rejected" t_index_duplicate
run_case "unindexed release directory rejected" t_unindexed_dir
run_case "suite line must match directory" t_suite_dir_mismatch
if command -v git >/dev/null 2>&1; then
  run_case "appending a release passes --base" t_append_ok
  run_case "modified existing manifest rejected against --base" t_modified_manifest_rejected
  run_case "deleted release rejected against --base" t_deleted_release_rejected
  run_case "unknown base ref is a usage error" t_unknown_base
else
  skip_case "immutability against --base" "git not installed"
fi
finish_tests
