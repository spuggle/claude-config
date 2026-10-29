#!/usr/bin/env bash
# Verdicts of explored-facts.py explores_bash() and records_bash(), run twice: as installed,
# and with shfmt hidden from PATH. End-to-end transcript cases are in stop-check-test.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$(command -v python3)"
EMPTY="$(mktemp -d)"
trap 'rm -rf "$EMPTY"' EXIT

check() { # MODE PATH
  PATH="$2" "$PY" - "$ROOT/claude-worktree/hooks/explored-facts.py" "$1" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ef", sys.argv[1])
ef = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ef)
mode = sys.argv[2]
# (bash command, reads system state?[, on the shfmt path when it differs])
EXPLORES = [
    ("lsblk -f", True),
    ("cat /etc/fstab | grep swap", True),
    ("git status", False),
    ("pip install x; zip -r a b; umount /mnt", False),
    ('git commit -m "Read /etc/fstab and lsblk output"', False),
    ("bash -c 'cat /etc/fstab'", True),
    ("ssh remote-host 'lsblk -f'", True),
    ("grep -rn swap ~/.claude/skills/references/ 2>/dev/null; lsblk -f", True),
    ("df -h /; free -h", False),
    ("VAR=1 timeout 5 swapon --show", True),
    ("sudo sysctl vm.swappiness", True),
    ("/usr/bin/lsblk", True),
    ("x=$(cat /proc/meminfo)", True),
    ('cat "/etc/$f"', True),
    ("grep -n '/etc/fstab' notes.md", False),
    ("grep swap /etc/fstab", True),
    ("cd /sys/class && ls", True),
    ("ls /dev/disk/by-uuid", True),
    ("ls /dev/null", False),
    ("cat < /etc/hostname", True),
    ("env LC_ALL=C lsblk", True),
    ("command lsblk", True),
    # kb: probe and the read commands are neither exploring nor recording
    ("kb probe --cat host/managing-host --budget 3 --stale 30d", False),
    ("kb add --help | head; lsblk", False, True),
    ("kb set --help", False),
    ("~/.claude/skills/scripts/kb probe host/x/y; echo ok", False),
    ("python3 ~/.claude/skills/scripts/kb get host/x/mounts --field value", False),
    ("kb find /etc/fstab", False),
    ("kb ls host/managing-host && lsblk -f", False, True),  # legacy skips a whole kb command
    ("kb add host/x/f --type fact --title T --probe 'grep a /etc/fstab' --source-path /etc/fstab --source-locator a", False),
    ("for f in /etc/*.conf; do :; done", True),
    ("f=/etc/fstab; cat $f", True),
    ("journalctl -b", True),
    ("ls ~/.config", False),
    ("pipx list", False),
    ("cat /usr/share/foo.conf/x", True),
    ("cat <<EOF > /tmp/x\nsee /etc/fstab\nEOF", False),
    ("git commit -F - <<EOF\nlsblk /etc/fstab\nEOF", False),
    ('echo "unterminated', False),
    ("timeout 5 lsblk", True),
    ("bash script.sh", False),
    # review round 1
    ("sudo -iu root lsblk", True),
    ("sudo -u root lsblk", True),
    ("sudo -n -u root lsblk", True),
    ("bash -c 'cat \"$1\"' _ /etc/fstab", True),
    ("command -v lsblk", False),
    ("command -V lsblk || true", False),
    ("{ " * 2000 + "lsblk; " + "}; " * 2000, True),  # too deep for the parser: the regex check decides
    # verdicts the shfmt port changes (legacy, shfmt), with the reason
    ("echo /etc/fstab", True, False),                                 # printed text, not a read
    ("printf '%s\\n' /proc/cpuinfo", True, False),                    # likewise
    ("grep -n /etc/fstab notes.md", True, False),                     # a grep pattern
    ("bash <<'EOF'\nlsblk\nEOF", False, True),                        # a script given to a shell
    ("ssh remote-host bash -s <<'EOF'\ncat /etc/os-release\nEOF", False, True),
    ('sh -c "lsblk"', False, True),
    ("bash -lc 'lsblk'", False, True),
    ("ssh -p 22 remote-host lsblk -f", False, True),                         # remote command words
    ("xargs lsblk", False, True),                                     # wrappers
    ("nohup lsblk", False, True),
    ("echo $(lsblk)", False, True),                                   # command substitution
    ("cat x & lsblk", False, True),                                   # after a lone &
    ("python3 -c 'open(\"/etc/fstab\")'", False, True),             # quoted words are checked
    ("ssh remote-host 'cat <<EOF\n/etc/x\nEOF'", True, False),               # heredoc text of a remote cat
]
# (bash command, writes a fact store?[, on the shfmt path when it differs])
RECORDS = [
    ("cat >> ~/.claude/skills/host-hygiene/references/h.md <<'EOF'\n- fact\nEOF", True),
    ("grep -rn swap ~/.claude/skills/references/ 2>/dev/null", False),
    ("sed -i 's/a/b/' /x/references/h.md", True),
    ("sed -n 1p /x/references/h.md", False),
    ("echo x | tee -a /x/references/h.md", True),
    ("cp /tmp/h.md /x/references/h.md", True),
    ("mv a /x/SKILL.md", True),
    ("git add host-hygiene/references/h.md", True),
    ('git commit -m "Record fact in host-hygiene/references/h.md"', True),
    ("echo x > /home/u/.claude/projects/p/memory/a.md", True),
    ("cat /x/references/h.md 2>/dev/null", False),
    ("cat /x/references/h.md >&2", False),
    ("cp -t /x/references/ a b", True),
    ("echo x >> ~/.claude/skills/a/SKILL.md", True),
    ("git add -A", False),
    # kb write commands record; the read commands do not
    ("kb add host/x/f --type fact --title T --value v --probe true --source-path p --source-locator l", True),
    ("~/.claude/skills/scripts/kb set host/x/f --value w", True),
    ("python3 scripts/kb close some-item", True),
    ("kb link a depends-on b", True),
    ("kb ref some-id --at host/x", True),
    ("kb mv host/x/f host/x/g", True),
    ("kb edit host/x/f", True),
    ("kb supersede old new", True),
    ("kb add --help", False),
    ("~/.claude/skills/scripts/kb set -h", False),
    ("python3 scripts/kb supersede --help; kb ls", False),
    ("kb add --help; kb add host/x/f --type fact --title T", True),
    ("kb import-state docs/state.json", True),
    ("kb probe host/x", False),
    ("kb ls host/x", False),
    ("kb get host/x/f", False),
    ("kb find mount; kb search swap; kb links host/x/f", False),
    ("git log -- /x/references/h.md > /dev/null", False),
    # review round 1: the skills worktrees are fact stores
    ("sed -i s/a/b/ ~/.claude/skills-worktrees/claude/scripts/check.sh", True),
    ("git -C ~/.claude/skills-worktrees/claude add -A", True),
    ("git -C ~/.claude/skills-worktrees/claude commit -m x", True),
    ("ls ~/.claude/skills-worktrees/", False),
    # verdicts the shfmt port changes (legacy, shfmt), with the reason
    ("cat ~/.claude/skills-worktrees/claude/x > /tmp/y", True, False),
    ("cp /x/references/h.md /tmp/h.md", True, False),                 # copies out of the store
    ("cat /x/references/h.md > /tmp/y", True, False),                 # writes elsewhere
    ("ls /x/references/ | tee /tmp/l", True, False),
    ("git -C ~/.claude/skills commit -m x", False, True),             # commits in the skills repo
    ("install -m 644 a /x/references/h.md", False, True),             # install writes like cp
]
bad = 0
for fn, cases in ((ef.explores_bash, EXPLORES), (ef.records_bash, RECORDS)):
    for case in cases:
        cmd, want = case[0], case[-1] if mode == "shfmt" else case[1]
        got = bool(fn(cmd))
        if got != want:
            bad += 1
            print(f"FAIL  [{mode}] {fn.__name__}({cmd!r}): {got}, want {want}")
n = len(EXPLORES) + len(RECORDS)
print(f"{mode}: {n - bad}/{n} verdicts as expected")
sys.exit(1 if bad else 0)
EOF
}

failures=0
check shfmt "$PATH" || failures=$((failures + 1))
check legacy "$EMPTY" || failures=$((failures + 1))
[ "$failures" -eq 0 ]
