#!/usr/bin/env bash
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/session-start.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
mkdir -p "$HOME/.claude" "$WORK/bin" "$WORK/cwd"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
printf '#!/bin/sh\necho testhost\n' > "$WORK/bin/hostname"
chmod +x "$WORK/bin/hostname"
export PATH="$WORK/bin:$PATH"

SK="$HOME/.claude/skills"
git init -q "$SK"
mkdir -p "$SK/host-hygiene"
printf -- '---\nname: host-hygiene\ndescription: general\n---\n' > "$SK/host-hygiene/SKILL.md"
git -C "$SK" add -A
git -C "$SK" commit -qm initial

failures=0
run_hook() {
  jq -cn --arg cwd "${1:-$WORK/cwd}" '{cwd:$cwd,source:"startup"}' | bash "$HOOK" 2>&1
}
expect_line() {
  local name="$1" want="$2" out
  out="$(run_hook "${3:-}")"
  if grep -qxF -- "$want" <<<"$out"; then echo "ok    $name"
  else echo "FAIL  $name: no line '$want'"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1)); fi
}
expect_count() {
  local name="$1" want="$2" n="$3" out got
  out="$(run_hook "${4:-}")"
  got="$(grep -cxF -- "$want" <<<"$out")"
  if [ "$got" -eq "$n" ]; then echo "ok    $name"
  else echo "FAIL  $name: line '$want' seen $got times, want $n"; echo "$out" | sed 's/^/      /'; failures=$((failures + 1)); fi
}

HKB="$(dirname "$HOOK")/../../scripts/kb"
KBD="$SK/docs/kb"
export KB_DIR="$KBD"
mkdir -p "$SK/docs"
"$HKB" mkcat host --title "Host facts" >/dev/null
expect_line "no host category entry is reported as none" "Host facts: none for testhost"
"$HKB" mkcat host/testhost --title "Test host" >/dev/null
"$HKB" mkcat host/testhost/hw --title "Hardware" >/dev/null
"$HKB" add host/testhost/hw/holds --type fact --title "Holds" --value "holds" --probe true --source-path x --source-locator x >/dev/null
"$HKB" add host/testhost/hw/policy --type fact --title "Policy fact" --value "a policy" --probe-none "policy" --source-path x --source-locator y >/dev/null
expect_line "host facts point to kb ls" "Host facts: kb ls host/testhost"
FAILHDR="Host facts whose probe failed (fix the fact or the probe this session; instruction-layer):"
expect_count "passing probes print nothing" "$FAILHDR" 0
expect_count "facts without a probe are not listed" "  UNCHECKED host/testhost/hw/policy -> Probe: none (policy)" 0
"$HKB" add host/testhost/hw/gone --type fact --title "Gone fact" --value "gone" --probe 'v=gone; echo "found $v"; [ "$v" = here ]' --source-path x --source-locator z >/dev/null
expect_line "a failing probe is reported with its output" "  FAIL host/testhost/hw/gone \`v=gone; echo \"found \$v\"; [ \"\$v\" = here ]\` -> found gone"
"$HKB" rm host/testhost/hw/gone >/dev/null
"$HKB" rm host/testhost/hw/holds >/dev/null
if "$HKB" add host/testhost/hw/unsafe --type fact --title "Unsafe fact" --value "unsafe" --probe 'rm -f /tmp/x' --source-path x --source-locator u >/dev/null 2>&1; then
  echo "FAIL  kb accepted a probe that writes"; failures=$((failures + 1))
else echo "ok    a probe that writes is refused when recorded, so SessionStart never runs it"; fi
rm -rf "$KBD"
unset KB_DIR

