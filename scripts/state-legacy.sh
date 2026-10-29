#!/usr/bin/env bash
# LEGACY implementation over a state.json file; scripts/state.sh delegates here for fixtures and exports.
# Open-items store (docs/state.json): validate, add, close, show, list, render.
# Usage: state.sh [-f FILE] validate | add ... | set ID [--title T ...] | close ID [--date D] | show ID | list [--all] | search REGEX | render
set -uo pipefail
SELF="${STATE_SELF:-$(readlink -f "${BASH_SOURCE[0]}")}"
FILE="${STATE_FILE:-}"
if [ "${1:-}" = "-f" ]; then FILE="${2:-}"; shift 2 || { echo "state: -f needs a file" >&2; exit 2; }; fi
[ -n "$FILE" ] || FILE="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)/docs/state.json"

die() { echo "state: $*" >&2; exit 1; }
today() { date +%F; }
is_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" +%F >/dev/null 2>&1; }

# Validation program: one "state: <id>: <problem>" line per problem.
read -r -d '' VALIDATE <<'JQ' || true
def isdate: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
if (type != "object") or ((.items // null) | type) != "array" then "state: file: top level must be {\"items\":[...]}"
else
  (.items | map(select(type == "object") | .id) | group_by(.) | map(select(length > 1) | .[0] | "state: \(.): duplicate id")[]),
  (.items | to_entries[] | .key as $i | .value |
    if type != "object" then "state: #\($i): item is not an object" else
    (if (.id | type) == "string" and (.id | test("^[a-z0-9-]+$")) then .id else "#\($i)" end) as $id |
    ( (if (.id | type) != "string" or (.id | test("^[a-z0-9-]+$") | not) then "id must be a slug [a-z0-9-]+" else empty end),
      (if ((.kind // null) | IN("user-action", "waiting", "backlog")) | not then "kind must be user-action, waiting or backlog" else empty end),
      (if (.title | type) != "string" or (.title | length) < 1 or (.title | length) > 100 or (.title | contains("\n")) then "title must be a single line of 1..100 chars" else empty end),
      (if (.detail | type) != "string" then "detail must be a string" else empty end),
      (if (.area | type) != "string" or (.area | length) == 0 then "area must be a non-empty string" else empty end),
      (if .kind == "backlog" and ((.priority | type) != "number" or .priority != (.priority | floor)) then "backlog needs an integer priority"
       elif .priority != null and ((.priority | type) != "number" or .priority != (.priority | floor)) then "priority must be an integer or null" else empty end),
      (if (.opened | isdate) | not then "opened must be YYYY-MM-DD" else empty end),
      (if .closed != null and (.closed | isdate | not) then "closed must be YYYY-MM-DD or null" else empty end),
      (if ((.status // null) | IN("open", "done")) | not then "status must be open or done"
       elif .status == "done" and .closed == null then "done requires a closed date" else empty end)
    ) | "state: \($id): \(.)" end)
end
JQ

validate_file() { # prints problems; returns 1 if any
  local out
  [ -f "$1" ] || { echo "state: file: $1 does not exist"; return 1; }
  jq -e . "$1" >/dev/null 2>&1 || { echo "state: file: malformed JSON"; return 1; }
  out="$(jq -r "$VALIDATE" "$1")"
  [ -z "$out" ] || { echo "$out"; return 1; }
}

# Order: user-action, waiting, backlog (by priority), then opened and id.
SORT='sort_by([({"user-action":0,"waiting":1,"backlog":2}[.kind] // 3), (.priority // 0), .opened, .id])'

write_checked() { # $1 = new JSON text; validate, then atomic replace
  local tmp errs
  mkdir -p "$(dirname "$FILE")"
  tmp="$(mktemp "$FILE.XXXXXX")" || die "cannot create temp file"
  printf '%s\n' "$1" > "$tmp"
  if ! errs="$(validate_file "$tmp")"; then rm -f "$tmp"; echo "$errs" >&2; exit 1; fi
  mv "$tmp" "$FILE"
}

# Normalise key order of every item.
NORM='.items |= map({id,kind,title,detail,area,priority,opened,closed,status} + del(.id,.kind,.title,.detail,.area,.priority,.opened,.closed,.status))'

load() { # existing file contents, or empty store
  if [ -f "$FILE" ]; then
    validate_file "$FILE" >&2 || exit 1
    cat "$FILE"
  else echo '{"items":[]}'; fi
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
validate)
  validate_file "$FILE" || exit 1 ;;
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
  [ -n "$opened" ] || opened="$(today)"
  is_date "$opened" || die "$id: opened must be YYYY-MM-DD"
  cur="$(load)" || exit 1
  jq -e --arg id "$id" '.items | any(.id == $id)' <<<"$cur" >/dev/null && die "$id: duplicate id"
  new="$(jq --arg id "$id" --arg kind "$kind" --arg title "$title" --arg detail "$detail" --arg area "$area" \
        --arg prio "$prio" --arg opened "$opened" \
        '.items += [{id:$id,kind:$kind,title:$title,detail:$detail,area:$area,
          priority:(if $prio == "" then null else ($prio|tonumber) end),opened:$opened,closed:null,status:"open"}] | '"$NORM" <<<"$cur")" || die "add failed"
  write_checked "$new" ;;
close)
  id="${1:-}"; [ -n "$id" ] || die "close: id required"; shift
  date="$(today)"
  if [ "${1:-}" = "--date" ]; then date="${2:-}"; is_date "$date" || die "close: bad date"; fi
  cur="$(load)" || exit 1
  jq -e --arg id "$id" '.items | any(.id == $id)' <<<"$cur" >/dev/null || die "$id: unknown id"
  new="$(jq --arg id "$id" --arg d "$date" '.items |= map(if .id == $id then .status = "done" | .closed = $d else . end) | '"$NORM" <<<"$cur")"
  write_checked "$new" ;;
set)
  id="${1:-}"; [ -n "$id" ] || die "set: id required"; shift
  args=()
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --title|--detail|--kind|--area) args+=(--arg "${1#--}" "$2") ;;
      --priority) [[ "$2" =~ ^-?[0-9]+$ ]] || die "$id: priority must be an integer"; args+=(--argjson priority "$2") ;;
      *) die "set: unknown option $1" ;;
    esac; shift 2
  done
  cur="$(load)" || exit 1
  jq -e --arg id "$id" '.items | any(.id == $id)' <<<"$cur" >/dev/null || die "$id: unknown id"
  new="$(jq --arg id "$id" "${args[@]}" '($ARGS.named | del(.id)) as $u | .items |= map(if .id == $id then . + $u else . end) | '"$NORM" <<<"$cur")" || die "set failed"
  write_checked "$new" ;;
