#!/bin/sh
# Luuna suite native installer for macOS and Linux (POSIX sh). See --help and releases/FORMAT.md.
#
# Safety model:
#   - Writes only under LUUNA_SUITE_HOME and LUUNA_SUITE_BIN. Both are validated (absolute, not /,
#     not HOME or an ancestor of it, not a symlink, not nested in each other).
#   - Never writes .luuna/, ~/.luuna, ~/.pi, a repository, or `luuna`/`lu`.
#   - Every archive is checksum-verified and its listing allow-listed before extraction. All
#     components are staged before anything visible changes.
#   - current/previous are regular pointer files replaced by rename. Bin links are replaced by
#     rename only after an ownership check, so no swap follows a destination symlink.
#   - Recursive removal needs the home marker, a matching receipt, and only installer-created
#     entries. Mutations hold a mkdir lock.
#   - The lock is taken before the home marker is written, and only the lock holder may write or
#     remove the marker. A run that loses the lock (exit 8) removes only directories it created.
#   - Install, rollback and uninstall (including --dry-run) refuse when receipt.tsv names a
#     different LUUNA_SUITE_HOME or LUUNA_SUITE_BIN, or when current exists without a receipt.
#   - The commit phase (version dir, pointers, bin links, receipt) is journaled under the lock in
#     a .trash.* directory. A failure or HUP/INT/TERM before the receipt is written replays the
#     journal and restores the previous state byte for byte; foreign bin entries seen at check
#     time are left untouched. The receipt write is the commit point; GC after it is non-fatal.
#     If the undo itself fails, the journal is retained for manual recovery (docs/NATIVE-DISTRIBUTION.md).
#   - Residual races: POSIX mv has no no-replace rename. Every check-then-rename or check-then-unlink
#     of a bin entry (link_bin relink, undo's link restore/removal, stale-link removal, uninstall)
#     has a narrowed but open window: a foreign entry created in that instant can still be
#     replaced or removed. link_bin re-checks ownership immediately before `mv -f`.
set -eu
umask 022

PROG="luuna-suite install"
script_dir=$(cd "$(dirname "$0")" && pwd -P)
hub_root=$(cd "$script_dir/.." && pwd -P)
. "$script_dir/lib/manifest.sh"

TAB=$(printf '\t')
PUBLIC_NAMES="luuna-suite luuna-atlas lat luuna-beacon lbc luuna-missions lms luuna-roots lrt"
MARKER_NAME=.luuna-suite-home
MARKER_TEXT="luuna-suite-home 1"
VERSION_META=.luuna-suite-version.tsv

usage() {
  cat <<'USAGE'
Usage: install.sh --manifest PATH [--asset-dir DIR] [--dry-run]
       install.sh --version V [--asset-dir DIR] [--dry-run]
       install.sh --rollback [--dry-run]
       install.sh --uninstall [--dry-run]
       install.sh --help

Installs the public Luuna suite CLIs (luuna-atlas/lat, luuna-beacon/lbc, luuna-missions/lms,
luuna-roots/lrt) and the luuna-suite dispatcher for the current user. No sudo is needed. It never
installs or links `luuna` or `lu`, which belong to the private Luuna runtime.

  --manifest PATH  Install the release described by a manifest file (releases/FORMAT.md)
  --version V      Install releases/V/manifest.tsv from this checkout. It must match releases/INDEX.tsv.
                   No releases are published yet, so this currently always fails.
  --asset-dir DIR  Read archives from DIR (offline). Without it, archives are fetched from the
                   manifest's https URLs with curl or wget.
  --rollback       Swap the current and previous installed versions
  --uninstall      Remove the receipt-owned links and LUUNA_SUITE_HOME. Project stores are never touched.
  --dry-run        Validate and print the plan without writing anything

Environment:
  LUUNA_SUITE_HOME  Install root (default: ${XDG_DATA_HOME:-$HOME/.local/share}/luuna-suite)
  LUUNA_SUITE_BIN   Directory for command links (default: $HOME/.local/bin)
  LUUNA_SUITE_UNAME_S, LUUNA_SUITE_UNAME_M
                    Override `uname -s` / `uname -m`. These exist for tests only.

Exit codes: 0 ok, 2 usage or invalid input, 3 unsupported platform, 4 checksum mismatch,
5 unsafe or malformed archive, 6 ownership conflict, 7 fetch failure, 8 another install holds the lock.
USAGE
}

die() { _code=$1; shift; echo "$PROG: $*" >&2; exit "$_code"; }
say() { echo "$PROG: $*"; }