# global handoff and memory
MEMDIR="$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$HOME")/memory"
GH="$SK/docs/HANDOFF.md"
expect_line "missing global handoff is reported" "MISSING: global handoff $GH (instruction-layer)"
expect_line "missing home memory index is reported" "MISSING: home memory index $MEMDIR/MEMORY.md (instruction-layer)"
mkdir -p "$SK/docs" "$MEMDIR"
printf '# H\n\n## 0. State\n\nglobal-state-line\n\n## 1. Next\n\nnot-in-section-0\n' > "$GH"
: > "$MEMDIR/MEMORY.md"
expect_line "empty home memory index is reported" "MISSING: home memory index $MEMDIR/MEMORY.md (instruction-layer)"
printf -- '- [x](x.md) - x\n' > "$MEMDIR/MEMORY.md"
expect_count "home memory index present: no warning" "MISSING: home memory index $MEMDIR/MEMORY.md (instruction-layer)" 0
expect_count "global handoff present: no warning" "MISSING: global handoff $GH (instruction-layer)" 0
expect_line "non-repo cwd prints global handoff section 0" "global-state-line"
expect_count "only section 0 is printed" "not-in-section-0" 0
expect_line "HOME cwd prints global handoff section 0" "global-state-line" "$HOME"
expect_count "skills repo cwd prints the handoff once" "global-state-line" 1 "$SK"

P="$WORK/proj"
git init -q "$P"
mkdir -p "$P/docs"
printf '## 0. State\n\nproject-state-line\n## 1. x\n' > "$P/docs/HANDOFF.md"
git -C "$P" add -A
git -C "$P" commit -qm initial
expect_line "project cwd prints the project handoff" "project-state-line" "$P"
expect_count "project cwd does not print the global handoff" "global-state-line" 0 "$P"

# a handoff with state.json prints the compact rendering instead of section 0
mkdir -p "$SK/scripts"
cp "$(dirname "$HOOK")/../../scripts/state.sh" "$SK/scripts/state.sh"
expect_line "no state.json: section 0 header still printed" "## $P/docs/HANDOFF.md section 0 (first 80 lines)" "$P"
printf '{"items":[{"id":"do-it","kind":"user-action","title":"Do it","detail":"","area":"x","priority":null,"opened":"2026-01-01","closed":null,"status":"open"}]}\n' > "$P/docs/state.json"
expect_line "state.json: Open items header" "## Open items ($P/docs/state.json)" "$P"
expect_line "state.json: user action rendered" "- [user-action] 2026-01-01 do-it: Do it" "$P"
expect_line "state.json: Handoff line" "Handoff: $P/docs/HANDOFF.md (§1 where state lives, §2 decisions, §3 pitfalls; read on demand)" "$P"
expect_count "state.json: section 0 text not printed" "project-state-line" 0 "$P"
echo '{"items":[{"id":"bad","kind":"user-action","title":"Still visible","status":"open"}]}' > "$P/docs/state.json"
expect_line "invalid state.json still shows the user action" "- [user-action] bad: Still visible" "$P"
# missing state.sh: fall back to section 0 (hook copy without scripts/)
FAKE="$WORK/fake"; mkdir -p "$FAKE/claude-worktree"; cp -r "$(dirname "$HOOK")" "$FAKE/claude-worktree/hooks"
out="$(jq -cn --arg cwd "$P" '{cwd:$cwd,source:"startup"}' | bash "$FAKE/claude-worktree/hooks/session-start.sh" 2>&1)"
if grep -qxF "project-state-line" <<<"$out"; then echo "ok    missing state.sh falls back to section 0"; else echo "FAIL  missing state.sh fallback"; failures=$((failures + 1)); fi
rm -f "$P/docs/state.json"
# global handoff path renders open items
printf '{"items":[{"id":"glob","kind":"waiting","title":"Global item","detail":"","area":"x","priority":null,"opened":"2026-01-01","closed":null,"status":"open"}]}\n' > "$SK/docs/state.json"
expect_line "global handoff with state.json renders open items" "- [waiting] 2026-01-01 glob: Global item" "$HOME"
rm -f "$SK/docs/state.json"

expect_line "HOME cwd with trailing slash prints global handoff" "global-state-line" "$HOME/"

