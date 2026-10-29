#!/usr/bin/env bash
# scripts/kb: every command, every validate failure, aliases, supersede/history, ref/link, mv/rm,
# concurrency, fmt, schema-too-new, state/facts import and export, probe pass/fail/stale/unchecked.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="$ROOT/scripts/kb"
STATE="$ROOT/scripts/state.sh"
WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export KB_DIR="$WORK/kb" KB_CACHE="$WORK/cache/verified.json" KB_TODAY=2026-10-27 EDITOR=false HOME="$WORK/home"
mkdir -p "$HOME"
failures=0
HAVE_SHFMT=1; command -v shfmt >/dev/null || HAVE_SHFMT=0

fail() { echo "FAIL  $1"; shift; printf '%s\n' "$@" | sed 's/^/      /'; failures=$((failures + 1)); }
# expect NAME WANT_RC WANT_TEXT ARGS...   (WANT_TEXT may be empty; output is stdout+stderr)
expect() {
  local name="$1" rc="$2" want="$3"; shift 3
  OUT="$("$K" "$@" 2>&1)"; RC=$?
  if [ "$RC" -ne "$rc" ]; then fail "$name: exit $RC, want $rc" "$OUT"
  elif [ -n "$want" ] && ! grep -qF -- "$want" <<<"$OUT"; then fail "$name: output lacks '$want'" "$OUT"
  elif grep -q Traceback <<<"$OUT"; then fail "$name: crashed" "$OUT"
  else echo "ok    $name"; fi
}
lacks() { # NAME TEXT  (against the last OUT)
  if grep -qF -- "$2" <<<"$OUT"; then fail "$1: output has '$2'" "$OUT"; else echo "ok    $1"; fi
}
has() { if grep -qF -- "$2" <<<"$OUT"; then echo "ok    $1"; else fail "$1: output lacks '$2'" "$OUT"; fi; }
same() { if [ "$2" = "$3" ]; then echo "ok    $1"; else fail "$1: got '$2', want '$3'"; fi; }

# ---- help on every command
for c in ask hot ls find get links search add mkcat set close link ref supersede mv rm edit probe validate fmt render import-state export-state import-facts; do
  expect "$c --help" 0 "usage:" "$c" --help
done
expect "add --help prints the type table" 0 "chezmoi_source" add --help
has "add --help lists procedure" "procedure"
expect "no command is a usage error" 2 ""
expect "unknown option is a usage error" 2 "" ls --bogus

# ---- build the main fixture store
"$K" mkcat games --title "Games" --alias gaming >/dev/null
"$K" mkcat games/deadlock --title "Deadlock" --alias deadlock --alias 1422450 >/dev/null
for c in launch config mangohud; do "$K" mkcat games/deadlock/$c --title "Deadlock $c" >/dev/null; done
"$K" mkcat host --title "Hosts" >/dev/null
"$K" mkcat host/box --title "The box" --alias box >/dev/null
"$K" mkcat host/box/memory --title "Memory and swap" >/dev/null
"$K" mkcat setup --title "Setup" >/dev/null
"$K" mkcat setup/items --title "Open items" >/dev/null
"$K" mkcat setup/decisions --title "Decisions" >/dev/null
expect "mkcat twice fails" 1 "already exists" mkcat host/box --title x
expect "mkcat under a missing topic fails" 1 "does not exist" mkcat nope/x --title x
expect "add: launch options fact" 0 "added games/deadlock/launch/options" add games/deadlock/launch/options --type fact \
  --title "Steam launch options string (localconfig.vdf)" --value "gamemoderun %command%" --probe "test -d /tmp" \
  --source-path localconfig.vdf --source-locator "apps 1422450" --alias launch-options
expect "add: artifact" 0 "" add games/deadlock/config/autoexec --type artifact --title "autoexec.cfg written by Claude" \
  --field path=/home/u/autoexec.cfg --field written_by=claude --field chezmoi_source=null --commit e33fb66
expect "add: frame cap" 0 "" add games/deadlock/mangohud/frame-cap --type fact --title "MangoHud frame limiter" \
  --value "fps_limit=90" --probe-none "needs the game running" --source-path deadlock.conf --source-locator "fps_limit"
expect "add: swap fact" 0 "" add host/box/memory/swap-size --type fact --title "Swap file size" --value "8 GB" \
  --probe "test -d /tmp" --source-path /etc/fstab --source-locator "swap line" --commit 41ef9e7
expect "add: planned swap item" 0 "" add host/box/memory/swap-plan --type item --kind backlog --priority 2 \
  --title "Grow swap to 16 GB" --body "run zswap.sh" --link blocks=swap-size
expect "add: decision" 0 "" add setup/decisions/use-kb --type decision --title "Use kb for facts" \
  --decision "Facts live in kb" --body "Original paragraph."

# ---- ls, aliases, tree
expect "ls top level: one line per topic" 0 "games - Games" ls
has "ls top level: host" "host - Hosts"
expect "ls alias resolves" 0 "launch/  Deadlock launch  (1)" ls deadlock
expect "ls numeric alias" 0 "config/" ls 1422450
expect "ls alias/rest" 0 "options  Steam launch options" ls deadlock/launch
expect "ls full path" 0 "options  Steam launch options" ls games/deadlock/launch
expect "ls entry id" 0 "id: options" ls options
expect "ls typo suggests" 1 "did you mean: deadlock" ls deadlok
expect "ls missing leaf lists siblings" 1 "under games/deadlock/launch: options" ls games/deadlock/launch/optoins
expect "ls --json" 0 '"name": "games"' ls --json
expect "ls --tree" 0 "  deadlock/  Deadlock" ls --tree
has "ls --tree has entries" "      options  Steam launch options"
expect "ls --tree PATH" 0 "frame-cap  MangoHud frame limiter" ls --tree games/deadlock/mangohud

# tree caps: line cap and char cap
"$K" mkcat setup/many --title "Many" >/dev/null
for i in $(seq 1 70); do "$K" add setup/many/e$i --type pitfall --title "Pitfall $i" --dup-ok >/dev/null; done
expect "tree capped at 60 lines" 0 "lines cut" ls --tree setup/many
same "tree output is 60 lines" "$("$K" ls --tree setup/many | wc -l)" 60
"$K" mkcat setup/wide --title "Wide" >/dev/null
for i in $(seq 1 50); do "$K" add setup/wide/w$i --type pitfall --title "w$i-$(head -c 90 /dev/zero | tr '\0' x)" --dup-ok >/dev/null; done
expect "tree capped at 4k chars" 0 "lines cut" ls --tree setup/wide
n=$(wc -c <<<"$("$K" ls --tree setup/wide)"); [ "$n" -le 4200 ] && echo "ok    tree under 4k chars" || fail "tree chars $n"
"$K" rm setup/many --force >/dev/null; "$K" rm setup/wide --force >/dev/null

# ---- add details
expect "add: id is made unique store-wide" 0 "(id options-2)" add host/box/memory/options --type pitfall --title "Unrelated words here"
expect "add: duplicate refused" 1 "duplicate of games/deadlock/launch/options" add games/deadlock/launch/opts --type fact \
  --title "Steam launch options string" --value "gamemoderun %command%" --probe-none x --source-path p --source-locator l
has "add: lists nearest entries" "nearest entries in games"
expect "add: --dup-ok overrides" 0 "" add games/deadlock/launch/opts --type fact --title "Steam launch options string" \
  --value "gamemoderun %command%" --probe-none x --source-path p --source-locator l --dup-ok
expect "add: existing path refused" 1 "already exists" add games/deadlock/launch/opts --type pitfall --title zz --dup-ok
expect "add: missing category refused" 1 "no category games/nothere" add games/nothere/x --type pitfall --title zz
expect "add: bad type is usage" 2 "" add games/deadlock/x --type bogus --title zz
expect "add: fact without probe refused" 1 "fact requires probe" add games/deadlock/launch/np --type fact --title "No probe at all" --value v \
  --source-path p --source-locator l