# --- arguments ------------------------------------------------------------------
mode=""; manifest=""; version=""; asset_dir=""; dry_run=0
set_mode() { [ -z "$mode" ] || [ "$mode" = "$1" ] || die 2 "choose one of install, --rollback, --uninstall"; mode=$1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) [ $# -ge 2 ] || die 2 "--manifest needs a path"; set_mode install; manifest=$2; shift 2 ;;
    --version) [ $# -ge 2 ] || die 2 "--version needs a value"; set_mode install; version=$2; shift 2 ;;
    --asset-dir) [ $# -ge 2 ] || die 2 "--asset-dir needs a directory"; asset_dir=$2; shift 2 ;;
    --rollback) set_mode rollback; shift ;;
    --uninstall) set_mode uninstall; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$mode" ] || { usage >&2; exit 2; }
if [ "$mode" = install ]; then
  [ -n "$manifest" ] && [ -n "$version" ] && die 2 "use --manifest or --version, not both"
else
  [ -z "$asset_dir" ] || die 2 "--asset-dir only applies to an install"
fi

# --- roots ----------------------------------------------------------------------
[ -n "${HOME:-}" ] || die 2 "HOME is not set"
case "$HOME" in /*) ;; *) die 2 "HOME must be an absolute path" ;; esac
[ -d "$HOME" ] || die 2 "HOME does not exist: $HOME"
home_phys=$(cd "$HOME" && pwd -P)

# resolve_root NAME PATH: validate an install root and print its physical absolute path.
resolve_root() {
  _n=$1 _p=$2
  case "$_p" in /*) ;; *) die 2 "$_n must be an absolute path: $_p" ;; esac
  if [ "$(printf '%s' "$_p" | LC_ALL=C tr -d '\001-\037\177' | wc -c)" -ne "$(printf '%s' "$_p" | wc -c)" ]; then
    die 2 "$_n must not contain control characters"
  fi
  while [ "$_p" != / ] && [ "${_p%/}" != "$_p" ]; do _p=${_p%/}; done
  [ "$_p" != / ] || die 2 "$_n must not be /"
  case "$_p/" in */./*|*/../*|*//*) die 2 "$_n must not contain '.', '..' or '//' segments: $_p" ;; esac
  [ ! -L "$_p" ] || die 2 "$_n must not be a symlink: $_p"
  if [ -e "$_p" ] && [ ! -d "$_p" ]; then die 2 "$_n exists and is not a directory: $_p"; fi
  _anc=$_p _rest=""
  while [ ! -d "$_anc" ]; do
    [ ! -L "$_anc" ] || die 2 "$_n has a dangling symlink component: $_anc"
    _rest="/${_anc##*/}$_rest"; _anc=${_anc%/*}; [ -n "$_anc" ] || _anc=/
  done
  _base=$(cd "$_anc" && pwd -P)
  [ "$_base" != / ] || _base=""
  _phys="$_base$_rest"
  [ -n "$_phys" ] || die 2 "$_n must not be /"
  [ "$_phys" != "$home_phys" ] || die 2 "$_n must not be HOME itself: $_phys"
  case "$home_phys/" in "$_phys"/*) die 2 "$_n must not be an ancestor of HOME: $_phys" ;; esac
  case "$_phys/" in "$hub_root"/*) die 2 "$_n must not be inside this repository: $_phys" ;; esac
  printf '%s\n' "$_phys"
}

xdg=${XDG_DATA_HOME:-}
case "$xdg" in /*) ;; *) xdg="$HOME/.local/share" ;; esac
H=$(resolve_root LUUNA_SUITE_HOME "${LUUNA_SUITE_HOME:-$xdg/luuna-suite}") || exit $?
B=$(resolve_root LUUNA_SUITE_BIN "${LUUNA_SUITE_BIN:-$HOME/.local/bin}") || exit $?
[ "$H" != "$B" ] || die 2 "LUUNA_SUITE_HOME and LUUNA_SUITE_BIN must differ"
case "$B/" in "$H"/*) die 2 "LUUNA_SUITE_BIN must not be inside LUUNA_SUITE_HOME" ;; esac
case "$H/" in "$B"/*) die 2 "LUUNA_SUITE_HOME must not be inside LUUNA_SUITE_BIN" ;; esac

# --- cleanup and lock ---------------------------------------------------------------
STAGE=""; LOCKED=0; CREATED_DIRS=""; CREATED_MARKER=0
# Commit journal: TXN is none, active or done. See txn_begin/txn_undo.
TXN=none; TXN_DIR=""; NEW_DEST=""; HAD_OLD=0; VERSIONS_CREATED=0; UNDONE=0; UNDO_FAILED=0
cleanup() {
  _rc=$?
  trap - EXIT
  trap '' HUP INT TERM
  [ -z "$STAGE" ] || rm -rf "$STAGE" || :
  if [ "$_rc" -ne 0 ] && [ "$TXN" = active ] && [ "$LOCKED" = 1 ]; then txn_undo; fi
  if [ "$LOCKED" = 1 ]; then
    for _t in "$H"/.tmp.* "$H"/.trash.*; do
      # Keep the journal when undo failed, so the backups survive for inspection; the next
      # locked run sweeps it.
      if [ "$UNDO_FAILED" = 1 ] && [ "$_t" = "$TXN_DIR" ]; then continue; fi
      if [ -e "$_t" ]; then rm -rf "$_t" || :; fi
    done
  fi
  _undo_ok=0
  if [ "$_rc" -ne 0 ] && [ "$TXN" != done ] && { [ "$TXN" = none ] || [ "$UNDONE" = 1 ]; }; then _undo_ok=1; fi
  if [ "$_undo_ok" = 1 ] && [ "$LOCKED" = 1 ] && [ "$CREATED_MARKER" = 1 ]; then rm -f "$H/$MARKER_NAME" || :; fi
  [ "$LOCKED" = 0 ] || rm -rf "$H/.lock" || :
  if [ "$_undo_ok" = 1 ] && [ -n "$CREATED_DIRS" ]; then
    # Remove the directories this run created, deepest first; rmdir only removes empty ones.
    while IFS= read -r _d; do
      if [ -n "$_d" ]; then rmdir "$_d" 2>/dev/null || true; fi
    done <<EOF
$CREATED_DIRS
EOF
  fi
  exit "$_rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# mkdir_tracked DIR: create DIR and missing ancestors, remembering them for failure cleanup.
mkdir_tracked() {
  _todo="" _d=$1
  while [ ! -d "$_d" ]; do
    [ ! -e "$_d" ] && [ ! -L "$_d" ] || die 6 "cannot create $_d: a non-directory is in the way"
    _todo="$_d
$_todo"
    _d=${_d%/*}; [ -n "$_d" ] || _d=/
  done
  # Shallowest first; CREATED_DIRS keeps deepest first for cleanup. Paths may contain spaces.
  # A concurrent run may create the same directory: tolerate that, but only remember the
  # directories this process actually created.
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    if mkdir "$_d" 2>/dev/null; then
      CREATED_DIRS="$_d
$CREATED_DIRS"
    elif [ ! -d "$_d" ] || [ -L "$_d" ]; then
      die 6 "cannot create $_d"
    fi
  done <<EOF
$_todo
EOF
}

acquire_lock() {
  mkdir "$H/.lock" 2>/dev/null || die 8 "another install appears to be running ($H/.lock exists). If none is, remove that directory and retry."
  LOCKED=1
  printf '%s\n' "$$" > "$H/.lock/pid"
}

marker_ok() { [ -f "$H/$MARKER_NAME" ] && [ ! -L "$H/$MARKER_NAME" ] && [ "$(cat "$H/$MARKER_NAME")" = "$MARKER_TEXT" ]; }

# home_unclaimed: LUUNA_SUITE_HOME holds nothing except, possibly, another run's .lock.
home_unclaimed() {
  for _e in "$H"/* "$H"/.[!.]* "$H"/..?*; do
    [ -e "$_e" ] || [ -L "$_e" ] || continue
    [ "${_e##*/}" = .lock ] || return 1
  done
  return 0
}

