# Luuna suite release manifest: parse and validate (POSIX sh + awk; no jq, no Python).
# shellcheck shell=sh
#
# Format (releases/FORMAT.md), tab-separated, LF line endings, printable ASCII only:
#   luuna-suite-manifest<TAB>1
#   suite<TAB><suite-version>
#   asset<TAB><component><TAB><component-version><TAB><os><TAB><arch><TAB><https-url><TAB><sha256><TAB><archive-file-name><TAB><exe,exe>
#
# Functions (source this file; nothing runs on load):
#   manifest_validate FILE        exit 0 if valid; diagnostics on stderr
#   manifest_suite FILE           print the suite version (FILE must be valid)
#   manifest_select FILE OS ARCH  print the asset rows for OS/ARCH in manifest order; return 3 unless
#                                 all four components are present for that platform
#   manifest_component_exes COMP  print "primary alias" for a component's public executables
#   manifest_is_version STRING    exit 0 if STRING is a valid version identifier

MANIFEST_COMPONENTS="atlas beacon missions roots"

manifest_component_exes() {
  case "$1" in
    atlas) echo "luuna-atlas lat" ;;
    beacon) echo "luuna-beacon lbc" ;;
    missions) echo "luuna-missions lms" ;;
    roots) echo "luuna-roots lrt" ;;
    *) return 1 ;;
  esac
}

manifest_is_version() {
  printf '%s\n' "$1" | awk '
    NR > 1 { bad = 1 }
    END { exit (bad || NR != 1) }
    length($0) > 64 || $0 !~ /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$/ { bad = 1 }'
}

manifest_validate() {
  _mf=$1
  if [ ! -f "$_mf" ]; then echo "manifest: not a regular file: $_mf" >&2; return 1; fi
  if [ ! -s "$_mf" ]; then echo "manifest: empty file: $_mf" >&2; return 1; fi
  _cr=$(printf '\r')
  if grep "$_cr" "$_mf" >/dev/null 2>&1; then
    echo "manifest: CRLF or CR line endings are not allowed: $_mf" >&2; return 1
  fi
  # Only printable ASCII, tab and newline.
  _bad=$(LC_ALL=C tr -d '\011\012\040-\176' < "$_mf" | wc -c | tr -d ' ')
  if [ "$_bad" != 0 ]; then echo "manifest: non-printable or non-ASCII bytes: $_mf" >&2; return 1; fi
  if [ -n "$(tail -c 1 "$_mf")" ]; then echo "manifest: must end with a newline: $_mf" >&2; return 1; fi
  LC_ALL=C awk -F '\t' '
    function fail(msg) { printf "manifest: line %d: %s\n", NR, msg > "/dev/stderr"; err = 1 }
    function isver(v) { return length(v) <= 64 && v ~ /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$/ }
    BEGIN {
      allowed["atlas"] = "luuna-atlas,lat"; allowed["beacon"] = "luuna-beacon,lbc"
      allowed["missions"] = "luuna-missions,lms"; allowed["roots"] = "luuna-roots,lrt"
    }
    NR == 1 { if ($0 != "luuna-suite-manifest\t1") fail("header must be: luuna-suite-manifest<TAB>1"); next }
    NR == 2 { if (NF != 2 || $1 != "suite" || !isver($2)) fail("second line must be: suite<TAB><version>"); next }
    {
      if (NF != 9) { fail("asset row must have exactly 9 tab-separated fields"); next }
      for (i = 1; i <= 9; i++) if ($i == "") { fail("empty field " i); next }
      if ($1 != "asset") { fail("unknown row type: " $1); next }
      comp = $2; cver = $3; os = $4; arch = $5; url = $6; sha = $7; file = $8; exes = $9
      if (!(comp in allowed)) { fail("unknown component: " comp); next }
      if (!isver(cver)) fail("bad component version: " cver)
      if (os != "darwin" && os != "linux") fail("unsupported os: " os)
      if (arch != "arm64" && arch != "amd64") fail("unsupported arch: " arch)
      if (length(sha) != 64 || sha ~ /[^0-9a-f]/) fail("sha256 must be 64 lowercase hex characters")
      if (file != "luuna-" comp "_" cver "_" os "_" arch ".tar.gz") fail("archive file name must be luuna-" comp "_" cver "_" os "_" arch ".tar.gz")
      prefix = "https://github.com/brodynelly/luuna-" comp "/releases/download/"
      if (index(url, prefix) != 1) fail("url must start with " prefix)
      else {
        rest = substr(url, length(prefix) + 1)
        slash = index(rest, "/")
        tag = substr(rest, 1, slash - 1)
        if (slash < 2 || tag !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ || substr(rest, slash + 1) != file)
          fail("url must be " prefix "<tag>/" file)
      }
      n = split(exes, e, ",")
      has_primary = 0
      split(allowed[comp], ok, ",")
      for (i = 1; i <= n; i++) {
        if ((NR, e[i]) in seen) fail("duplicate executable: " e[i])
        seen[NR, e[i]] = 1
        if (e[i] != ok[1] && e[i] != ok[2]) fail("not a public executable of " comp ": " e[i])
        if (e[i] == ok[1]) has_primary = 1
      }
      if (!has_primary) fail("executables must include " ok[1])
      key = comp "/" os "/" arch
      if (key in rows) fail("duplicate asset row for " key)
      rows[key] = 1
      assets++
    }
    END {
      if (NR < 2) { printf "manifest: missing header or suite line\n" > "/dev/stderr"; err = 1 }
      else if (assets == 0) { printf "manifest: no asset rows\n" > "/dev/stderr"; err = 1 }
      exit err
    }' "$_mf"
}

manifest_suite() {
  awk -F '\t' 'NR == 2 && $1 == "suite" { print $2; exit }' "$1"
}

manifest_select() {
  _mf=$1 _os=$2 _arch=$3
  _rows=$(awk -F '\t' -v os="$_os" -v arch="$_arch" 'NR > 2 && $1 == "asset" && $4 == os && $5 == arch' "$_mf")
  for _c in $MANIFEST_COMPONENTS; do
    if ! printf '%s\n' "$_rows" | awk -F '\t' -v c="$_c" '$2 == c { found = 1 } END { exit !found }'; then
      echo "manifest: no $_c asset for $_os/$_arch" >&2
      return 3
    fi
  done
  printf '%s\n' "$_rows"
}