expect "add: long title refused" 1 "title must be" add games/deadlock/launch/lt --type pitfall --title "$(printf 'x%.0s' {1..101})"
expect "add: decision needs body" 1 "decision requires body" add setup/decisions/nb --type decision --title "No body" --decision d
expect "add: backlog needs priority" 1 "backlog needs an integer priority" add setup/items/np --type item --kind backlog --title "No prio"
if [ "$HAVE_SHFMT" = 1 ]; then
  expect "add: unsafe probe refused" 1 "not read-only" add games/deadlock/launch/bad --type fact --title "Writes a file" --value v \
    --probe "touch /tmp/kb-test-should-not-exist" --source-path p --source-locator l
  [ ! -e /tmp/kb-test-should-not-exist ] && echo "ok    unsafe probe never ran" || fail "unsafe probe ran"
fi

# ---- get, find, search, links
expect "get by path" 0 "value: gamemoderun %command%" get games/deadlock/launch/options
has "get shows source" "source: localconfig.vdf :: apps 1422450"
has "get shows probe" "probe: test -d /tmp"
expect "get via alias --why" 0 "via: alias deadlock -> games/deadlock" get deadlock/launch/options --why
expect "get by id" 0 "at: games/deadlock/launch/options" get options
expect "get by entry alias" 0 "at: games/deadlock/launch/options" get launch-options
expect "get --field" 0 "gamemoderun %command%" get options --field value
expect "get --field dotted" 0 "localconfig.vdf" get options --field source.path
expect "get unknown field" 1 "no field" get options --field nope
expect "get --json" 0 '"written_by": "claude"' get games/deadlock/config/autoexec --json
expect "get autoexec shows commit" 0 "commits: e33fb66" get games/deadlock/config/autoexec
expect "get a category lists it" 0 "frame-cap" get games/deadlock/mangohud
expect "find by word" 0 "games/deadlock/mangohud/frame-cap  MangoHud frame limiter" find frame limiter
expect "find by alias" 0 "games/deadlock/" find deadlock
expect "find --under" 0 "host/box/memory/swap-size" find swap --under host
expect "find --type" 0 "autoexec" find autoexec --type artifact
expect "find no match" 1 "not recorded" find zzzzqq
has "find no match lists topics" "topics: games - Games"
expect "search regex" 0 "games/deadlock/mangohud/frame-cap" search 'fps_limit=\d+'
expect "search --commit" 0 "host/box/memory/swap-size" search --commit 41ef9e7
expect "search --commit short" 0 "swap-size" search --commit 41ef
expect "search --commit none" 1 "no match" search --commit deadbeef
expect "search --path" 0 "games/deadlock/config/autoexec" search --path autoexec.cfg
expect "search --type --under" 0 "swap-plan" search 'swap' --type item --under host
expect "search no match" 1 "no match" search 'qqqqzzz'
expect "search without args" 2 "" search
expect "search bad regex" 2 "bad regex" search '('
expect "links outgoing and incoming" 0 "<- blocks  swap-plan" links host/box/memory/swap-size
expect "links on the item" 0 "-> blocks  swap-size  host/box/memory/swap-size" links swap-plan
expect "links --json" 0 '"rel": "blocks"' links swap-plan --json

# ---- set, close, link, ref
expect "set value" 0 "updated" set host/box/memory/swap-size --value "16 GB"
expect "set persisted" 0 "16 GB" get swap-size --field value
expect "set nothing" 2 "nothing to change" set swap-size
expect "set category title" 0 "" set games/deadlock --title "Deadlock (game)"
expect "set category alias" 0 "" set games/deadlock --alias dl
expect "alias dl resolves" 0 "launch/" ls dl
expect "set decision body refused" 1 "frozen" set use-kb --value "changed"
expect "set decision status ok" 0 "" set use-kb --status accepted-final
expect "set unknown id fails" 1 "not found" set nonexistent --value x
expect "close item" 0 "closed" close swap-plan --date 2026-10-28
expect "close hides item in ls" 0 "" ls host/box/memory
lacks "closed item hidden" "swap-plan"
expect "ls --all shows done" 0 "swap-plan  Grow swap to 16 GB  [done]" ls host/box/memory --all
expect "close a fact refused" 1 "not an item" close swap-size
expect "link bad rel" 2 "rel must be" link swap-size friend options
expect "link unknown id" 1 "not found" link swap-size about nope
expect "link ok" 0 "linked" link options about frame-cap
expect "link duplicate refused" 1 "already exists" link options about frame-cap
expect "link --remove" 0 "unlinked" link options about frame-cap --remove
expect "ref also under" 0 "added ref" ref options --at games/deadlock/mangohud
expect "ls marks refs" 0 "-> games/deadlock/launch/options" ls games/deadlock/mangohud
expect "get through a ref" 0 "at: games/deadlock/launch/options" get games/deadlock/mangohud/options
expect "links lists refs" 0 "also listed under games/deadlock/mangohud" links options
expect "ref in the home category refused" 1 "home category" ref options --at games/deadlock/launch
expect "ref twice refused" 1 "already refs" ref options --at games/deadlock/mangohud
expect "link + ref of the same pair refused" 1 "use one or the other" link frame-cap about options
expect "search finds a ref'd entry once" 0 "" search 'gamemoderun'
same "search reports each entry once" "$("$K" search 'gamemoderun' | grep -c '^games')" 2   # options and opts
expect "ref --remove" 0 "removed ref" ref options --at games/deadlock/mangohud --remove
expect "ref to a category fails" 1 "ref needs an entry" ref games/deadlock --at host

# ---- supersede, history
expect "supersede" 0 "superseded by" supersede swap-size options-2
expect "ls hides superseded" 0 "" ls host/box/memory
lacks "superseded hidden in ls" "swap-size  "
expect "ls --history shows it" 0 "[superseded by options-2]" ls host/box/memory --history
expect "get superseded refused" 1 "superseded by options-2" get swap-size
expect "get --history reads it" 0 "superseded_by: options-2" get swap-size --history
expect "find hides superseded" 1 "" find swap --under host --type fact
expect "find --history" 0 "swap-size" find swap --under host --history
expect "links shows the chain" 0 "superseded by  options-2" links swap-size
expect "links shows supersedes" 0 "supersedes  swap-size" links options-2
expect "supersede twice refused" 1 "already superseded" supersede swap-size options-2
expect "supersede self refused" 1 "itself" supersede options-2 options-2
expect "supersede chain stays valid" 0 "" validate

# ---- mv, rm
expect "mv entry" 0 "moved" mv host/box/memory/swap-plan host/box/memory/swap-grow
expect "mv keeps ids (links valid)" 0 "swap-grow" links swap-size
expect "mv to existing refused" 1 "already exists" mv host/box/memory/swap-grow host/box/memory/swap-size
expect "mv into itself refused" 1 "into itself" mv host/box host/box/x
expect "mv category" 0 "moved" mv games/deadlock/mangohud games/deadlock/overlay
expect "mv category keeps entries" 0 "frame-cap" ls deadlock/overlay
expect "mv topic needs topic" 1 "topic can only" mv setup games/setup
expect "mv missing source" 1 "not found" mv games/nothing games/other
expect "validate after mv" 0 "ok" validate
expect "rm refused while linked" 1 "still referenced" rm host/box/memory/swap-size
has "rm names the blocker" "links blocks -> swap-size"
expect "rm refused while ref'd" 0 "" ref options --at games/deadlock/overlay
expect "rm refuses a ref'd entry" 1 "refs options" rm games/deadlock/launch/options
expect "rm non-empty category refused" 1 "not empty" rm games/deadlock/launch
expect "rm --force removes and cleans links" 0 "removed" rm host/box/memory/swap-size --force
expect "store valid after forced rm" 0 "ok" validate
expect "rm a ref" 0 "removed" rm games/deadlock/overlay/options
expect "rm entry" 0 "removed" rm games/deadlock/launch/opts
expect "rm unknown" 1 "not found" rm games/deadlock/launch/opts