# check_receipt_roots: refuse (exit 6) unless receipt.tsv was written for these exact roots.
check_receipt_roots() {
  if [ ! -e "$H/receipt.tsv" ] && [ ! -L "$H/receipt.tsv" ]; then
    if [ -e "$H/current" ] || [ -L "$H/current" ]; then die 6 "refusing: $H has a current version but no receipt.tsv"; fi
    return 0
  fi
  [ -f "$H/receipt.tsv" ] && [ ! -L "$H/receipt.tsv" ] || die 6 "refusing: $H/receipt.tsv is not a regular file"
  [ "$(sed -n 1p "$H/receipt.tsv")" = "luuna-suite-receipt${TAB}1" ] || die 6 "refusing: unrecognized receipt"
  [ "$(receipt_field home)" = "$H" ] || die 6 "refusing: receipt was written for home $(receipt_field home)"
  [ "$(receipt_field bin)" = "$B" ] || die 6 "refusing: receipt was written for LUUNA_SUITE_BIN=$(receipt_field bin); rerun with that value (or uninstall with it first)"
}

# check_home_entries: refuse (exit 6) if LUUNA_SUITE_HOME holds anything this installer does not create.
check_home_entries() {
  for _e in "$H"/* "$H"/.[!.]* "$H"/..?*; do
    [ -e "$_e" ] || [ -L "$_e" ] || continue
    _n=${_e##*/}
    case "$_n" in
      "$MARKER_NAME"|receipt.tsv|current|previous)
        [ -f "$_e" ] && [ ! -L "$_e" ] || die 6 "refusing: $_e is not a regular file" ;;
      versions) [ -d "$_e" ] && [ ! -L "$_e" ] || die 6 "refusing: $_e is not a real directory" ;;
      .lock) ;;
      .stage.*|.trash.*|.tmp.*) [ ! -L "$_e" ] || die 6 "refusing: unexpected symlink $_e" ;;
      *) die 6 "refusing: $_e was not created by this installer (remove it or choose another LUUNA_SUITE_HOME)" ;;
    esac
  done
  [ -d "$H/versions" ] || return 0
  for _e in "$H/versions"/* "$H/versions"/.[!.]* "$H/versions"/..?*; do
    [ -e "$_e" ] || [ -L "$_e" ] || continue
    manifest_is_version "${_e##*/}" && [ -d "$_e" ] && [ ! -L "$_e" ] || die 6 "refusing: unexpected entry $_e"
  done
}

