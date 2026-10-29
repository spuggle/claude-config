#!/usr/bin/env bash
# Check the global skills repository against the authoring rules in
# instruction-layer ("Writing a skill") and run every hook test.
# Usage: scripts/check.sh   (from any directory; checks the copy it lives in)
set -uo pipefail
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
fail=0
bad() { echo "FAIL  $*"; fail=1; }

for f in */SKILL.md; do
  dir="${f%/SKILL.md}"
  [ "$dir" = synced ] && continue
  name="$(sed -n '2,5s/^name: //p' "$f" | head -1)"
  desc="$(sed -n '2,8s/^description: //p' "$f" | head -1)"
  [ "$(head -1 "$f")" = "---" ] || bad "$f: no frontmatter"
  [ "$name" = "$dir" ] || bad "$f: name '$name' does not match directory '$dir'"
  [[ "$name" =~ ^[a-z0-9-]{1,64}$ ]] || bad "$f: name must be lowercase letters, digits, hyphens (max 64)"
  [ -n "$desc" ] || bad "$f: empty or multi-line description"
  [ "${#desc}" -le 600 ] || bad "$f: description ${#desc} chars (rule: under ~600; hard cap 1024)"
  grep -qiE "^description: (I |you |I'|you')" "$f" && bad "$f: description in first or second person"
  lines="$(wc -l <"$f")"
  [ "$lines" -le 150 ] || bad "$f: body $lines lines (rule: under ~150)"
  tokens=$(( $(wc -c <"$f") / 4 ))
  [ "$tokens" -le 2000 ] || echo "WARN  $f: body ~$tokens tokens (rule: under ~2k)"
  grep -nE '(^|[[:space:](])@[A-Za-z0-9_./~-]+\.(md|txt|sh|py)' "$f" | grep -v '`' | sed "s|^|FAIL  $f: @path link (force-loads): |" && fail=1
  # every references/… mentioned in the body exists, and references are one level deep
  for ref in $(grep -oE 'references/[A-Za-z0-9_<>().$ -]+\.md' "$f" | grep -v '[<$]' | sort -u); do
    [ -f "$dir/$ref" ] || bad "$f: points to missing $dir/$ref"
  done
  if [ -d "$dir/references" ]; then
    for r in "$dir"/references/*.md; do
      grep -oE '(^|[^/a-z-])references/[a-z0-9-]+\.md' "$r" | grep -oE 'references/[a-z0-9-]+\.md' | while read -r x; do
        [ "$(basename "$x")" = "$(basename "$r")" ] || echo "WARN  $r links another reference ($x): keep references one level deep"
      done
      rl="$(wc -l <"$r")"
      if [ "$rl" -gt 100 ] && ! grep -qiE '^## contents' "$r"; then bad "$r: $rl lines without a Contents list"; fi
    done
  fi
  if [ -f "$dir/evals/triggers.json" ]; then
    jq -e 'type=="array" and all(.[]; has("query") and (.should_trigger|type=="boolean"))' "$dir/evals/triggers.json" >/dev/null \
      || bad "$dir/evals/triggers.json: not an array of {query, should_trigger}"
    for want in true false; do
      n="$(jq "[.[]|select(.should_trigger==$want)]|length" "$dir/evals/triggers.json")"
      [ "$n" -ge 3 ] || bad "$dir/evals/triggers.json: only $n cases with should_trigger=$want (need 3)"
    done
  fi
done

# gate lines: four tab-separated fields, valid regexes, skills that exist
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r _tools pattern skills reason <<<"$line"
  [ -n "$reason" ] || { bad "skill-gates: line needs 4 tab-separated fields: ${line:0:60}"; continue; }
  grep -qE -- "$pattern" <<<"" ; [ $? -le 1 ] || bad "skill-gates: invalid regex: $pattern"
  for s in $skills; do
    case "$s" in agent:*) [ -f "agents/${s#agent:}.md" ] || bad "skill-gates: unknown agent $s" ;; *) [ -f "$s/SKILL.md" ] || bad "skill-gates: unknown skill $s" ;; esac
  done
done < <(cat claude-worktree/skill-gates .claude/skill-gates 2>/dev/null)

# agents: required frontmatter
for a in agents/*.md; do
  [ -f "$a" ] || continue
  grep -q '^name: ' "$a" && grep -q '^description: ' "$a" || bad "$a: needs name and description"
done

# kb store: schema, links, probe safety (host facts live here), canonical form; it holds the open items too (no docs/state.json)
if [ -d docs/kb ]; then
  out="$(KB_DIR="$ROOT/docs/kb" python3 scripts/kb validate 2>&1)" || { echo "$out" | sed 's/^/FAIL  /'; fail=1; }
  out="$(KB_DIR="$ROOT/docs/kb" python3 scripts/kb fmt --check 2>&1)" || { echo "$out" | sed 's/^/FAIL  kb fmt --check: /'; fail=1; }
fi


# Lint shell scripts when shellcheck is installed; intended patterns carry disable directives
if command -v shellcheck >/dev/null 2>&1; then
  out="$(shellcheck -S warning claude-worktree/hooks/*.sh claude-worktree/scripts/*.sh scripts/*.sh 2>&1)" || { echo "$out" | sed "s/^/FAIL  shellcheck: /"; fail=1; }
else
  echo "NOTE  shellcheck not installed; skipped"
fi

# hook and script tests (includes scripts/tests: kb-test.sh)
for t in */tests/*-test.sh; do
  bash "$t" >/dev/null 2>&1 || bad "$t exits non-zero (run it for details)"
done
for s in claude-worktree/hooks/*.sh claude-worktree/scripts/*.sh claude-worktree/git-hooks/* scripts/*.sh; do
  [ -f "$s" ] && { bash -n "$s" 2>/dev/null || bad "$s: bash syntax error"; }
done
python3 -m py_compile claude-worktree/hooks/*.py instruction-layer/scripts/*.py 2>/dev/null || bad "python hook or script does not compile"

[ "$fail" -eq 0 ] && echo "check: all passed" || { echo "check: failures above"; exit 1; }
