#!/bin/sh
# adw-component.sh: run the tac-final ADW (adw.sh) inside exactly one verified sibling component repo.
#
# Usage: adw-component.sh <atlas|beacon|missions|roots> [options] <task text...>
#        adw-component.sh <atlas|beacon|missions|roots> [options] --spec PATH
#
# Options (everything else is refused):
#   -w, --workflow NAME   plan_build | plan_build_test (default) | plan_build_review_fix
#   -s, --spec PATH       Build an existing spec (relative path inside the component repo)
#       --no-worktree     Run in the checkout itself (requires a clean tree). The default is --worktree.
#       --base REF        Worktree base commit (worktree mode only)
#       --max-fix N       Review-fix rounds, 1-10
#       --no-learn        Skip the Learn step
#       --dry-run         Pass --dry-run to adw.sh (prints the claude invocations)
#   -h, --help            Show this help
#   --                    End of options; the rest is task text
#
# Refused: --pr (commit/push/PR stay human), --issue (pulls remote content), -w sdlc, unknown options,
# and any caller-set TAC_CLAUDE_ARGS.
#
# Environment:
#   LUUNA_COMPONENTS_ROOT    Directory holding luuna-<component> checkouts (default: the hub's parent)
#   LUUNA_ADW_SCRIPT         adw.sh path (default: <hub parent>/.agents/skills/adw/scripts/adw.sh)
#   CLAUDE_BIN               Claude Code executable (default: claude); must have the tac-final plugin
#   LUUNA_ADW_MAX_TURNS      --max-turns per step, 1-200 (default 40)
#   LUUNA_ADW_ALLOWED_TOOLS  ';'-separated extra --allowedTools rules for the repo's validation commands,
#                            e.g. 'Bash(go test *);Bash(make verify)'. Characters are restricted.
#
# Security: adw.sh eval's "$CLAUDE_BIN" and $TAC_CLAUDE_ARGS. Every value that reaches them is built
# here from validated, metacharacter-free input. Task text is passed as a plain argument (adw.sh
# does not eval it).
set -eu

PROG=adw-component
die() { echo "$PROG: $*" >&2; exit 2; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

script_dir=$(cd "$(dirname "$0")" && pwd -P)
hub=$(cd "$script_dir/.." && pwd -P)
hub_parent=$(cd "$hub/.." && pwd -P)

[ $# -gt 0 ] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
component=$1; shift
case "$component" in atlas|beacon|missions|roots) ;; *) die "unknown component: $component (atlas|beacon|missions|roots)" ;; esac

# --- options ----------------------------------------------------------------------
workflow=plan_build_test; spec=""; worktree=1; base=""; max_fix=""; no_learn=0; dry_run=0; task=""
need() { [ $# -ge 2 ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -w|--workflow) need "$@"; workflow=$2; shift 2 ;;
    -s|--spec) need "$@"; spec=$2; shift 2 ;;
    --worktree) worktree=1; shift ;;
    --no-worktree) worktree=0; shift ;;
    --base) need "$@"; base=$2; shift 2 ;;
    --max-fix) need "$@"; max_fix=$2; shift 2 ;;
    --no-learn) no_learn=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --pr) die "--pr is refused: committing, pushing and opening PRs stay human" ;;
    -i|--issue) die "--issue is refused: it pulls remote issue content into the prompt (out of scope)" ;;
    --) shift; task="$*"; break ;;
    -*) die "unknown or refused option: $1" ;;
    *) task="${task:+$task }$1"; shift ;;
  esac
done

case "$workflow" in
  plan_build|plan_build_test|plan_build_review_fix) ;;
  sdlc) die "workflow sdlc is refused (it runs unattended documentation and learn steps)" ;;
  *) die "unknown workflow: $workflow" ;;
esac
if [ -n "$spec" ] && [ -n "$task" ]; then die "give either task text or --spec, not both"; fi
[ -n "$spec$task" ] || die "missing task text or --spec PATH"
if [ -n "$max_fix" ]; then
  case "$max_fix" in ''|*[!0-9]*) die "--max-fix must be an integer 1-10" ;; esac
  [ "$max_fix" -ge 1 ] && [ "$max_fix" -le 10 ] || die "--max-fix must be an integer 1-10"