# read_pointer NAME: print the version named by $H/NAME (empty if absent).
read_pointer() {
  _f="$H/$1"
  [ -e "$_f" ] || [ -L "$_f" ] || return 0
  [ -f "$_f" ] && [ ! -L "$_f" ] || die 6 "refusing: $_f is not a regular file"
  _v=$(cat "$_f")
  manifest_is_version "$_v" || die 6 "refusing: $_f does not name a version"
  [ -d "$H/versions/$_v/bin" ] && [ ! -L "$H/versions/$_v" ] || die 6 "refusing: $_f names a missing version: $_v"
  printf '%s\n' "$_v"
}

# replace_file SRC DEST: rename SRC over DEST. DEST must be absent or a regular non-symlink file.
replace_file() {
  if [ -L "$2" ] || { [ -e "$2" ] && [ ! -f "$2" ]; }; then die 6 "refusing to replace $2: not a regular file"; fi
  chmod 644 "$1"
  mv -f "$1" "$2"
}
write_pointer() { # NAME VERSION|""
  if [ -z "$2" ]; then
    if [ -L "$H/$1" ] || { [ -e "$H/$1" ] && [ ! -f "$H/$1" ]; }; then die 6 "refusing to remove $H/$1"; fi
    rm -f "$H/$1"; return 0
  fi
  _t=$(mktemp "$H/.tmp.XXXXXX")
  printf '%s\n' "$2" > "$_t"
  replace_file "$_t" "$H/$1"
}

# bin_state PATH: 0 if free, 1 if a link owned by this install, 2 if anything else (conflict).
bin_state() {
  if [ -L "$1" ]; then
    _t=$(readlink "$1")
    case "$_t" in *"/../"*|*"/./"*) return 2 ;; esac
    case "$_t" in "$H"/versions/*/bin/*) [ ! -d "$1" ] || return 2; return 1 ;; esac
    return 2
  fi
  [ ! -e "$1" ] || return 2
  return 0
}
preflight_bins() { # NAME...
  for _n in "$@"; do
    _st=0; bin_state "$B/$_n" || _st=$?
    [ "$_st" -ne 2 ] || die 6 "refusing to replace $B/$_n: it exists and was not installed by the Luuna suite installer"
  done
}
link_bin() { # NAME TARGET
  _l="$B/$1"
  _st=0; bin_state "$_l" || _st=$?
  [ "$_st" -ne 2 ] || die 6 "refusing to replace $_l: not owned by the Luuna suite installer"
  if [ "$_st" = 1 ] && [ "$(readlink "$_l")" = "$2" ]; then return 0; fi
  _tmp="$B/.luuna-suite.tmp.$$.$1"
  ln -s "$2" "$_tmp" || die 6 "cannot create a temporary link in $B"
  # Re-check right before the rename to narrow the window for a racing writer (see header).
  _st=0; bin_state "$_l" || _st=$?
  if [ "$_st" = 2 ]; then rm -f "$_tmp"; die 6 "refusing to replace $_l: not owned by the Luuna suite installer"; fi
  mv -f "$_tmp" "$_l"
}
# relink VERSION: point every executable of VERSION at its bin link and drop stale owned links.
relink() {
  [ -d "$B" ] || mkdir_tracked "$B"
  for _f in "$H/versions/$1/bin"/*; do
    [ -f "$_f" ] || continue
    link_bin "${_f##*/}" "$_f"
  done
  for _n in $PUBLIC_NAMES; do
    [ ! -f "$H/versions/$1/bin/$_n" ] || continue
    _st=0; bin_state "$B/$_n" || _st=$?
    [ "$_st" != 1 ] || rm -f "$B/$_n"
  done
}
version_bins() { # VERSION -> names
  for _f in "$H/versions/$1/bin"/*; do if [ -f "$_f" ]; then printf '%s ' "${_f##*/}"; fi; done
}

write_receipt() { # CURRENT PREVIOUS
  _t=$(mktemp "$H/.tmp.XXXXXX")
  {
    printf 'luuna-suite-receipt\t1\n'
    printf 'home\t%s\n' "$H"
    printf 'bin\t%s\n' "$B"
    printf 'current\t%s\n' "$1"
    printf 'previous\t%s\n' "${2:--}"
    for _f in "$H/versions/$1/bin"/*; do
      if [ -f "$_f" ]; then printf 'link\t%s\t%s\n' "${_f##*/}" "$_f"; fi
    done
    sed 1d "$H/versions/$1/$VERSION_META"
  } > "$_t"
  replace_file "$_t" "$H/receipt.tsv"
}
receipt_field() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$H/receipt.tsv"; }

