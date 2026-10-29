#!/usr/bin/env bash
set -uo pipefail
STATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
F="$WORK/state.json"
failures=0
check() { # name, want-substring, output
  if grep -qF -- "$2" <<<"$3"; then echo "ok    $1"; else echo "FAIL  $1: lacks '$2'"; echo "$3" | sed 's/^/      /'; failures=$((failures + 1)); fi
}
bash "$STATE" -f "$F" add --id launch --kind waiting --area game --title "Run the test" --detail "Intro text. Launch options: game-performance swap-log -- %command% -vulkan" >/dev/null
bash "$STATE" -f "$F" add --id other --kind backlog --area game --priority 1 --title "Unrelated" --detail "nothing here" >/dev/null
out="$(bash "$STATE" -f "$F" search 'swap-log')"
check "search finds the id and status" "launch · open · Run the test" "$out"
check "search shows the matching line" "swap-log -- %command%" "$out"
check "search is case-insensitive" "launch ·" "$(bash "$STATE" -f "$F" search 'SWAP-LOG')"
check "search skips non-matching items" "" "$(bash "$STATE" -f "$F" search 'swap-log' | grep -c other | sed 's/^0$//')"
[ -z "$(bash "$STATE" -f "$F" search 'zzzz')" ] && echo "ok    search with no match prints nothing" || { echo "FAIL  search with no match prints output"; failures=$((failures + 1)); }
bash "$STATE" -f "$F" search >/dev/null 2>&1 && { echo "FAIL  search without a regex succeeds"; failures=$((failures + 1)); } || echo "ok    search needs a regex"
[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