# ---- edit
cat >"$WORK/ed-ok.sh" <<'EOF'
#!/bin/sh
sed -i 's/"fps_limit=90"/"fps_limit=60"/' "$1"
EOF
cat >"$WORK/ed-bad.sh" <<'EOF'
#!/bin/sh
echo '{ not json' > "$1"
EOF
cat >"$WORK/ed-id.sh" <<'EOF'
#!/bin/sh
sed -i 's/"id": "frame-cap"/"id": "other"/' "$1"
EOF
cat >"$WORK/ed-title.sh" <<'EOF'
#!/bin/sh
sed -i 's/"title": "Use kb for facts"/"title": "Changed"/' "$1"
EOF
cat >"$WORK/ed-invalid.sh" <<'EOF'
#!/bin/sh
sed -i 's/"fps_limit=60"/""/' "$1"
EOF
chmod +x "$WORK"/ed-*.sh
EDITOR="$WORK/ed-ok.sh" expect "edit applies a valid change" 0 "edited" edit frame-cap
expect "edit persisted" 0 "fps_limit=60" get frame-cap --field value
EDITOR="$WORK/ed-bad.sh" expect "edit rejects invalid JSON" 1 "not valid JSON" edit frame-cap
EDITOR="$WORK/ed-id.sh" expect "edit rejects an id change" 1 "id is immutable" edit frame-cap
EDITOR="$WORK/ed-title.sh" expect "edit rejects a decision change" 1 "frozen" edit use-kb
EDITOR="$WORK/ed-invalid.sh" expect "edit rejects a schema violation" 1 "value must be" edit frame-cap
expect "edit persisted nothing from rejects" 0 "fps_limit=60" get frame-cap --field value
EDITOR=true expect "edit with no change" 1 "no change" edit frame-cap

# ---- render
expect "render --open" 0 "## Open items" render --open
"$K" add setup/items/fix-x --type item --kind user-action --title "Fix x by hand" --body "a" "--opened=2026-10-20" >/dev/null
"$K" add setup/items/later --type item --kind backlog --priority 3 --title "Later thing" >/dev/null
expect "render --open lists user actions" 0 "- [user-action] 2026-10-20 fix-x: Fix x by hand" render --open
has "render --open summarises backlog" "Backlog: 1 open; top: Later thing"
expect "render --cat" 0 "games/deadlock/launch/options: gamemoderun %command%" render --cat games
expect "render --cat --md" 0 "- gamemoderun %command% Probe: \`test -d /tmp\`" render --cat games/deadlock --md
has "render --md headings" "## Deadlock launch"
expect "render needs an argument" 2 "" render

# ---- fmt
expect "fmt --check on a fresh store" 0 "" fmt --check
python3 - "$KB_DIR/games.json" <<'EOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); open(p,"w").write(json.dumps(d))
EOF
expect "fmt --check detects drift" 1 "games.json is not formatted" fmt --check
expect "fmt rewrites" 0 "formatted games.json" fmt
expect "fmt --check clean again" 0 "" fmt --check
same "files end with a newline and use sorted keys" "$(tail -c1 "$KB_DIR/games.json" | xxd -p)" 0a

# ---- validate failures (each on a copy of the good store)
GOOD="$WORK/good"; cp -r "$KB_DIR" "$GOOD"
expect "validate good store" 0 "kb: ok" validate
bad() { # NAME FILE JQ-EXPR WANT
  local d="$WORK/bad"; rm -rf "$d"; cp -r "$GOOD" "$d"
  jq "$3" "$d/$2.json" >"$d/$2.json.new" && mv "$d/$2.json.new" "$d/$2.json"
  KB_DIR="$d" expect "validate: $1" 1 "$4" validate
}
bad "category without _title" games 'del(.deadlock._title)' "category needs a one-line _title"
bad "topic without _title" games 'del(._title)' "category needs a one-line _title"
bad "duplicate id" games '.deadlock.config.dup = .deadlock.config.autoexec' "duplicate id autoexec"
bad "duplicate alias" games '.deadlock.config._aliases = ["dl"]' "alias dl is used 2 times"
bad "alias shadows a topic" games '.deadlock.config._aliases = ["host"]' "shadows the topic host"
bad "dangling ref" games '.deadlock.config.r = {"$ref": "no-such-id"}' "ref to unknown id no-such-id"
bad "ref with extra keys" games '.deadlock.config.r = {"$ref": "options", "x": 1}' "a ref is exactly"
bad "ref to a ref" games '.deadlock.config.r1 = {"$ref": "options"} | .deadlock.config.r2 = {"$ref": "games/deadlock/config/r1"}' "ref to a ref"
bad "ref in the home category" games '.deadlock.launch.r = {"$ref": "options"}' "ref in the home category"
bad "ref and link on one pair" games '.deadlock.config.r = {"$ref": "options"} | .deadlock.config.autoexec.links = [{"rel":"about","to":"options"}]' "both a ref here and linked"
bad "dangling link" games '.deadlock.config.autoexec.links = [{"rel":"about","to":"ghost"}]' "link to unknown id ghost"
bad "bad link rel" games '.deadlock.config.autoexec.links = [{"rel":"friend","to":"options"}]' "link must be"
bad "link to itself" games '.deadlock.config.autoexec.links = [{"rel":"about","to":"autoexec"}]' "link to itself"
bad "supersede cycle" games '.deadlock.config.autoexec |= (.superseded_by = "frame-cap" | .until = "2026-10-27" | .supersedes = ["frame-cap"]) | .deadlock.overlay."frame-cap" |= (.superseded_by = "autoexec" | .until = "2026-10-27" | .supersedes = ["autoexec"])' "supersede chain has a cycle"
bad "superseded_by unknown" games '.deadlock.config.autoexec |= (.superseded_by = "ghost" | .until = "2026-10-27")' "superseded_by unknown id ghost"
bad "superseded_by without until" games '.deadlock.config.autoexec.superseded_by = "options"' "requires until"
bad "supersede without back link" games '.deadlock.config.autoexec |= (.superseded_by = "options" | .until = "2026-10-27")' "does not list autoexec in supersedes"
bad "missing required field" games 'del(.deadlock.launch.options.source)' "fact requires source"
bad "fact probe malformed" games '.deadlock.launch.options.probe = {"cmd": "", "none": "x"}' "probe must be"
bad "probe timeout not positive" games '.deadlock.launch.options.probe.timeout = -1' "probe.timeout"
bad "unknown type" games '.deadlock.config.autoexec.type = "gizmo"' "type must be one of"
bad "title too long" games ".deadlock.config.autoexec.title = \"$(printf 'x%.0s' {1..101})\"" "title must be a single line"
bad "bad id" games '.deadlock.config.autoexec.id = "Bad_Id"' "id must be a slug"
bad "bad updated date" games '.deadlock.config.autoexec.updated = "yesterday"' "updated must be"
bad "artifact written_by" games '.deadlock.config.autoexec.written_by = "robot"' "written_by must be"
bad "item status/closed" setup '.items.later |= (.status = "done" | .closed = null)' "done requires a closed date"
bad "item kind" setup '.items.later.kind = "someday"' "kind must be"
bad "decision without body" setup 'del(.decisions."use-kb".body)' "decision requires body"
bad "bad entry name" games '.deadlock.config."Bad Name" = .deadlock.config.autoexec | del(.deadlock.config."Bad Name".id) | .deadlock.config."Bad Name".id = "zz"' "name must match"
if [ "$HAVE_SHFMT" = 1 ]; then
  bad "unsafe probe" games '.deadlock.launch.options.probe.cmd = "rm -rf /tmp/zz"' "probe is not read-only"
fi
d="$WORK/bad"; rm -rf "$d"; cp -r "$GOOD" "$d"; echo '{ nope' >"$d/games.json"
KB_DIR="$d" expect "validate: malformed JSON" 1 "malformed JSON" validate
rm -rf "$d"; cp -r "$GOOD" "$d"; jq 'del(._schema)' "$d/games.json" >"$d/x" && mv "$d/x" "$d/games.json"
KB_DIR="$d" expect "validate: missing _schema" 1 "_schema must be 1" validate
KB_DIR="$d" expect "write refuses what makes the store invalid" 1 "nothing written" add host/box/bad --type fact --title "No probe" --value v
rm -rf "$d"; cp -r "$GOOD" "$d"; jq '.deadlock.config.autoexec.value = "'"$(printf 'v%.0s' {1..250})"'"' "$d/games.json" >"$d/x" && mv "$d/x" "$d/games.json"
KB_DIR="$d" expect "validate: long value warns, passes" 0 "over 200" validate
rm -rf "$d"; cp -r "$GOOD" "$d"; "$K" mkcat host/box/empty --title Empty >/dev/null 2>&1; KB_DIR="$d" "$K" mkcat host/box/empty --title Empty >/dev/null
KB_DIR="$d" expect "validate --orphans: empty category" 0 "host/box/empty: empty category" validate --orphans
KB_DIR="$d" expect "validate --orphans: fact without probe" 0 "fact has no probe" validate --orphans
KB_DIR="$d" expect "validate --json" 0 '"errors": []' validate --json