# --- commit journal -------------------------------------------------------------------
# txn_begin: under the lock and before the first visible mutation, back up current, previous and
# receipt.tsv and record the state of every public bin name. Install sets NEW_DEST, HAD_OLD and
# VERSIONS_CREATED first. A failure in here is still a pre-mutation failure.
txn_begin() {
  TXN_DIR=$(mktemp -d "$H/.trash.XXXXXX")
  for _f in current previous receipt.tsv; do
    if [ -e "$H/$_f" ] || [ -L "$H/$_f" ]; then
      [ -f "$H/$_f" ] && [ ! -L "$H/$_f" ] || die 6 "refusing: $H/$_f is not a regular file"
      cp -p "$H/$_f" "$TXN_DIR/$_f"
    else
      : > "$TXN_DIR/$_f.absent"
    fi
  done
  : > "$TXN_DIR/links.tsv"
  for _n in $PUBLIC_NAMES; do
    _st=0; bin_state "$B/$_n" || _st=$?
    case "$_st" in
      0) printf '%s\tabsent\n' "$_n" >> "$TXN_DIR/links.tsv" ;;
      1) printf '%s\towned\t%s\n' "$_n" "$(readlink "$B/$_n")" >> "$TXN_DIR/links.tsv" ;;
    esac
  done
  TXN=active
}
txn_done() { TXN=done; }

# txn_undo: replay the journal. Runs from cleanup under set -e, so every step is non-fatal and
# nothing here calls die (or a helper that does).
txn_undo() {
  # Temporary links this process may have left in the bin directory.
  for _ul in "$B"/.luuna-suite.tmp."$$".*; do
    if [ -L "$_ul" ]; then rm -f "$_ul" || UNDO_FAILED=1; fi
  done
  if [ -f "$TXN_DIR/links.tsv" ]; then
    while IFS="$TAB" read -r _un _us _ut; do
      [ -n "$_un" ] || continue
      _ucur=0; bin_state "$B/$_un" || _ucur=$?
      if [ "$_ucur" = 2 ]; then say "left $B/$_un in place: not owned by this install"; continue; fi
      case "$_us" in
        absent)
          if [ "$_ucur" = 1 ]; then rm -f "$B/$_un" || UNDO_FAILED=1; fi ;;
        owned)
          if [ "$_ucur" = 0 ] || [ "$(readlink "$B/$_un")" != "$_ut" ]; then
            _uu="$B/.luuna-suite.tmp.$$.undo.$_un"
            rm -f "$_uu" || :
            { ln -s "$_ut" "$_uu" && mv -f "$_uu" "$B/$_un"; } || UNDO_FAILED=1
          fi ;;
        *) UNDO_FAILED=1 ;;
      esac
    done < "$TXN_DIR/links.tsv"
  else
    UNDO_FAILED=1
  fi
  for _uf in current previous receipt.tsv; do
    _ud="$H/$_uf"
    if [ -f "$TXN_DIR/$_uf" ]; then
      if [ -L "$_ud" ] || { [ -e "$_ud" ] && [ ! -f "$_ud" ]; }; then UNDO_FAILED=1
      else mv -f "$TXN_DIR/$_uf" "$_ud" || UNDO_FAILED=1; fi
    elif [ -e "$TXN_DIR/$_uf.absent" ]; then
      if [ -L "$_ud" ]; then UNDO_FAILED=1
      elif [ -f "$_ud" ]; then rm -f "$_ud" || UNDO_FAILED=1
      elif [ -e "$_ud" ]; then UNDO_FAILED=1; fi
    else
      UNDO_FAILED=1
    fi
  done
  if [ -n "$NEW_DEST" ]; then
    # Decide from the filesystem, not from flags, so an interruption between a rename and a
    # flag update cannot make undo move the wrong directory.
    if [ "$HAD_OLD" = 1 ]; then
      if [ -d "$TXN_DIR/old-version" ]; then
        if [ -d "$NEW_DEST" ] && [ ! -L "$NEW_DEST" ]; then mv "$NEW_DEST" "$TXN_DIR/new-version" || UNDO_FAILED=1; fi
        if [ -e "$NEW_DEST" ] || [ -L "$NEW_DEST" ]; then UNDO_FAILED=1
        else mv "$TXN_DIR/old-version" "$NEW_DEST" || UNDO_FAILED=1; fi
      fi
    elif [ -d "$NEW_DEST" ] && [ ! -L "$NEW_DEST" ]; then
      mv "$NEW_DEST" "$TXN_DIR/new-version" || UNDO_FAILED=1
    fi
    if [ "$VERSIONS_CREATED" = 1 ] && [ -d "$H/versions" ]; then rmdir "$H/versions" 2>/dev/null || :; fi
  fi
  if [ "$UNDO_FAILED" = 0 ]; then
    UNDONE=1
    say "restored the previous installation"
  else
    say "could not fully restore the previous installation; rerun install or --rollback (backups kept in $TXN_DIR)"
  fi
}

