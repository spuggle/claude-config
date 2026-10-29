#!/usr/bin/env bash
# Open-items store, thin shim over kb. Same CLI as before:
# state.sh [-f FILE] validate | add ... | set ID [--title T ...] | close ID [--date D] | show ID | list [--all] | search REGEX | render
# kb mode (no -f, or FILE in a docs/ directory whose kb/ holds setup.json, e.g. -f docs/state.json beside docs/kb/): data is
# docs/kb/setup.json (setup/items). FILE itself need not exist (this repo has no docs/state.json since plan step 9) and is never
# created. Writes go to kb only; reads export the items to a temp state.json and reuse state-legacy.sh, so output is identical.
# Any other FILE (a project-level state.json, a fixture) is a plain legacy state.json handled entirely by state-legacy.sh.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
DIR="$(dirname "$SELF")"
LEGACY="$DIR/state-legacy.sh"
FILE="${STATE_FILE:-}"
if [ "${1:-}" = "-f" ]; then FILE="${2:-}"; shift 2 || { echo "state: -f needs a file" >&2; exit 2; }; fi
DEFAULT_STORE=
if [ -z "$FILE" ]; then
  top="$(git -C "$DIR" rev-parse --show-toplevel)"
  # like kb: the sibling claude worktree holds the live store; never read or write main's copy
  if [ -f "$top-worktrees/claude/docs/kb/setup.json" ]; then top="$top-worktrees/claude"; else DEFAULT_STORE=1; fi
  FILE="$top/docs/state.json"
fi

FDIR="$(dirname "$FILE")"; KBDIR="$FDIR/kb"
if [ "$(basename "$(cd "$FDIR" 2>/dev/null && pwd)")" != docs ] || [ ! -f "$KBDIR/setup.json" ]; then STATE_SELF="$SELF" exec bash "$LEGACY" -f "$FILE" "$@"; fi

KB="$DIR/kb"
if [ -n "$DEFAULT_STORE" ]; then unset KB_DIR; else export KB_DIR="$KBDIR"; fi
ITEMS=setup/items
die() { echo "state: $*" >&2; exit 1; }
run_kb() { "$KB" "$@" >/dev/null 2>"$tmp/err" || { sed 's/^kb: /state: /' "$tmp/err" >&2; exit 1; }; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export_to() { # only setup/items, in file (seq) order
  "$KB" export-state | jq --slurpfile k "$KBDIR/setup.json" '.items |= map(select(.id as $i | $k[0].items | has($i)))' > "$tmp/state.json" || exit 1
}
body_args() { # DETAIL -> BODY array, split on every newline (trailing one kept)
  BODY=(); local s="$1"
  while [[ "$s" == *$'\n'* ]]; do BODY+=(--body "${s%%$'\n'*}"); s="${s#*$'\n'}"; done
  BODY+=(--body "$s")
}
need_id() { export_to; jq -e --arg id "$1" '.items | any(.id == $id)' "$tmp/state.json" >/dev/null || die "$1: unknown id"; }
need_kind() { case "$1" in user-action|waiting|backlog) ;; *) die "$2: kind must be user-action, waiting or backlog" ;; esac; }
is_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" +%F >/dev/null 2>&1; }
legacy() { STATE_SELF="$SELF" STATE_LABEL="$FILE" bash "$LEGACY" -f "$tmp/state.json" "$@"; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
validate)
  if ! o="$("$KB" validate 2>&1)"; then echo "$o" >&2; exit 1; fi
  export_to; legacy validate ;;
list|show|search|render)
  export_to; legacy "$cmd" "$@" ;;
add)
  id='' kind='' title='' area='' detail='' prio='' opened=''
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --id) id="$2" ;; --kind) kind="$2" ;; --title) title="$2" ;; --area) area="$2" ;;
      --detail) detail="$2" ;; --priority) prio="$2" ;; --opened) opened="$2" ;;
      *) die "add: unknown option $1" ;;
    esac; shift 2
  done
  [ -n "$id" ] || die "add: --id required"
  [ -z "$prio" ] || [[ "$prio" =~ ^-?[0-9]+$ ]] || die "$id: priority must be an integer"
  need_kind "$kind" "$id"
  [ -z "$opened" ] || is_date "$opened" || die "$id: opened must be YYYY-MM-DD"
  export_to; ! jq -e --arg id "$id" '.items | any(.id == $id)' "$tmp/state.json" >/dev/null || die "$id: duplicate id"
  body_args "$detail"
  args=(add "$ITEMS/$id" --type item --id "$id" --title "$title" --kind "$kind" --status open --field "area=$(jq -n --arg a "$area" '$a')" --dup-ok "${BODY[@]}")
  [ -z "$prio" ] || args+=(--priority "$prio")
  [ -z "$opened" ] || args+=(--opened "$opened")
  run_kb "${args[@]}" ;;
close)
  id="${1:-}"; [ -n "$id" ] || die "close: id required"; shift
  need_id "$id"
  args=(close "$id")
  if [ "${1:-}" = "--date" ]; then is_date "${2:-}" || die "close: bad date"; args+=(--date "$2"); fi
  run_kb "${args[@]}" ;;
set)
  id="${1:-}"; [ -n "$id" ] || die "set: id required"; shift
  need_id "$id"
  args=(set "$id")
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --title) args+=(--title "$2") ;;
      --detail) body_args "$2"; args+=("${BODY[@]}") ;;
      --kind) need_kind "$2" "$id"; args+=(--field "kind=$(jq -n --arg a "$2" '$a')") ;;
      --area) args+=(--field "area=$(jq -n --arg a "$2" '$a')") ;;
      --priority) [[ "$2" =~ ^-?[0-9]+$ ]] || die "$id: priority must be an integer"; args+=(--field "priority=$2") ;;
      *) die "set: unknown option $1" ;;
    esac; shift 2
  done
  run_kb "${args[@]}" ;;
*) echo "usage: state.sh [-f FILE] validate|add|set|close|show|list|search|render" >&2; exit 2 ;;
esac