# a handoff next to docs/kb prints the topics and the open items from kb
export KB_DIR="$SK/docs/kb"
"$HKB" mkcat setup --title "Setup and process" >/dev/null
"$HKB" mkcat setup/items --title "Items" >/dev/null
"$HKB" add setup/items/kb-item --type item --kind user-action --title "Kb item" >/dev/null
"$HKB" add setup/items/kb-back --type item --kind backlog --priority 1 --title "Kb backlog" >/dev/null
unset KB_DIR
D="$(date +%F)"
expect_line "kb: topics listed" "setup - Setup and process" "$HOME"
expect_line "kb: user action rendered" "- [user-action] $D kb-item: Kb item" "$HOME"
expect_line "kb: backlog summarised" "Backlog: 1 open; top: Kb backlog" "$HOME"
expect_line "kb: Handoff line" "Handoff: $GH (§1 where state lives; read on demand). Decisions and pitfalls: kb ls setup/decisions, kb ls setup/pitfalls; record new ones with kb add" "$HOME"
expect_count "kb: section 0 text not printed" "global-state-line" 0 "$HOME"
expect_count "kb: no §2/§3 advertisement" "§2 decisions" 0 "$HOME"
# schema too new (exit 3) or an unreadable store falls back to section 0
jq '._schema = 99' "$SK/docs/kb/setup.json" > "$WORK/setup.json" && cp "$WORK/setup.json" "$SK/docs/kb/setup.json"
expect_line "kb: schema too new falls back to section 0" "global-state-line" "$HOME"
expect_count "kb: schema too new prints no topics" "setup - Setup and process" 0 "$HOME"
rm -rf "$SK/docs/kb"

# the hot sheet comes first, before the report header, and kb failures print nothing
export KB_DIR="$WORK/hotkb"
"$HKB" mkcat host --title "Host facts" >/dev/null
"$HKB" mkcat host/testhost --title "Test host" >/dev/null
"$HKB" add host/testhost/swap --type fact --title "Swap" --value "8 GB swap" --probe-none p --source-path x --source-locator y --alias swap-hot --field hot=true >/dev/null
out="$(run_hook "$WORK/cwd")"
if [ "$(head -1 <<<"$out" | cut -c1-4)" = "HOT " ] && grep -qxF "swap-hot=8 GB swap" <<<"$out" \
   && [ "$(grep -n '^HOT ' <<<"$out" | head -1 | cut -d: -f1)" -lt "$(grep -n '^# SessionStart report' <<<"$out" | cut -d: -f1)" ]; then
  echo "ok    hot sheet is printed first"; else echo "FAIL  hot sheet first"; echo "$out" | head -5 | sed 's/^/      /'; failures=$((failures + 1)); fi
jq '._schema = 99' "$WORK/hotkb/host.json" > "$WORK/host.json" && cp "$WORK/host.json" "$WORK/hotkb/host.json"
out="$(run_hook "$WORK/cwd")"
if grep -q '^HOT ' <<<"$out"; then echo "FAIL  schema too new still printed a hot sheet"; failures=$((failures + 1)); else echo "ok    schema too new (exit 3): no hot sheet, no error"; fi
rm -rf "$WORK/hotkb"; unset KB_DIR

# a skills mirror has no worktree and no memory to restore
rm -f "$GH" "$MEMDIR/MEMORY.md"
echo managing-host > "$SK/.git/mirror-of"
expect_count "mirror: no global handoff warning" "MISSING: global handoff $GH (instruction-layer)" 0
expect_count "mirror: no home memory warning" "MISSING: home memory index $MEMDIR/MEMORY.md (instruction-layer)" 0
rm -f "$SK/.git/mirror-of"

# HOME given with a trailing slash keys memory the same way
HOME="$HOME/" expect_line "trailing-slash HOME uses the same memory key" "MISSING: home memory index $MEMDIR/MEMORY.md (instruction-layer)"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