gc_versions() { # KEEP...
  for _e in "$H/versions"/*; do
    [ -d "$_e" ] && [ ! -L "$_e" ] || continue
    _n=${_e##*/}
    case " $* " in *" $_n "*) continue ;; esac
    if manifest_is_version "$_n"; then rm -rf "$_e"; fi
  done
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'
  else die 2 "need sha256sum or shasum"; fi
}

fetch() { # URL DEST
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -q -O "$2" "$1"
  else
    echo "$PROG: neither curl nor wget is available" >&2; return 1
  fi
}

# inspect_archive ARCHIVE EXE...: allow-list the listing before anything is extracted.
inspect_archive() {
  _a=$1; shift
  _names=$(tar -tzf "$_a" 2>/dev/null) || { echo "cannot list archive" >&2; return 1; }
  _verbose=$(tar -tzvf "$_a" 2>/dev/null) || { echo "cannot list archive" >&2; return 1; }
  [ -n "$_names" ] || { echo "empty archive" >&2; return 1; }
  if [ "$(printf '%s\n' "$_names" | wc -l)" -ne "$(printf '%s\n' "$_verbose" | wc -l)" ]; then
    echo "ambiguous archive listing" >&2; return 1
  fi
  if [ -n "$(printf '%s\n' "$_names" | sort | uniq -d)" ]; then echo "duplicate entries" >&2; return 1; fi
  while IFS= read -r _entry; do
    case "$_entry" in
      bin|bin/) continue ;;
    esac
    _hit=0
    for _x in "$@"; do [ "$_entry" != "bin/$_x" ] || _hit=1; done
    [ "$_hit" = 1 ] || { echo "unexpected entry: $_entry" >&2; return 1; }
  done <<EOF
$_names
EOF
  for _x in "$@"; do
    printf '%s\n' "$_names" | grep -Fx -e "bin/$_x" >/dev/null || { echo "missing executable: bin/$_x" >&2; return 1; }
  done
  # Only regular files and directories: no symlinks, hardlinks, devices, fifos.
  printf '%s\n' "$_verbose" | awk '
    { c = substr($0, 1, 1); if ((c != "-" && c != "d") || index($0, " -> ") || index($0, " link to ")) bad = 1 }
    END { exit bad }' || { echo "archive contains links or special files" >&2; return 1; }
}

detect_platform() {
  _s=${LUUNA_SUITE_UNAME_S:-$(uname -s)}
  _m=${LUUNA_SUITE_UNAME_M:-$(uname -m)}
  case "$_s" in
    Darwin) OS=darwin ;;
    Linux) OS=linux ;;
    *) die 3 "unsupported platform: $_s/$_m. The public installer supports macOS and Linux on x86_64 and arm64. Windows is not supported." ;;
  esac
  case "$_m" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) die 3 "unsupported platform: $_s/$_m (supported architectures: x86_64, arm64)" ;;
  esac
}

# --- uninstall --------------------------------------------------------------------
do_uninstall() {
  if [ ! -e "$H" ]; then say "nothing installed at $H"; exit 0; fi
  marker_ok || die 6 "refusing: $H has no Luuna suite marker ($MARKER_NAME); not removing it"
  [ -f "$H/receipt.tsv" ] && [ ! -L "$H/receipt.tsv" ] || die 6 "refusing: $H has no receipt.tsv; remove it manually after checking its contents"
  check_receipt_roots
  check_home_entries
  _links=$(awk -F '\t' '$1 == "link" { print $2 }' "$H/receipt.tsv")
  if [ "$dry_run" = 1 ]; then
    for _n in $_links; do say "would remove link $B/$_n"; done
    say "would remove $H"; exit 0
  fi
  acquire_lock
  for _n in $_links; do
    case " $PUBLIC_NAMES " in *" $_n "*) ;; *) say "skipping non-public receipt entry: $_n"; continue ;; esac
    _st=0; bin_state "$B/$_n" || _st=$?
    if [ "$_st" = 1 ]; then rm -f "$B/$_n"; say "removed $B/$_n"
    elif [ "$_st" = 2 ]; then say "left $B/$_n in place: not owned by this install"; fi
  done
  if [ -d "$H/versions" ]; then
    for _e in "$H/versions"/*; do
      if [ -d "$_e" ] && [ ! -L "$_e" ] && manifest_is_version "${_e##*/}"; then rm -rf "$_e"; fi
    done
    rmdir "$H/versions"
  fi
  for _e in "$H"/.stage.* "$H"/.trash.* "$H"/.tmp.*; do if [ -e "$_e" ]; then rm -rf "$_e"; fi; done
  rm -f "$H/receipt.tsv" "$H/current" "$H/previous" "$H/$MARKER_NAME"
  rm -rf "$H/.lock"; LOCKED=0
  rmdir "$H" || die 6 "could not remove $H (not empty)"
  say "uninstalled; project stores (.luuna/) were not touched"
  exit 0
}