# ---- schema too new
rm -rf "$d"; cp -r "$GOOD" "$d"; jq '._schema = 2' "$d/host.json" >"$d/x" && mv "$d/x" "$d/host.json"
for c in "ls" "validate" "fmt --check" "find box" "render --open" "probe"; do
  # shellcheck disable=SC2086
  KB_DIR="$d" expect "schema too new: $c exits 3" 3 "newer" $c
done
KB_DIR="$d" expect "schema too new: add exits 3" 3 "newer" add games/deadlock/launch/zz --type pitfall --title zz

# ---- concurrency
"$K" mkcat setup/par --title Parallel >/dev/null
for i in $(seq 1 16); do "$K" add setup/par/p$i --type pitfall --title "Parallel entry number $i" --dup-ok >/dev/null 2>"$WORK/par$i.err" & done
wait
same "16 parallel adds all landed" "$("$K" ls setup/par | wc -l)" 16
same "parallel adds got unique ids" "$("$K" search . --under setup/par | grep -c '^setup/par')" 16
expect "store valid after parallel adds" 0 "kb: ok" validate
"$K" add setup/par/same --type pitfall --title "Race one" --dup-ok >/dev/null 2>&1 &
"$K" add setup/par/same --type pitfall --title "Race two" --dup-ok >/dev/null 2>&1 &
wait
same "same-name race: exactly one wins" "$("$K" ls setup/par | grep -c '^same ')" 1
ls "$KB_DIR"/.kb-*.tmp >/dev/null 2>&1 && fail "temp files left behind" || echo "ok    no temp files left behind"

# ---- import-state / export-state
cat >"$WORK/state.json" <<'EOF'
{"items": [
  {"id":"zeta","kind":"backlog","title":"Backlog low","detail":"line one\nline two\n","area":"setup","priority":5,"opened":"2026-10-02","closed":null,"status":"open"},
  {"id":"alpha","kind":"backlog","title":"Backlog high → arrow","detail":"","area":"game","priority":1,"opened":"2026-10-03","closed":null,"status":"open"},
  {"id":"wait-b","kind":"waiting","title":"Waiting b","detail":"Launch: x -- %command%","area":"game","priority":null,"opened":"2026-10-05","closed":null,"status":"open"},
  {"id":"wait-a","kind":"waiting","title":"Waiting a","detail":"d","area":"game","priority":null,"opened":"2026-10-05","closed":null,"status":"open"},
  {"id":"act-1","kind":"user-action","title":"Do the thing","detail":"multi\n\nparagraph","area":"host","priority":null,"opened":"2026-10-09","closed":null,"status":"open"},
  {"id":"act-0","kind":"user-action","title":"Done thing","detail":"x","area":"host","priority":null,"opened":"2026-10-01","closed":"2026-10-08","status":"done"},
  {"id":"mid","kind":"backlog","title":"Backlog mid","detail":"m","area":"setup","priority":3,"opened":"2026-10-01","closed":null,"status":"open"}
]}
EOF
IMP="$WORK/imp"; mkdir -p "$IMP"
KB_DIR="$IMP/kb" expect "import-state" 0 "imported 7 items under setup/items" import-state "$WORK/state.json"
KB_DIR="$IMP/kb" expect "import-state again refused" 1 "already holds" import-state "$WORK/state.json"
KB_DIR="$IMP/kb" expect "import-state --replace" 0 "imported 7" import-state "$WORK/state.json" --replace
KB_DIR="$IMP/kb" expect "imported store validates" 0 "kb: ok" validate
KB_DIR="$IMP/kb" expect "imported item keeps its id" 0 "type: item" get act-1
KB_DIR="$IMP/kb" "$K" export-state >"$WORK/exported.json"
same "export is a state.json (semantic round trip)" \
  "$(jq -S '.items | sort_by(.id)' "$WORK/exported.json")" "$(jq -S '.items | sort_by(.id)' "$WORK/state.json")"
same "export validates with state.sh" "$(bash "$STATE" -f "$WORK/exported.json" validate; echo $?)" 0
want="$(bash "$STATE" -f "$WORK/state.json" list --all | awk '{print $1}' | paste -sd' ')"
got="$(KB_DIR="$IMP/kb" "$K" ls setup/items --all | awk '{print $1}' | paste -sd' ')"
same "seq preserves state.sh order" "$got" "$want"
same "export order is state.sh order" "$(jq -r '[.items[].id] | join(" ")' "$WORK/exported.json")" "$want"
KB_DIR="$IMP/kb" expect "export-state --out" 0 "" export-state --out "$WORK/out2.json"
same "export --out equals stdout" "$(cat "$WORK/out2.json")" "$(cat "$WORK/exported.json")"
echo '{"items": [{"id":"Bad_ID","kind":"x"}]}' >"$WORK/bad-state.json"
KB_DIR="$IMP/bad" expect "import-state rejects invalid items" 1 "must be a slug" import-state "$WORK/bad-state.json"
expect "import-state of a missing file" 1 "cannot read" import-state "$WORK/none.json"

# ---- import-facts
cat >"$WORK/facts.md" <<'EOF'
# The box

Intro prose that is not a bullet.

## Hardware

- Ryzen 7 6800H with 14 GB RAM and a Radeon 680M. Probe: `grep -q Ryzen /proc/cpuinfo`
- The GPU is an NVIDIA RTX 3050 Ti with 4 GB VRAM and a proprietary driver, which the long description keeps going about until it passes eighty characters. Probe: `test -d /tmp`
- `~/.ssh` holds the user's keys. Probe: none (policy)
- A wrapped bullet that continues
  on a second line. Probe: `test -e /tmp`

## Safe to reclaim, in this order

1. Package cache: `paccache -rk2`.
2. Journal vacuum.
EOF
FI="$WORK/fi"; mkdir -p "$FI"
KB_DIR="$FI/kb" "$K" mkcat host --title Hosts >/dev/null
KB_DIR="$FI/kb" expect "import-facts" 0 "imported 4 facts under host/box/hardware" import-facts "$WORK/facts.md" --cat host/box/hardware
KB_DIR="$FI/kb" expect "imported facts validate" 0 "kb: ok (4 entries" validate
KB_DIR="$FI/kb" "$K" search . --type fact >"$WORK/facts-found.txt"
same "numbered items are not imported" "$(grep -c -i 'paccache\|vacuum' "$WORK/facts-found.txt")" 0
expect "import-facts --help warns that numbered lists are skipped" 0 "Numbered lists" import-facts --help
KB_DIR="$FI/kb" expect "fact value drops the probe suffix" 0 "value: Ryzen 7 6800H with 14 GB RAM and a Radeon 680M." get host/box/hardware/ryzen-7-6800h-with-14-gb
KB_DIR="$FI/kb" expect "fact probe filled" 0 "probe: grep -q Ryzen /proc/cpuinfo" get host/box/hardware/ryzen-7-6800h-with-14-gb
KB_DIR="$FI/kb" expect "fact source filled" 0 "/facts.md :: bullet at line 7" get host/box/hardware/ryzen-7-6800h-with-14-gb
KB_DIR="$FI/kb" expect "probe: none kept" 0 "probe: none (policy)" get host/box/hardware/ssh-holds-the-user-s-keys
KB_DIR="$FI/kb" expect "wrapped bullet joined" 0 "A wrapped bullet that continues on a second line." get host/box/hardware/a-wrapped-bullet-that-continues-on
t="$(KB_DIR="$FI/kb" "$K" get host/box/hardware/the-gpu-is-an-nvidia-rtx --field title)"
[ "${#t}" -le 80 ] && echo "ok    title is at most 80 chars" || fail "title too long: $t"
printf -- '- No probe on this one.\n' >"$WORK/noprobe.md"
KB_DIR="$FI/kb" expect "bullet without a probe refused" 1 "has no Probe:" import-facts "$WORK/noprobe.md" --cat host/box/other
KB_DIR="$FI/kb" expect "nothing imported after refusal" 1 "not found" ls host/box/other