fi
if [ -n "$base" ]; then
  [ "$worktree" = 1 ] || die "--base requires worktree mode (do not combine with --no-worktree)"
  case "$base" in -*|*[!A-Za-z0-9._/-]*|*..*) die "--base must be a plain ref name or commit" ;; esac
fi
if [ -n "$spec" ]; then
  case "$spec" in /*|-*|*..*|*[!A-Za-z0-9._/-]*) die "--spec must be a relative path of [A-Za-z0-9._/-] without '..'" ;; esac
fi

# --- bounds -------------------------------------------------------------------------
if [ -n "${TAC_CLAUDE_ARGS:-}" ]; then
  case "$TAC_CLAUDE_ARGS" in
    *bypassPermissions*|*dangerously*) die "refusing: TAC_CLAUDE_ARGS requests a permission bypass" ;;
  esac
  die "refusing: TAC_CLAUDE_ARGS is set by this wrapper; unset it (use LUUNA_ADW_MAX_TURNS / LUUNA_ADW_ALLOWED_TOOLS)"
fi
max_turns=${LUUNA_ADW_MAX_TURNS:-40}
case "$max_turns" in ''|*[!0-9]*) die "LUUNA_ADW_MAX_TURNS must be an integer 1-200" ;; esac
[ "${#max_turns}" -le 3 ] && [ "$max_turns" -ge 1 ] && [ "$max_turns" -le 200 ] || die "LUUNA_ADW_MAX_TURNS must be an integer 1-200"

denied='"Bash(git push)" "Bash(git push *)" "Bash(git commit)" "Bash(git commit *)" "Bash(git tag)" "Bash(git tag *)" "Bash(gh)" "Bash(gh *)" "Bash(npm publish)" "Bash(npm publish *)" "Bash(cargo publish)" "Bash(cargo publish *)" "Bash(curl *)" "Bash(wget *)"'
allowed=""
if [ -n "${LUUNA_ADW_ALLOWED_TOOLS:-}" ]; then
  rest=$LUUNA_ADW_ALLOWED_TOOLS
  while [ -n "$rest" ]; do
    rule=${rest%%;*}
    if [ "$rule" = "$rest" ]; then rest=""; else rest=${rest#*;}; fi
    [ -n "$rule" ] || continue
    case "$rule" in
      Read|Glob|Grep|Edit|Write) ;;
      "Bash("*")")
        inner=${rule#Bash(}; inner=${inner%)}
        case "$inner" in ''|\**|' '*) die "LUUNA_ADW_ALLOWED_TOOLS rule not allowed: $rule" ;; esac
        # Only letters, digits, space and ._/=:@+*- : no quotes, $, backticks, ;, |, &, <, >, (, ) or backslash.
        [ -z "$(printf '%s' "$inner" | LC_ALL=C tr -d 'A-Za-z0-9 ._/=:@+*-')" ] \
          || die "LUUNA_ADW_ALLOWED_TOOLS rule not allowed: $rule" ;;
      *) die "LUUNA_ADW_ALLOWED_TOOLS rule not allowed: $rule (use Bash(<command> ...) or Read/Glob/Grep/Edit/Write)" ;;
    esac
    allowed="$allowed \"$rule\""
  done
fi
claude_args="--permission-mode acceptEdits --max-turns $max_turns"
[ -z "$allowed" ] || claude_args="$claude_args --allowedTools$allowed"
claude_args="$claude_args --disallowedTools $denied"

# --- component repository -----------------------------------------------------------------
components_root=${LUUNA_COMPONENTS_ROOT:-$hub_parent}
case "$components_root" in /*) ;; *) die "LUUNA_COMPONENTS_ROOT must be absolute" ;; esac
candidate="$components_root/luuna-$component"
[ -d "$candidate" ] || die "component repo not found: $candidate"
repo=$(cd "$candidate" && pwd -P)
[ "$repo" != "$hub" ] || die "refusing: $candidate resolves to the hub itself"
case "$repo/" in "$hub"/*) die "refusing: $repo is inside the hub (sources/ submodules are not orchestration targets)" ;; esac
case "$repo/" in */sources/*) die "refusing: $repo is under a sources/ directory" ;; esac
command -v git >/dev/null 2>&1 || die "git is required"
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "not a git work tree: $repo"
top=$(cd "$top" && pwd -P)
[ "$top" = "$repo" ] || die "refusing: $repo is not the top of its git work tree ($top)"
super=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null || true)
[ -z "$super" ] || die "refusing: $repo is a submodule of $super"
origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || die "refusing: $repo has no origin remote"
case "$origin" in
  "https://github.com/brodynelly/luuna-$component"|"https://github.com/brodynelly/luuna-$component.git"|"git@github.com:brodynelly/luuna-$component.git") ;;
  *) die "refusing: $repo origin is $origin, expected github.com/brodynelly/luuna-$component" ;;
esac
if [ "$worktree" = 0 ] && [ -n "$(git -C "$repo" status --porcelain -- . ':!.tac' ':!.claude/worktrees')" ]; then
  die "--no-worktree needs a clean working tree in $repo"
fi
if [ -n "$spec" ]; then
  [ -f "$repo/$spec" ] || die "spec not found in $repo: $spec"
  if [ "$worktree" = 1 ] && ! git -C "$repo" ls-files --error-unmatch -- "$spec" >/dev/null 2>&1; then
    die "spec $spec is not committed; a worktree run cannot see it (commit it or use --no-worktree)"
  fi
fi
if [ -n "$base" ]; then
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "--base: unknown ref in $repo: $base"
fi

# --- adw.sh and claude ----------------------------------------------------------------------
adw=${LUUNA_ADW_SCRIPT:-$hub_parent/.agents/skills/adw/scripts/adw.sh}
case "$adw" in /*) ;; *) die "LUUNA_ADW_SCRIPT must be absolute" ;; esac
[ -f "$adw" ] && [ -r "$adw" ] || die "adw.sh not found or unreadable: $adw"
command -v bash >/dev/null 2>&1 || die "bash is required to run adw.sh"

claude=${CLAUDE_BIN:-claude}
# adw.sh evals "$claude_bin" inside double quotes: allow only [A-Za-z0-9 ._/+@,:=%~-], which are
# inert there (no ", $, `, \ or control characters).
safe_path() { [ -n "$1" ] && [ -z "$(printf '%s' "$1" | LC_ALL=C tr -d 'A-Za-z0-9 ._/+@,:=%~-')" ]; }
safe_path "$claude" || die "CLAUDE_BIN contains unsupported characters"
claude_path=$(command -v -- "$claude" 2>/dev/null) || die "Claude Code not found: $claude (install it or set CLAUDE_BIN)"
case "$claude_path" in /*) ;; *) die "CLAUDE_BIN must resolve to an executable file" ;; esac
safe_path "$claude_path" || die "resolved CLAUDE_BIN path contains unsupported characters: $claude_path"
plugins=$("$claude_path" plugin list 2>/dev/null) || die "'$claude_path plugin list' failed; cannot verify the tac-final plugin"
if ! printf '%s\n' "$plugins" | grep -E '(^|[^A-Za-z0-9_-])tac-final([^A-Za-z0-9_-]|$)' >/dev/null; then
  die "the tac-final Claude Code plugin is not installed. Install it yourself (for example: $claude_path plugin install tac-final@<marketplace>) and rerun; this wrapper never installs plugins."
fi

# --- run --------------------------------------------------------------------------------
set -- -w "$workflow"
[ "$worktree" = 0 ] || set -- "$@" --worktree
[ -z "$base" ] || set -- "$@" --base "$base"
[ -z "$max_fix" ] || set -- "$@" --max-fix "$max_fix"
[ "$no_learn" = 0 ] || set -- "$@" --no-learn
[ "$dry_run" = 0 ] || set -- "$@" --dry-run
if [ -n "$spec" ]; then set -- "$@" --spec "$spec"; else set -- "$@" -- "$task"; fi

echo "$PROG: repo      $repo ($origin)" >&2
echo "$PROG: adw       $adw" >&2
echo "$PROG: claude    $claude_path (tac-final plugin present)" >&2
echo "$PROG: workflow  $workflow$( [ "$worktree" = 1 ] && echo ', worktree' || echo ', in-place')$( [ "$dry_run" = 1 ] && echo ', dry run' || true)" >&2
echo "$PROG: bounds    $claude_args" >&2
echo "$PROG: note      adw.sh writes .tac/ in $repo; review and merge stay human" >&2

CLAUDE_BIN=$claude_path
TAC_CLAUDE_ARGS=$claude_args
export CLAUDE_BIN TAC_CLAUDE_ARGS
cd "$repo"
exec bash "$adw" "$@"