# --- rollback -----------------------------------------------------------------------
do_rollback() {
  [ -d "$H" ] && marker_ok || die 2 "nothing installed at $H"
  check_home_entries
  check_receipt_roots
  _cur=$(read_pointer current) || exit $?
  _prev=$(read_pointer previous) || exit $?
  [ -n "$_cur" ] || die 2 "nothing installed at $H"
  [ -n "$_prev" ] || die 2 "no previous version to roll back to"
  # shellcheck disable=SC2046
  preflight_bins $(version_bins "$_prev")
  if [ "$dry_run" = 1 ]; then say "would roll back from $_cur to $_prev"; exit 0; fi
  acquire_lock
  # Authoritative checks, under the lock.
  marker_ok || die 6 "refusing: $H has no Luuna suite marker ($MARKER_NAME)"
  check_home_entries
  check_receipt_roots
  _cur=$(read_pointer current) || exit $?
  _prev=$(read_pointer previous) || exit $?
  [ -n "$_cur" ] || die 2 "nothing installed at $H"
  [ -n "$_prev" ] || die 2 "no previous version to roll back to"
  # shellcheck disable=SC2046
  preflight_bins $(version_bins "$_prev")
  txn_begin
  write_pointer previous "$_cur"
  write_pointer current "$_prev"
  relink "$_prev"
  write_receipt "$_prev" "$_cur"
  txn_done
  say "rolled back: current $_prev, previous $_cur"
  exit 0
}

[ "$mode" != uninstall ] || do_uninstall
[ "$mode" != rollback ] || do_rollback

# --- install ------------------------------------------------------------------------
if [ -n "$version" ]; then
  manifest_is_version "$version" || die 2 "invalid suite version: $version"
  manifest="$hub_root/releases/$version/manifest.tsv"
  [ -f "$manifest" ] || die 2 "no published manifest for suite version $version (expected releases/$version/manifest.tsv). No suite releases are published yet; see docs/RELEASING.md."
  _want=$(awk -F '\t' -v v="$version" '$1 == v { print $2; exit }' "$hub_root/releases/INDEX.tsv")
  [ -n "$_want" ] || die 2 "suite version $version is not listed in releases/INDEX.tsv"
  [ "$(sha256_of "$manifest")" = "$_want" ] || die 2 "releases/$version/manifest.tsv does not match its INDEX.tsv hash"
fi
[ -f "$manifest" ] || die 2 "manifest not found: $manifest"
manifest_validate "$manifest" || die 2 "invalid manifest: $manifest"
suite_v=$(manifest_suite "$manifest")
[ -z "$version" ] || [ "$suite_v" = "$version" ] || die 2 "manifest suite version $suite_v does not match $version"
if [ -n "$asset_dir" ]; then
  [ -d "$asset_dir" ] || die 2 "--asset-dir is not a directory: $asset_dir"
  asset_dir=$(cd "$asset_dir" && pwd -P)
fi

detect_platform
rows=$(manifest_select "$manifest" "$OS" "$ARCH") || die 3 "unsupported platform: release $suite_v has no complete set of assets for $OS/$ARCH"
all_exes="luuna-suite $(printf '%s\n' "$rows" | awk -F '\t' '{ gsub(",", " ", $9); printf "%s ", $9 }')"
[ -f "$script_dir/luuna-suite" ] || die 2 "dispatcher missing: $script_dir/luuna-suite"

old_cur=""; old_prev=""
if [ -e "$H" ]; then
  # Read-only preflight, so --dry-run and early refusals write nothing. The checks repeated
  # under the lock below are the authoritative ones.
  if marker_ok; then
    check_home_entries
    check_receipt_roots
    old_cur=$(read_pointer current) || exit $?
    old_prev=$(read_pointer previous) || exit $?
  elif ! home_unclaimed; then
    die 6 "refusing: $H exists, is not empty, and has no Luuna suite marker"
  fi
fi
# shellcheck disable=SC2086
preflight_bins $all_exes

if [ "$old_cur" = "$suite_v" ]; then say "suite $suite_v is already the current version"; exit 0; fi

if [ "$dry_run" = 1 ]; then
  say "dry run: suite $suite_v for $OS/$ARCH into $H (links in $B)"
  printf '%s\n' "$rows" | while IFS="$TAB" read -r _k _c _cv _o _a _u _s _f _x; do
    if [ -n "$asset_dir" ]; then _src="$asset_dir/$_f"; else _src=$_u; fi
    say "would install $_c $_cv ($_x) from $_src"
  done
  say "would link: $all_exes"
  exit 0