# ---- probe
PB="$WORK/pb"; mkdir -p "$PB"
export KB_DIR="$PB/kb"
"$K" mkcat host --title Hosts >/dev/null; "$K" mkcat host/h --title H --alias h >/dev/null
addf() { "$K" add "host/h/$1" --type fact --title "$2" --value "$2" "${@:3}" --source-path s --source-locator l >/dev/null; }
if [ "$HAVE_SHFMT" = 1 ]; then
  addf pass "Probe passes" --probe 'test -d /tmp'
  addf fail "Probe fails" --probe 'test -d /nonexistent-kb-dir'
  addf none "Probe none" --probe-none "policy"
  addf hang "Probe hangs" --probe 'cat /dev/zero | wc'
  expect "probe: pass, fail, unchecked" 1 "FAIL host/h/fail \`test -d /nonexistent-kb-dir\`" probe host/h --budget 2
  has "probe: unchecked none fact" "UNCHECKED host/h/none -> Probe: none (policy)"
  has "probe: budget leaves a hang unchecked" "UNCHECKED host/h/hang -> not finished within 2s"
  has "probe: summary" "probe: 1 ok, 1 failed, 2 unchecked, 0 fresh (skipped)"
  lacks "probe: passing probe is quiet" "host/h/pass"
  expect "probe -v shows ok" 1 "ok host/h/pass" probe host/h --budget 2 -v
  expect "probe single fact by path" 0 "probe: 1 ok" probe host/h/pass
  expect "probe by alias" 0 "probe: 1 ok" probe h/pass
  expect "probe --cat" 1 "FAIL host/h/fail" probe --cat host/h --budget 2
  expect "probe --json" 1 '"status": "fail"' probe host/h --budget 2 --json
  expect "probe nothing selected" 0 "probe: 0 ok" probe host/h/none
  "$K" rm host/h/hang >/dev/null
  addf slow "Probe with own timeout" --probe 'cat /dev/zero | wc' --probe-timeout 1
  expect "probe: per-probe timeout fails" 1 "timed out after 1s" probe host/h/slow --budget 10
  "$K" rm host/h/slow >/dev/null
  # verified cache and --stale
  [ -f "$KB_CACHE" ] && echo "ok    verified cache written" || fail "no verified cache"
  same "cache records the pass, not the fail" "$(jq -r '.verified | keys | join(",")' "$KB_CACHE")" "local:pass"
  expect "stale: fresh probe skipped" 1 "1 fresh (skipped)" probe host/h --stale 30d
  lacks "stale: fresh probe not rerun" "host/h/pass"
  jq '.verified["local:pass"] = "2020-01-01T00:00:00Z"' "$KB_CACHE" >"$WORK/c" && mv "$WORK/c" "$KB_CACHE"
  expect "stale: old verification reruns" 1 "probe: 1 ok, 1 failed, 1 unchecked, 0 fresh" probe host/h --stale 30d
  same "stale: cache refreshed" "$(jq -r '.verified["local:pass"] | startswith("2020")' "$KB_CACHE")" false
  expect "bad --stale" 2 "bad duration" probe --stale soon
  echo '{"_schema":1,"verified":{"local:pass":"garbage","local:fail":5}}' >"$KB_CACHE"
  expect "corrupt cache timestamp is treated as never verified" 1 "probe: 1 ok, 1 failed, 1 unchecked, 0 fresh" probe host/h --stale 30d
  # ssh: a stand-in ssh runs the script locally and records the host
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/ssh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/ssh-args"
while [ "\$1" = -o ]; do shift 2; done
[ "\$1" = -- ] && shift
echo "\$1" >> "$WORK/ssh-hosts"
shift
exec "\$@"
EOF
  chmod +x "$WORK/bin/ssh"
  PATH="$WORK/bin:$PATH" expect "probe --ssh runs through ssh" 1 "FAIL host/h/fail" probe host/h --ssh khost --budget 3
  same "ssh got the host" "$(sort -u "$WORK/ssh-hosts")" khost
  grep -q -- ' -- khost bash -s' "$WORK/ssh-args" && echo "ok    ssh argv has -- before the host" || fail "ssh argv: $(head -1 "$WORK/ssh-args")"
  PATH="$WORK/bin:$PATH" expect "probe --ssh rejects a host starting with -" 2 "must not start with" probe host/h --ssh=-oProxyCommand=x
  same "rejected ssh host never reached ssh" "$(wc -l <"$WORK/ssh-args")" "$(wc -l <"$WORK/ssh-hosts")"
  same "ssh verifications are cached per host" "$(jq -r '.verified | keys | join(",")' "$KB_CACHE")" "khost:pass,local:pass"
  # a probe refused as unsafe in a store written by hand is reported FAIL and never run
  jq '.h.fail.probe.cmd = "touch /tmp/kb-test-ran"' "$KB_DIR/host.json" >"$WORK/x" && mv "$WORK/x" "$KB_DIR/host.json"
  expect "probe refuses an unsafe command" 1 "refused" probe host/h/fail
  [ ! -e /tmp/kb-test-ran ] && echo "ok    refused probe was not run" || { fail "unsafe probe ran"; rm -f /tmp/kb-test-ran; }
  # without shfmt nothing runs
  mkdir -p "$WORK/none"; ln -sf "$(command -v python3)" "$WORK/none/python3"
  jq '.h.fail.probe.cmd = "test -d /tmp"' "$KB_DIR/host.json" >"$WORK/x" && mv "$WORK/x" "$KB_DIR/host.json"
  rm -f "$KB_CACHE"
  OUT="$(env PATH="$WORK/none" "$K" probe host/h 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && grep -qF "shfmt not installed" <<<"$OUT"; then echo "ok    probe without shfmt: UNCHECKED, exit 0"; else fail "probe without shfmt: exit $RC" "$OUT"; fi
else
  echo "SKIP  shfmt not installed: probe tests skipped"
fi

# ---- review fixes
export KB_DIR="$WORK/kb" KB_CACHE="$WORK/cache/verified.json"
# 1. a malformed or unreadable topic file blocks every write and is never overwritten
d="$WORK/mal"; rm -rf "$d"; cp -r "$GOOD" "$d"
printf '<<<<<<< HEAD\n{"_schema": 1}\n=======\n>>>>>>> x\n' >"$d/setup.json"; cp "$d/setup.json" "$WORK/setup.orig"
KB_DIR="$d" expect "malformed topic: mkcat refused" 1 "setup.json" mkcat setup --title New
KB_DIR="$d" expect "malformed topic: add to another topic refused" 1 "refusing to write" add games/deadlock/launch/zz --type pitfall --title zz
KB_DIR="$d" expect "malformed topic: import-state refused" 1 "setup.json" import-state "$WORK/state.json"
KB_DIR="$d" expect "malformed topic: import-facts refused" 1 "setup.json" import-facts "$WORK/facts.md" --cat setup/facts
KB_DIR="$d" expect "malformed topic: rm refused" 1 "refusing to write" rm games/deadlock/launch/options --force
cmp -s "$d/setup.json" "$WORK/setup.orig" && echo "ok    malformed topic file left untouched" || fail "malformed topic file was changed"
printf '{"_schema": 1, "_title": "x", "a": {"_title": "A"}, "a": {"_title": "B"}}' >"$d/setup.json"
KB_DIR="$d" expect "duplicate JSON keys are malformed" 1 "duplicate key" validate
KB_DIR="$d" expect "duplicate JSON keys block writes" 1 "refusing to write" mkcat host/z --title z
rm -rf "$d"; cp -r "$GOOD" "$d"; chmod 000 "$d/setup.json"
KB_DIR="$d" expect "unreadable topic blocks writes" 1 "setup.json" mkcat host/z --title z
chmod 644 "$d/setup.json"

# 3. export-state --out with a relative path
(cd "$WORK" && KB_DIR="$IMP/kb" "$K" export-state --out rel-out.json >/dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -s "$WORK/rel-out.json" ] && echo "ok    export-state --out relative.json" || fail "export-state --out relative.json produced nothing"

