#!/usr/bin/env bash
set -uo pipefail

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export STATE_FILE="$WORK/state.json"

failures=0
ok() { echo "ok    $1"; }
nok() { echo "FAIL  $1"; [ -n "${2:-}" ] && sed 's/^/      /' <<<"$2"; failures=$((failures + 1)); }
# expect NAME WANT_EXIT WANT_TEXT -- command...
expect() {
  local name="$1" want="$2" text="$3" out rc; shift 4
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then nok "$name: exit $rc, want $want" "$out"
  elif [ -n "$text" ] && ! grep -qF -- "$text" <<<"$out"; then nok "$name: output lacks '$text'" "$out"
  else ok "$name"; fi
}
lacks() { # NAME TEXT -- command...
  local name="$1" text="$2" out; shift 3
  out="$("$@" 2>&1)"
  if grep -qF -- "$text" <<<"$out"; then nok "$name: output has '$text'" "$out"; else ok "$name"; fi
}

expect "add user-action" 0 "" -- bash "$S" add --id ua-one --kind user-action --title "Sign the thing" --area setup --opened 2026-01-02
expect "add waiting" 0 "" -- bash "$S" add --id wait-one --kind waiting --title "Waiting on mirror" --area setup --opened 2026-01-03
for i in 4 1 3 2; do
  bash "$S" add --id "bl-$i" --kind backlog --title "Backlog $i" --area x --priority "$i" --opened 2026-01-05 || nok "add bl-$i"
done
expect "validate passes" 0 "" -- bash "$S" validate
expect "list shows id, kind, opened, title" 0 "ua-one · user-action · 2026-01-02 · Sign the thing" -- bash "$S" list
expect "show prints detail in full" 0 "title: Sign the thing" -- bash "$S" show ua-one
expect "show unknown id fails" 1 "unknown id" -- bash "$S" show nope
order="$(bash "$S" list | cut -d' ' -f1 | tr '\n' ' ')"
[ "$order" = "ua-one wait-one bl-1 bl-2 bl-3 bl-4 " ] && ok "list order: user-action, waiting, backlog by priority" || nok "list order: $order"

expect "duplicate id refused" 1 "duplicate id" -- bash "$S" add --id ua-one --kind waiting --title X --area a
expect "unknown kind refused" 1 "kind must be" -- bash "$S" add --id k1 --kind chore --title X --area a
expect "title over 100 chars refused" 1 "title must be" -- bash "$S" add --id t1 --kind waiting --title "$(printf 'x%.0s' $(seq 101))" --area a
expect "backlog without priority refused" 1 "priority" -- bash "$S" add --id p1 --kind backlog --title X --area a
lacks "refused adds leave the file unchanged" "k1" -- cat "$STATE_FILE"

out="$(bash "$S" render)"
for want in "## Open items ($STATE_FILE)" "- [user-action] 2026-01-02 ua-one: Sign the thing" "- [waiting] 2026-01-03 wait-one: Waiting on mirror" \
  "Backlog: 4 open; top: Backlog 1; Backlog 2; Backlog 3" "Detail: $S -f $STATE_FILE show <id>."; do
  if grep -qF -- "$want" <<<"$out"; then ok "render has '$want'"; else nok "render lacks '$want'" "$out"; fi
done
lacks "render shows only top 3 backlog titles" "Backlog 4;" -- bash "$S" render

expect "close ua-one" 0 "" -- bash "$S" close ua-one --date 2026-02-01
[ "$(jq -r '.items[]|select(.id=="ua-one")|.status+" "+.closed' "$STATE_FILE")" = "done 2026-02-01" ] && ok "close sets done and closed date" || nok "close fields"
lacks "render omits closed item" "ua-one" -- bash "$S" render
expect "close unknown id fails" 1 "unknown id" -- bash "$S" close nope

# special characters survive add -> show
rm -f "$STATE_FILE"
detail=$'say "hi" $HOME `x` \\n back\\slash\nsecond line'
title='Q "quoted" $VAR \back'
bash "$S" add --id weird --kind waiting --title "$title" --area 'a"b' --detail "$detail" || nok "add weird values"
[ "$(jq -r '.items[0].title' "$STATE_FILE")" = "$title" ] && [ "$(jq -r '.items[0].detail' "$STATE_FILE")" = "$detail" ] \
  && ok "special characters survive add" || nok "special characters changed"
expect "special characters survive show" 0 'second line' -- bash "$S" show weird
[ "$(bash "$S" show weird | sed -n '/^detail:/,$p' | tail -n +2)" = "$detail" ] && ok "show detail is unchanged" || nok "show detail changed"

# set
rm -f "$STATE_FILE"
bash "$S" add --id s1 --kind backlog --title Old --area a --priority 5 --detail keep
expect "set updates fields" 0 "" -- bash "$S" set s1 --title "New \"t\"" --priority 1 --area b
[ "$(jq -c '.items[0]|[.title,.priority,.area,.detail]' "$STATE_FILE")" = '["New \"t\"",1,"b","keep"]' ] && ok "set changed only given fields" || nok "set fields"
expect "set unknown id fails" 1 "unknown id" -- bash "$S" set nope --title X
expect "set invalid result refused" 1 "kind must be" -- bash "$S" set s1 --kind bogus
[ "$(jq -r '.items[0].kind' "$STATE_FILE")" = backlog ] && ok "refused set leaves file unchanged" || nok "set changed file"

# title with newline; unknown keys survive
expect "newline in title refused" 1 "title must be" -- bash "$S" add --id nl --kind waiting --title $'a\nb' --area a
jq '.items[0].extra = {"k":1}' "$STATE_FILE" > "$WORK/x" && mv "$WORK/x" "$STATE_FILE"
bash "$S" set s1 --title Again; bash "$S" add --id s2 --kind waiting --title Two --area a
[ "$(jq -c '.items[0].extra' "$STATE_FILE")" = '{"k":1}' ] && ok "unknown keys survive set and add" || nok "unknown key dropped"

# malformed JSON
echo '{"items": [' > "$STATE_FILE"
expect "malformed JSON fails validate" 1 "malformed" -- bash "$S" validate
expect "malformed JSON: render says STATE INVALID, exit 0" 0 "STATE INVALID:" -- bash "$S" render
# invalid but readable: user actions are still shown
echo '{"items":[{"id":"ua","kind":"user-action","title":"Must do","status":"open"}]}' > "$STATE_FILE"
expect "invalid file still lists user actions" 0 "Must do" -- bash "$S" render
echo '{"items":{"x":{"id":"ua2","kind":"user-action","title":"Obj shape","status":"open"}}}' > "$STATE_FILE"
expect "items as object: user action still shown" 0 "Obj shape" -- bash "$S" render
echo '[{"id":"ua3","kind":"user-action","title":"Array shape","status":"open"}]' > "$STATE_FILE"
expect "top-level array: user action still shown" 0 "Array shape" -- bash "$S" render
expect "-f selects another file" 0 "" -- bash "$S" -f "$WORK/other.json" add --id o1 --kind waiting --title O --area a

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