fi

# Writes begin here.
if [ ! -d "$H" ]; then mkdir_tracked "$H"; fi
# Lock first: only the lock holder may claim the home by writing the marker.
acquire_lock
if ! marker_ok; then
  home_unclaimed || die 6 "refusing: $H exists, is not empty, and has no Luuna suite marker"
  printf '%s\n' "$MARKER_TEXT" > "$H/$MARKER_NAME"
  CREATED_MARKER=1
fi
for _e in "$H"/.stage.* "$H"/.trash.* "$H"/.tmp.*; do if [ -e "$_e" ]; then rm -rf "$_e"; fi; done
check_home_entries
check_receipt_roots
old_cur=$(read_pointer current) || exit $?
old_prev=$(read_pointer previous) || exit $?
if [ "$old_cur" = "$suite_v" ]; then say "suite $suite_v is already the current version"; exit 0; fi
# shellcheck disable=SC2086
preflight_bins $all_exes

STAGE=$(mktemp -d "$H/.stage.XXXXXX")
mkdir "$STAGE/bin" "$STAGE/dl"
printf 'luuna-suite-version\t1\nsuite\t%s\n' "$suite_v" > "$STAGE/$VERSION_META"
while IFS="$TAB" read -r _k comp cver os arch url sha file exes; do
  dl="$STAGE/dl/$file"
  if [ -n "$asset_dir" ]; then
    src="$asset_dir/$file"
    [ -f "$src" ] && [ ! -L "$src" ] || die 7 "asset not found in --asset-dir: $file"
    cp "$src" "$dl" || die 7 "cannot read asset: $src"
  else
    case "$url" in https://*) ;; *) die 2 "refusing non-https url: $url" ;; esac
    say "fetching $url"
    fetch "$url" "$dl" || die 7 "download failed: $url"
  fi
  got=$(sha256_of "$dl")
  [ "$got" = "$sha" ] || die 4 "checksum mismatch for $file: expected $sha, got $got"
  exe_list=$(printf '%s' "$exes" | tr ',' ' ')
  # shellcheck disable=SC2086
  why=$(inspect_archive "$dl" $exe_list 2>&1) || die 5 "unsafe archive $file: $why"
  x="$STAGE/x.$comp"
  mkdir "$x"
  tar -xozf "$dl" -C "$x" 2>/dev/null || die 5 "cannot extract $file"
  count=$(find "$x" -print | wc -l | tr -d ' ')
  # shellcheck disable=SC2086
  set -- $exe_list
  [ "$count" -eq $(($# + 2)) ] || die 5 "unsafe archive $file: extraction produced unexpected paths"
  for exe in $exe_list; do
    f="$x/bin/$exe"
    [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ] || die 5 "unsafe archive $file: bin/$exe is not a regular executable file"
    [ ! -e "$STAGE/bin/$exe" ] || die 5 "duplicate executable across components: $exe"
    mv "$f" "$STAGE/bin/$exe"
    chmod 755 "$STAGE/bin/$exe"
  done
  rm -rf "$x" "$dl"
  printf 'component\t%s\t%s\t%s\t%s\t%s\t%s\n' "$comp" "$cver" "$os" "$arch" "$sha" "$exes" >> "$STAGE/$VERSION_META"
  say "verified $comp $cver"
done <<EOF
$rows
EOF
cp "$script_dir/luuna-suite" "$STAGE/bin/luuna-suite"
chmod 755 "$STAGE/bin/luuna-suite"
rmdir "$STAGE/dl"

# Swap: everything staged and verified. Journal first, so any failure below is undone.
NEW_DEST="$H/versions/$suite_v"
if [ -e "$NEW_DEST" ] || [ -L "$NEW_DEST" ]; then
  [ -d "$NEW_DEST" ] && [ ! -L "$NEW_DEST" ] || die 6 "refusing: $NEW_DEST is not a real directory"
  HAD_OLD=1
fi
[ -d "$H/versions" ] || VERSIONS_CREATED=1
txn_begin
[ "$VERSIONS_CREATED" = 0 ] || mkdir "$H/versions"
[ "$HAD_OLD" = 0 ] || mv "$NEW_DEST" "$TXN_DIR/old-version"
mv "$STAGE" "$NEW_DEST"
STAGE=""
new_prev=$old_cur
write_pointer previous "$new_prev"
write_pointer current "$suite_v"
relink "$suite_v"
write_receipt "$suite_v" "$new_prev"
txn_done
# Committed. Garbage collection must not undo it or turn it into a failure.
# shellcheck disable=SC2086
gc_versions "$suite_v" $new_prev || say "warning: could not remove old versions under $H/versions"
say "installed suite $suite_v (${new_prev:+previous $new_prev; }links in $B)"
case ":$PATH:" in *":$B:"*) ;; *) say "note: $B is not on PATH" ;; esac