# 4. validate holes
expect "add: an id never equals a topic name" 0 "(id games-2)" add setup/decisions/games --type pitfall --title "Games pitfall"
expect "add: an id never equals an alias" 0 "(id deadlock-2)" add setup/decisions/deadlock --type pitfall --title "Alias pitfall zzz"
bad "id equal to a topic" setup '.decisions."use-kb".id = "games"' "equals the topic games"
bad "id equal to an alias" setup '.decisions."use-kb".id = "deadlock"' "equals an alias"
bad "unknown field" games '.deadlock.config.autoexec.bogus = 1' "unknown field bogus for type artifact"
bad "unknown field on a fact" games '.deadlock.launch.options.steps = ["x"]' "unknown field steps for type fact"
expect "add: --field cannot smuggle unknown fields" 1 "unknown field bogus" add setup/decisions/smuggle --type pitfall --title "Smuggle" --field bogus=1
bad "open item with a closed date" setup '.items.later.closed = "2026-10-01"' "an open item must have closed null"
bad "duplicate item seq" setup '.items.later.seq = .items."fix-x".seq' "duplicate item seq"

# 5. fmt takes the lock
if command -v flock >/dev/null && command -v timeout >/dev/null; then
  ( flock -x 9; sleep 3 ) 9>"$KB_DIR/.lock" &
  sleep 0.5
  timeout 1 "$K" fmt >/dev/null 2>&1; rc=$?
  wait
  same "fmt waits for the store lock" "$rc" 124
fi

# 6. a crash between renames never loses an entry (destination file is renamed before the source file)
python3 -I - "$K" "$WORK" <<'PYEOF' || failures=$((failures + 1))
import importlib.machinery, importlib.util, json, os, shutil, sys
kbp, work = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("kbmod", kbp)
spec = importlib.util.spec_from_loader("kbmod", loader)
kb = importlib.util.module_from_spec(spec)
loader.exec_module(kb)
d = os.path.join(work, "crash"); shutil.rmtree(d, ignore_errors=True)
os.makedirs(d)
os.environ["KB_DIR"] = d
def topic(name, children):
    t = {"_schema": 1, "_title": name}; t.update(children)
    open(os.path.join(d, name + ".json"), "w").write(kb.dumps(t))
ent = {"id": "e1", "type": "pitfall", "title": "An entry", "updated": "2026-10-27"}
topic("games", {"c": {"_title": "C", "e1": ent}})
topic("host", {"c": {"_title": "C"}})
real = os.replace
calls = []
def flaky(a, b):
    calls.append(b)
    if len(calls) == 2:
        raise OSError("crash")
    return real(a, b)
def move(st, idx):
    e = st.topics["games"]["c"].pop("e1")
    st.topics["host"]["c"]["e1"] = e
os.replace = flaky
try:
    kb.mutate(move)
except OSError:
    pass
os.replace = real
found = [t for t in ("games", "host") if "e1" in json.load(open(os.path.join(d, t + ".json")))["c"]]
if found:
    print("ok    crash between renames keeps the entry (found in %s)" % ",".join(found))
else:
    print("FAIL  crash between renames lost the entry"); sys.exit(1)
PYEOF

# 7. file modes and .gitignore
same "topic files are mode 644" "$(stat -c %a "$KB_DIR/games.json")" 644
grep -qxF 'docs/kb/.lock' "$ROOT/.gitignore" && grep -qxF 'docs/kb/.kb-*.tmp' "$ROOT/.gitignore" \
  && echo "ok    .gitignore covers docs/kb/.lock and .kb-*.tmp" || fail ".gitignore lacks docs/kb/.lock or docs/kb/.kb-*.tmp"

# 8. smaller edges
expect "set CATEGORY --value is a usage error" 2 "category only takes" set games/deadlock --value x
expect "ls --json ENTRY prints JSON" 0 '"entry": {' ls options --json
expect "get --all is not an option" 2 "" get games/deadlock --all

# 9. ambiguous alias
rm -rf "$d"; cp -r "$GOOD" "$d"; jq '.deadlock.config._aliases = ["dlx"] | .deadlock.launch._aliases = ["dlx"]' "$d/games.json" >"$d/x" && mv "$d/x" "$d/games.json"
KB_DIR="$d" expect "ambiguous alias says ambiguous" 1 "ambiguous: alias dlx matches games/deadlock/config, games/deadlock/launch" ls dlx

# 11/12. import-state extras, --replace, and add --type item keeps state.sh order
jq '.items[0].note = "extra"' "$WORK/state.json" >"$WORK/state-extra.json"
KB_DIR="$IMP/extra" expect "import-state rejects extra item keys" 1 "keys kb items do not keep: note" import-state "$WORK/state-extra.json"
export KB_DIR="$IMP/kb"
"$K" add setup/items/stray --type item --kind backlog --priority 9 --title "Stray item" >/dev/null
expect "import-state --replace clears the old items" 0 "imported 7" import-state "$WORK/state.json" --replace
expect "stray item gone after --replace" 1 "not found" get setup/items/stray
expect "no seq collision after --replace" 0 "kb: ok" validate
"$K" add setup/items/new-mid --type item --kind backlog --priority 2 --title "Backlog between" >/dev/null
"$K" add setup/items/new-first --type item --kind user-action --opened 2026-09-01 --title "Earlier action" >/dev/null
"$K" add setup/items/new-last --type item --kind backlog --priority 99 --title "Backlog last" >/dev/null
"$K" export-state >"$WORK/exp2.json"
want="$(bash "$STATE" -f "$WORK/exp2.json" list --all | awk '{print $1}' | paste -sd' ')"
same "new items follow state.sh order (priority, kind)" "$(jq -r '[.items[].id] | join(" ")' "$WORK/exp2.json")" "$want"
same "new-mid sits between alpha and mid" "$(jq -r '[.items[].id] | join(" ")' "$WORK/exp2.json" | grep -o 'alpha new-mid mid')" "alpha new-mid mid"
same "render --open lists backlog in that order" "$("$K" render --open | grep '^Backlog')" "Backlog: 5 open; top: Backlog high → arrow; Backlog between; Backlog mid"
expect "store valid after inserting items" 0 "kb: ok" validate
expect "add --help documents the seq rule" 0 "state.sh order" add --help
export KB_DIR="$WORK/kb"

# import-state --replace removes only direct item entries; nothing else
R3="$WORK/rep"; rm -rf "$R3"
KB_DIR="$R3" "$K" mkcat items --title Items >/dev/null
KB_DIR="$R3" "$K" add items/old-item --type item --kind backlog --priority 9 --title "Old item" >/dev/null
KB_DIR="$R3" "$K" add items/note --type pitfall --title "Keep this note" >/dev/null
KB_DIR="$R3" "$K" mkcat items/sub --title Sub >/dev/null
KB_DIR="$R3" "$K" add items/sub/deep --type pitfall --title "Deep entry stays" >/dev/null
KB_DIR="$R3" expect "import --replace into a mixed category" 0 "imported 7" import-state "$WORK/state.json" --cat items --replace
KB_DIR="$R3" expect "--replace keeps non-item entries" 0 "Keep this note" ls items
KB_DIR="$R3" expect "--replace keeps subcategories and their entries" 0 "Deep entry stays" ls items/sub
KB_DIR="$R3" expect "--replace removed the old item" 1 "not found" get old-item
# refuse when removal would orphan a link from outside the removed set
KB_DIR="$R3" "$K" add items/sub/stale --type item --kind backlog --priority 8 --title "Stale item" >/dev/null
KB_DIR="$R3" "$K" add items/linker --type pitfall --title "Links the stale one" --link about=stale >/dev/null
cp "$R3/items.json" "$WORK/items.before"
KB_DIR="$R3" expect "--replace refuses to orphan a link from outside" 1 "would orphan" import-state "$WORK/state.json" --cat items/sub --replace
cmp -s "$R3/items.json" "$WORK/items.before" && echo "ok    refused --replace wrote nothing" || fail "refused --replace changed the store"
# a topic file whose name is not a slug blocks writes
rm -rf "$d"; cp -r "$GOOD" "$d"; cp "$d/games.json" "$d/Bad_Name.json"
KB_DIR="$d" expect "bad topic file name blocks writes" 1 "Bad_Name.json" mkcat host/z --title z
# a failed rename leaves no staged temp files behind
python3 -I - "$K" "$WORK" <<'PYEOF' || failures=$((failures + 1))
import importlib.machinery, importlib.util, os, shutil, sys
loader = importlib.machinery.SourceFileLoader("kbmod2", sys.argv[1])
kb = importlib.util.module_from_spec(importlib.util.spec_from_loader("kbmod2", loader))
loader.exec_module(kb)
d = os.path.join(sys.argv[2], "crash2"); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
os.environ["KB_DIR"] = d
for n in ("a", "b"):
    open(os.path.join(d, n + ".json"), "w").write(kb.dumps({"_schema": 1, "_title": n}))