show)
  id="${1:-}"; [ -n "$id" ] || die "show: id required"
  cur="$(load)" || exit 1
  jq -e --arg id "$id" '.items[] | select(.id == $id)' <<<"$cur" >/dev/null || die "$id: unknown id"
  jq -r --arg id "$id" '.items[] | select(.id == $id) |
    "id: \(.id)\nkind: \(.kind)\narea: \(.area)\npriority: \(.priority // "-")\nopened: \(.opened)\nclosed: \(.closed // "-")\nstatus: \(.status)\ntitle: \(.title)\ndetail:\n\(.detail)"' <<<"$cur" ;;
list)
  all=0; [ "${1:-}" = "--all" ] && all=1
  cur="$(load)" || exit 1
  jq -r --argjson all "$all" ".items | map(select(\$all == 1 or .status == \"open\")) | $SORT | .[] | \"\(.id) · \(.kind) · \(.opened) · \(.title)\"" <<<"$cur" ;;
search)
  re="${1:-}"; [ -n "$re" ] || die "search: regex required"
  cur="$(load)" || exit 1
  jq -r --arg re "$re" '.items[] | select((.title + "\n" + .detail) | test($re; "i")) |
    "\(.id) · \(.status) · \(.title)\n" + ([(.title + "\n" + .detail) | split("\n")[] | select(test($re; "i")) | match($re; "i").offset as $o | "    …" + .[([$o - 60, 0] | max):($o + 140)] + "…"] | .[0:3] | join("\n"))' <<<"$cur" ;;
render)
  rel="${STATE_LABEL:-$FILE}"
  if errs="$(validate_file "$FILE")"; then
    jq -r --arg path "$rel" --arg self "$SELF" "
      (.items | map(select(.status == \"open\")) | $SORT) as \$o |
      \"## Open items (\(\$path))\",
      (\$o[] | select(.kind != \"backlog\") | \"- [\(.kind)] \(.opened) \(.id): \(.title)\"),
      ([\$o[] | select(.kind == \"backlog\")] as \$b | if (\$b | length) > 0 then \"Backlog: \(\$b | length) open; top: \(\$b[:3] | map(.title) | join(\"; \"))\" else empty end),
      \"Detail: \(\$self) -f \(\$path) show <id>. Decisions and pitfalls: docs/HANDOFF.md §2–3.\"" "$FILE"
  else
    echo "$errs" | sed 's/^/STATE INVALID: /'
    jq -r '[.. | objects | select(.kind == "user-action" and .status != "done")][] | "- [user-action] \(.id // "?"): \(.title // "?")"' "$FILE" 2>/dev/null || true
  fi ;;
*) echo "usage: state.sh [-f FILE] validate|add|set|close|show|list|search|render" >&2; exit 2 ;;
esac
