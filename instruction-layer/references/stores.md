# Tool for each store

Use the tool, not the raw file: a raw read loads text the tool would filter, skips validation, and misses what the tool knows (ids, ordering, closed items, superseded entries). The Bash hook (`guard-bash.sh`, `raw-store-read.py`) blocks commands that name `docs/state.json` or a file under `docs/kb/` unless they are `scripts/kb`, `state.sh`, `check.sh`, `git` or metadata-only (`ls`, `stat`, `wc`). The `Read` and `Grep` tools are not blocked, so the rule is on Claude: use `kb`.

## Contents
- Tool table
- `kb` commands
- Discovery
- Recording
- Probes

| Store | Tool |
|---|---|
| `kb` store (`docs/kb/<topic>.json`: games, host, setup) | `~/.claude/skills/scripts/kb` (exists on mirrors too; on the desktop it reads and writes the `claude` worktree's store); the worktree copy `~/.claude/skills-worktrees/claude/scripts/kb` is current until merged |
| Open items | `kb` entries under `setup/items`; this repo has no `docs/state.json` any more; `scripts/state.sh` is a compatibility shim over them (same CLI: `list [--all]`, `search`, `show`, `add`, `set`, `close`; `-f docs/state.json` still works beside `docs/kb/` without the file existing) and also reads a project's own `docs/state.json` |
| Project skill references | `instruction-layer/scripts/probe-facts.py <file>` runs the `Probe:` bullets of a Markdown file |
| Worktrees and shared-state links | `claude-worktree/scripts/ensure-worktree.sh <repo>`; `git -C <worktree>` for status and log |
| Memory | the `MEMORY.md` index in context, then `Read` of the one file it points to; write one file plus its index line |
| Handoff | its section headings first, then `Read` of the section needed |

If the tool lacks a command you need, add it to the tool in the same change (with a test) and use it; do not fall back to the raw file. Stores without a search command (handoff, memory) may be searched with `grep` only to find which section or file to open, with output cut to the matching lines.

## `kb` commands

Every command has `--help`; output is sorted, `--json` is available. Exit codes: 0 ok, 1 not found or invalid, 2 usage, 3 schema too new (session start then prints the handoff's §0 instead).

| Group | Commands |
|---|---|
| Read | `ask WORDS [--body] [--under P] [--json]`, `hot`, `ls [PATH\|ALIAS] [--tree] [--all] [--history]`, `find WORDS [--under P --type T --status S]`, `get PATH\|ID [--field F] [--why] [--body]`, `links PATH`, `search REGEX [--under --type --status --commit SHA --path P] [--body]` |
| Write | `add`, `mkcat`, `set`, `close`, `link A REL B`, `ref ID --at PATH`, `supersede OLD NEW`, `mv`, `rm`, `edit` |
| Check | `probe [PATH\|--cat C] [--budget S] [--ssh HOST] [--stale 30d]`, `validate [--orphans]`, `fmt [--check]`, `render --open\|--cat C [--md]` |
| Migration | `import-state`, `import-facts`, `export-state` |

- The tree: a category is an object with `_title` and optional `_aliases`; its other keys are subcategories and entries. An entry has one home path; `{"$ref": id}` elsewhere only means "also browse here"; `links` (rel: depends-on, about, evidence-for, blocks, part-of) relate entries.
- Types and required fields: `kb add --help` (fact, item, decision, artifact, procedure, pitfall, preference, warning, context). `warning`: scenario, kind `irrelevant-info|slow-lookup`, steps (int; tool calls from the first lookup to the one that returned the info used), optional noise and shortcut; `context`: scenario (when it applies) and body[] (the context to recall). `kb find --type warning` lists all warnings (WORDS optional).
- `get`, `ls` (entry), `search` and `ask` print `key: value` lines without body lines (`body: N lines`); `--body` adds them, `--json` is full. `ask` resolves exact alias, id, title, then ranked words: one winner line `PATH | value | source | verified | rel`, a category's children, or `AMBIGUOUS:` with up to 5 candidates; exit 1 = not recorded; a `warnings:` line points at the topic's warnings. `hot: true` (common field; needs an alias and a value of at most 120 chars; `kb set ID --field hot=true --alias A`) puts `alias=value` on the hot sheet printed by `kb hot` at session start (header `HOT <hash8>` is a hash of the whole sheet; at most 4000 chars). A category answer starts with `at: PATH/`.
- `ls`, `get` and `find` hide superseded entries; `--history` shows them. A decision is frozen once recorded (only `status` changes); a newer decision supersedes it.
- A planned change is an item that links (`blocks` or `depends-on`) to the fact it will change; `value` stays what is true now.
- Writes lock `docs/kb/.lock` and validate before renaming a temp file into place; never edit the JSON by hand (`kb edit PATH` opens an entry in `$EDITOR` and rejects invalid changes). Lookup follows the script's own repository, or its sibling `claude` worktree: `$KB_DIR` if set; else, for a script in checkout `<R>`, `<R>-worktrees/claude/docs/kb` when it exists (so `~/.claude/skills/scripts/kb` reads and writes `~/.claude/skills-worktrees/claude/docs/kb`); else `<R>/docs/kb`. A write to a store on the main branch of a checkout that has a `claude` branch is refused (exit 1, naming the worktree) unless `KB_DIR` is set.

## Discovery

Claude never guesses a key; it copies each segment from the previous output.
1. Session start prints the hot sheet, then `kb ls` (one line per topic) and the open items.
2. A mention such as "Deadlock" -> `kb ask WORDS` first; to browse, `kb ls deadlock` (alias to `games/deadlock`, subtopics with counts) -> `kb ls games/deadlock/launch` -> `kb get games/deadlock/launch/options` (value, source, probe, links).
3. A word that is not an alias: `kb find WORDS --under games`. Full text: `kb search REGEX`. Commit lookup: `kb search --commit SHA`.
4. No match exits 1 and lists the nearest topics; when to say "not recorded" is in `instruction-layer/SKILL.md` (Find).
5. Host facts: `kb ls host/<hostname>`; `kb render --cat host/<hostname> --md` prints them as Markdown on demand.

## Recording

- `kb add PATH --type T --title ...` takes the topic path, fills `id` (slug of the last segment, unique store-wide, immutable) and `updated`, and lists the 5 nearest entries of the topic first; a near-duplicate is refused unless `--dup-ok`. Prefer `kb set` on the existing entry.
- Where: warnings `<topic>/warnings` (`games/deadlock`, `host/<hostname>`, `setup`; `kb ls <topic>` shows it on the way down, create with `kb mkcat`), context under the topic it is about (any category); items `setup/items`; decisions `setup/decisions`; pitfalls `setup/pitfalls`; stores and hooks descriptions `setup/stores`, `setup/hooks`, `setup/worktree`; machine facts `host/<hostname>/<topic>`; game facts `games/<game>/<topic>`; written files as `artifact` entries with `written_by` (`claude` or `user`) and `chezmoi_source`.
- Commit SHAs that explain an entry go in `--commit`. `kb mv` keeps ids, refs and links valid; `kb rm` refuses while anything links to the entry.
- Last-verified times go to the untracked `~/.cache/kb/verified.json`, not into the store.

## Probes

A fact's probe is a command that exits 0 while the fact holds and prints the value it found, for example `v=$(findmnt -no FSTYPE,LABEL /mnt/scratch); echo "$v"; [ "$v" = "ext4 scratch" ]`. Give `--probe-timeout` when a probe is slow.
- Probes only read. `kb` parses them with `shfmt` (`scripts/shellast.py`) and refuses anything outside the allowlists in `instruction-layer/scripts/probe-facts.py`: commands and their options in `ALLOW_OPTS`, `systemctl` read verbs, `getent passwd|group`, redirects to `/dev/null`, arithmetic on literal numbers, lowercase variable names. Extend `ALLOW_OPTS` in a reviewed commit when a new read-only option is needed.
- Without `shfmt` probes are reported UNCHECKED and not run. A fact nothing can check (policy, procedure, a measured rate) uses `--probe-none '<reason>'` and is reported UNCHECKED; SessionStart does not list those.
- `kb probe` prints `FAIL <path> `<cmd>` -> <output>` per failing probe and a count line; exit 1 if any failed. `--stale 30d` skips probes verified within 30 days. `--ssh HOST` runs the probes on another machine (`host/remote-host` facts).
- `probe-facts.py` is the runner library `kb` imports; it also runs `Probe:` bullets in a project skill's Markdown references.
- Name devices by UUID, label or by-id path, never by kernel name.