real, n = os.replace, [0]
def flaky(a, b):
    n[0] += 1
    if n[0] == 1:
        raise OSError("boom")
    return real(a, b)
def touch(st, idx):
    st.topics["a"]["_title"] = "A2"; st.topics["b"]["_title"] = "B2"
os.replace = flaky
try:
    kb.mutate(touch)
except OSError:
    pass
os.replace = real
left = [f for f in os.listdir(d) if f.endswith(".tmp")]
print("ok    failed rename leaves no .kb-*.tmp files" if not left else "FAIL  leftover temp files: %s" % left)
sys.exit(1 if left else 0)
PYEOF

# 2. import-facts on a host-facts Markdown fixture (the real files are gone): one fact per bullet, same probes as probe-facts.py
REAL="$WORK/factsmd"; mkdir -p "$REAL"
cat >"$REAL/fx.md" <<'MD'
# Fixture host facts

- Tmp is a directory. Probe: `test -d /tmp`
- Nothing at this path. Probe: `test -d /nonexistent-kb-fixture`
- Shell pitfalls. Probe: none (the zsh part is seen only from inside the Bash tool)
- Root exists. Probe: `test -d /`
MD
RI="$WORK/real"; rm -rf "$RI"
KB_DIR="$RI/kb" "$K" mkcat host --title Hosts >/dev/null
for h in fx; do
  KB_DIR="$RI/kb" expect "fixture $h.md imports" 0 "imported" import-facts "$REAL/$h.md" --cat host/$h
  same "fixture $h.md: one fact per bullet" "$(jq --arg h "$h" '[.[$h] | .. | objects | select(.type == "fact")] | length' "$RI/kb/host.json" 2>/dev/null)" \
    "$(grep -c '^- ' "$REAL/$h.md")"
done
KB_DIR="$RI/kb" expect "fixture validates" 0 "kb: ok" validate
KB_DIR="$RI/kb" expect "trailing prose after the probe is kept in the value" 0 "the zsh part" search 'the zsh part'
if [ "$HAVE_SHFMT" = 1 ]; then
  pfl="$(python3 "$ROOT/instruction-layer/scripts/probe-facts.py" --budget 25 "$REAL/fx.md" | sed -n 's/^STALE [^ ]*:\([0-9]*\) .*/\1/p' | sort -n | paste -sd,)"
  kbj="$(KB_DIR="$RI/kb" "$K" probe host/fx --budget 25 --json)"
  kbl="$(jq -r '[.results[] | select(.status == "fail") | .locator | sub("bullet at line "; "") | tonumber] | sort | join(",")' <<<"$kbj")"
  same "kb probe fails the same bullets as probe-facts.py" "$kbl" "$pfl"
  same "kb runs as many probes as probe-facts.py" "$(jq '[.results[] | select(.cmd)] | length' <<<"$kbj")" \
    "$(python3 -c "
import re,sys
rx=re.compile(r'Probe: \`([^\`]+)\`')
print(sum(len(rx.findall(l)) for l in open(sys.argv[1])))" "$REAL/fx.md")"
fi
# a probe in a continuation line does not replace the parent's; ')' inside a none reason is kept
printf -- '- Parent text. Probe: `test -d /tmp`\n  continuation text. Probe: `test -d /nonexistent`\n- Policy (with parens). Probe: none (policy (really); no probe)\n' >"$WORK/cont.md"
KB_DIR="$RI/c" "$K" mkcat host --title H >/dev/null
KB_DIR="$RI/c" "$K" import-facts "$WORK/cont.md" --cat host/c >/dev/null
KB_DIR="$RI/c" expect "continuation Probe: does not replace the parent's" 0 "probe: test -d /tmp" get host/c/parent-text-continuation-text-probe-test
KB_DIR="$RI/c" expect "none reason keeps inner )" 0 "probe: none (policy (really); no probe)" get host/c/policy-with-parens

# ---- an alias is found when typed with a space instead of a hyphen
expect "alias with a space resolves" 0 "launch-options" ls "launch options"

# ---- --unset with a dotted key removes one nested field
expect "add: procedure with thresholds" 0 "" add host/box/memory/steps --type procedure --title "Steps" --step one --field thresholds.a=1 --field thresholds.b=2
expect "set --unset thresholds.a" 0 "updated" set host/box/memory/steps --unset thresholds.a
expect "dotted unset removed only the nested key" 0 '{"b": 2}' get host/box/memory/steps --field thresholds
lacks "dotted unset removed a" '"a"'

# ---- store location and the main-branch write refusal (fake checkout <R> with sibling <R>-worktrees/claude)
FK="$WORK/fake"; rm -rf "$FK"; mkdir -p "$FK/skills/scripts" "$FK/skills/docs/kb"
cp "$K" "$FK/skills/scripts/kb"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
KBF="env -u KB_DIR KB_CACHE=$WORK/fcache.json $FK/skills/scripts/kb"
env -u KB_DIR "$FK/skills/scripts/kb" mkcat zed --title Zed >/dev/null   # no git yet: allowed
git -C "$FK/skills" init -q -b main && git -C "$FK/skills" add -A && git -C "$FK/skills" commit -q -m init
OUT="$($KBF mkcat main-only --title X 2>&1)"; RC=$?
same "no claude branch: writes to the checkout's own docs/kb" "$RC" 0
git -C "$FK/skills" add -A && git -C "$FK/skills" commit -q -m two
git -C "$FK/skills" branch claude
OUT="$($KBF mkcat blocked --title X 2>&1)"; RC=$?
same "main branch with a claude branch: write refused (exit 1)" "$RC" 1
has "refusal names the worktree path" "$FK/skills-worktrees/claude"
[ ! -e "$FK/skills/docs/kb/blocked.json" ] && echo "ok    refused write left the store untouched" || fail "refused write created a file"
OUT="$($KBF ls 2>&1)"; RC=$?; same "reads are not refused" "$RC" 0
OUT="$($KBF fmt 2>&1)"; RC=$?; same "fmt (a write) is refused too" "$RC" 1
OUT="$($KBF fmt --check 2>&1)"; RC=$?; same "fmt --check is not refused" "$RC" 0
mkdir -p "$FK/mine"
OUT="$(KB_DIR="$FK/mine" KB_CACHE="$WORK/fcache.json" "$FK/skills/scripts/kb" mkcat alt --title Alt 2>&1)"; RC=$?
same "KB_DIR set explicitly overrides the refusal" "$RC" 0
git -C "$FK/skills" worktree add -q "$FK/skills-worktrees/claude" claude
OUT="$($KBF mkcat viaworktree --title V 2>&1)"; RC=$?
same "sibling claude worktree exists: write succeeds" "$RC" 0
[ -f "$FK/skills-worktrees/claude/docs/kb/viaworktree.json" ] && echo "ok    write landed in the claude worktree store" || fail "write did not land in the worktree"
[ ! -e "$FK/skills/docs/kb/viaworktree.json" ] && echo "ok    main checkout store untouched" || fail "main store was written"
OUT="$($KBF ls 2>&1)"; has "lookup follows the sibling claude worktree" "viaworktree"
OUT="$(KB_DIR="$FK/mine" "$FK/skills/scripts/kb" ls 2>&1)"; has "KB_DIR wins over the sibling worktree" "alt"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# ---- warning and context entries
W="$WORK/wkb"; rm -rf "$W"; mkdir -p "$W"
export KB_DIR="$W"
"$K" mkcat host --title Host >/dev/null; "$K" mkcat host/box --title Box >/dev/null; "$K" mkcat host/box/warnings --title Warnings >/dev/null
expect "add --help lists warning" 0 "slow-lookup" add --help
has "add --help lists context" "context"
expect "find --type warning with nothing recorded misses" 1 "not recorded" find --type warning
expect "add: warning" 0 "added host/box/warnings/swap-lookup" add host/box/warnings/swap-lookup --type warning --title "Swap lookup took 7 calls" \
  --scenario "checking swap settings" --kind slow-lookup --steps 7 --noise "read unrelated fstab" --shortcut "kb get host/box/memory/swap"
expect "add: warning without steps refused" 1 "warning requires steps" add host/box/warnings/nosteps --type warning --title "No steps" --scenario s --kind slow-lookup
expect "add: warning with bad kind refused" 1 "kind must be irrelevant-info or slow-lookup" add host/box/warnings/badkind --type warning --title "Bad kind" --scenario s --kind noisy --steps 2
expect "add: warning with non-integer steps refused" 1 "steps" add host/box/warnings/badsteps --type warning --title "Bad steps" --scenario s --kind slow-lookup --field steps=\"x\"
expect "add: warning with unknown field refused" 1 "unknown field" add host/box/warnings/unk --type warning --title "Unknown field" --scenario s --kind slow-lookup --steps 1 --field extra=1
expect "add: context" 0 "added host/box/warnings/boot-context" add host/box/warnings/boot-context --type context --title "Boot troubleshooting context" \
  --scenario "diagnosing a slow boot" --body "boot goes through the encrypted root first" --body "the second disk is mounted late"
expect "add: context without body refused" 1 "context requires body" add host/box/warnings/nobody --type context --title "No body" --scenario s
expect "add: context without scenario refused" 1 "context requires scenario" add host/box/warnings/noscen --type context --title "No scenario" --body b
expect "find without WORDS, --type or --under is a usage error" 2 "needs --type or --under" find
expect "find --type warning with no words" 0 "swap-lookup" find --type warning
lacks "find --type warning leaves out context" "boot-context"
expect "find --type context under a category" 0 "boot-context" find --type context --under host/box
expect "get warning shows steps" 0 "7" get host/box/warnings/swap-lookup --field steps
expect "render lists warnings" 0 "swap-lookup" render --cat host/box/warnings
expect "validate with warning and context" 0 "kb: ok" validate
expect "fmt --check with warning and context" 0 "" fmt --check
expect "export-state ignores warning and context" 0 '"items": []' export-state
export KB_DIR="$WORK/kb"

# ---- ask, lean output, hot sheet
A="$WORK/akb"; rm -rf "$A"; mkdir -p "$A"
export KB_DIR="$A"
"$K" mkcat games --title Games --alias gaming >/dev/null
"$K" mkcat games/dl --title "Deadlock" --alias deadlock >/dev/null
"$K" mkcat games/dl/mangohud --title "MangoHud settings" --alias mh >/dev/null
"$K" mkcat games/dl/warnings --title Warnings >/dev/null
"$K" add games/dl/mangohud/frame-cap --type fact --title "Frame cap by MangoHud" --value "fps_limit=90" --probe-none r \
  --source-path deadlock.conf --source-locator fps_limit --id fc --alias frame-cap --body "body line one" --field hot=true >/dev/null
"$K" add games/dl/mangohud/log-dir --type fact --title "MangoHud log directory" --value "logs go to ~/logs" --probe-none r \
  --source-path x --source-locator y --id logdir >/dev/null
"$K" add games/dl/mangohud/log-rotate --type fact --title "MangoHud log rotation" --value "logs rotate daily" --probe-none r \
  --source-path x --source-locator y --dup-ok >/dev/null
"$K" add games/dl/mangohud/old-cap --type fact --title "Old frame limiter" --value "fps_limit=60" --probe-none r \
  --source-path x --source-locator y --id old-cap >/dev/null
"$K" add games/dl/mangohud/new-cap --type fact --title "Frame limiter now" --value "fps_limit=90" --probe-none r \
  --source-path x --source-locator y --id new-cap --dup-ok >/dev/null
"$K" supersede old-cap new-cap >/dev/null
"$K" add games/dl/warnings/slow --type warning --title "Slow lookup" --scenario s --kind slow-lookup --steps 3 >/dev/null
expect "ask: exact alias gives one line" 0 "games/dl/mangohud/frame-cap | fps_limit=90 | deadlock.conf:fps_limit | verified: -" ask frame-cap
[ "$(wc -l <<<"$OUT")" -eq 2 ] && echo "ok    ask: line plus the warnings line only" || fail "ask: line count" "$OUT"
has "ask: warnings line" "warnings: games/dl/warnings (1)"
lacks "ask: no body by default" "body line one"
expect "ask --body appends body lines" 0 "body line one" ask frame-cap --body
expect "ask: exact id" 0 "games/dl/mangohud/log-dir |" ask logdir
expect "ask: exact title (case-insensitive)" 0 "games/dl/mangohud/log-rotate |" ask "mangohud log rotation"
expect "ask: ranked words" 0 "games/dl/mangohud/log-rotate |" ask rotation of logs
expect "ask: category lists children" 0 "frame-cap  Frame cap by MangoHud" ask mh
lacks "ask: category prints no bodies" "body line one"
expect "ask: ambiguity" 0 "AMBIGUOUS:" ask mangohud log
has "ask: ambiguity lists candidates" "games/dl/mangohud/log-dir | MangoHud log directory"
expect "ask: miss exits 1 with topics" 1 "not found" ask zzzqq
has "ask: miss names the topics" "games"
expect "ask: superseded entry is hidden" 0 "new-cap |" ask frame limiter
lacks "ask: superseded not listed" "old-cap"
expect "ask --under restricts" 1 "not found" ask frame cap --under games/dl/warnings
expect "ask --json" 0 '"match": "entry"' ask frame-cap --json
expect "ask without WORDS is a usage error" 2 "" ask
o1="$("$K" ask frame cap mangohud 2>&1)"; o2="$("$K" ask frame cap mangohud 2>&1)"
same "ask: deterministic" "$o1" "$o2"
expect "get is lean by default" 0 "body: 1 lines" get games/dl/mangohud/frame-cap
lacks "get: no body text" "body line one"
lacks "get: no JSON punctuation" "{"
has "get: keeps value" "value: fps_limit=90"
has "get: keeps source" "source: deadlock.conf :: fps_limit"
has "get: keeps probe" "probe: none (r)"
expect "get --body shows the body" 0 "  body line one" get games/dl/mangohud/frame-cap --body
expect "search is lean" 0 "games/dl/mangohud/frame-cap" search "body line"
lacks "search: no body snippet" "body line one"
expect "search --body shows the snippet" 0 "body line one" search "body line" --body
expect "links is lean" 0 "frame-cap" links frame-cap
expect "links has no --body" 2 "" links frame-cap --body
expect "hot: validate accepts hot" 0 "kb: ok" validate
expect "hot: sheet lists alias=value" 0 "frame-cap=fps_limit=90" hot
H1="$OUT"
grep -qE '^HOT [0-9a-f]{8}$' <<<"$(head -1 <<<"$H1")" && echo "ok    hot: header first" || fail "hot: header" "$H1"
[ "${#H1}" -le 4000 ] && echo "ok    hot: size within 4000" || fail "hot: size ${#H1}"
has "hot: cheat sheet" "kb ask WORDS first"
same "hot: deterministic" "$("$K" hot)" "$("$K" hot)"
"$K" set frame-cap --value "fps_limit=91" >/dev/null
expect "hot: hash changes with a hot value" 0 "frame-cap=fps_limit=91" hot
HASH91="$(head -1 <<<"$OUT")"
[ "$(head -1 <<<"$H1")" != "$HASH91" ] && echo "ok    hot: header hash changed" || fail "hot: hash unchanged"
expect "hot --write is gone" 2 "" hot --write
expect "hot --check is gone" 2 "" hot --check
"$K" set frame-cap --value "fps_limit=92" >/dev/null
expect "hot: hash changes again" 0 "frame-cap=fps_limit=92" hot
[ "$(head -1 <<<"$OUT")" != "$HASH91" ] && echo "ok    hot: hash differs per value" || fail "hot: same hash for different values"
"$K" set frame-cap --value "fps_limit=91" >/dev/null
expect "hot: hash is a function of the sheet" 0 "frame-cap=fps_limit=91" hot
same "hot: same sheet, same hash" "$(head -1 <<<"$OUT")" "$HASH91"
LONG="$(printf 'x%.0s' $(seq 1 121))"
expect "hot: value over 120 chars refused" 1 "at most 120" set frame-cap --value "$LONG"
expect "ask: category answer starts with at:" 0 "at: games/dl/mangohud/" ask mh
same "ask: category first line" "$(head -1 <<<"$OUT")" "at: games/dl/mangohud/"
expect "hot: needs an alias" 1 "needs an alias" set log-rotate --field hot=true
expect "hot: must be boolean" 1 "hot must be" set logdir --field hot=\"yes\"
export KB_DIR="$WORK/kb"

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
