#!/usr/bin/env python3
"""Stop-hook helper: did this turn read system state without recording what it learned?

Usage: explored-facts.py TRANSCRIPT_PATH
Prints one problem line, or nothing. The turn starts at the last prompt the user typed;
subagent transcripts (<transcript dir>/<session>/subagents/*.jsonl) count from the same time.
Exploration = a Bash segment starting with a state-reading command, or a Bash/Read/Grep/Glob
target under a system path. Recorded = an Edit/Write (or a Bash command) that touches a fact
store: a skill's references/, a SKILL.md, a HANDOFF.md, a memory directory or docs/kb, or a kb
write command (kb add|set|close|link|ref|mv|edit|supersede|import-*). Other kb commands (probe, ls, get,
find, search, links) and any kb command with -h/--help are neither exploring nor recording; whether a kb
command failed is not checked.
Bash commands are parsed with shfmt (scripts/shellast.py); without shfmt, or when a command does
not parse, the older regex checks (*_legacy) decide.
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "scripts"))
try:
    import shellast
except ImportError:
    shellast = None

STATE_CMDS = {
    "lsblk", "findmnt", "blkid", "swapon", "zramctl", "sysctl", "systemctl", "journalctl",
    "udevadm", "lspci", "lsusb", "lsmod", "modinfo", "ip", "nmcli", "iw", "mount", "dmesg",
    "nvidia-smi", "sensors", "hostnamectl", "loginctl", "timedatectl", "localectl", "lscpu",
    "dmidecode", "snap", "flatpak", "asusctl", "powerprofilesctl", "cpupower", "efibootmgr",
    "smartctl", "nvme", "resolvectl", "getent",
}  # not df, free, id, uname: they give live values, which are not recorded
SYS_PATH = re.compile(r"(^|[\s'\"=:])/(etc|sys|proc|boot|dev/disk|usr/lib|usr/share/[\w.-]*conf|var/lib|run/systemd)(/|\b)")
FACT_STORE = re.compile(r"/references/|/SKILL\.md|HANDOFF\.md|/memory/|/\.claude/skills/"
                        r"|/docs/kb/|/\.claude/skills-worktrees/[^/\s'\"]+(/|[\s'\"]|$)")
WRITEY = re.compile(r"\bsed\s+-i|\btee\b|(?<![0-9&])>(?!\s*/dev/null|&)|\bcp\b|\bmv\b|\bgit(\s+-C\s+\S+)?\s+(add|commit)\b")
SPLIT = re.compile(r"\|\||&&|[|;\n]|\$\(|`")
LEAD = re.compile(r"^(?:\s*(?:\w+=\S*|sudo(?:\s+-[A-Za-z]*[CDghprtTUu]\s+\S+|\s+-\S+)*|timeout\s+\S+|env|command|exec|!|\(|\{|then|do|else|if|while))*\s*")
KB_WRITE = {"add", "set", "close", "link", "ref", "mv", "edit", "supersede"}  # and import-*
KB_READ = {"probe", "ls", "get", "find", "search", "links", "validate", "fmt", "render", "export-state"}
HELP = re.compile(r"(?:^|\s)(?:-h|--help)(?:\s|$)")
KB_LEGACY = re.compile(r"(?:^|[\s/;&|(`])kb\s+(?:-\S+\s+)*([a-z][a-z-]*)\b")
# shfmt AST path
SHELLS = {"bash", "sh", "zsh", "dash", "ssh"}
WRAPPERS = {  # wrapper -> its short options that take a value
    "sudo": "CDghprtTUu", "doas": "Cu", "env": "CSu", "command": "", "exec": "a", "nice": "n", "nohup": "",
    "timeout": "ks", "xargs": "adEILnPs", "stdbuf": "eio"}
SSH_ARGS = set("BbcDEeFIiJLlmOopQRSWw")
WRITE_REDIRS = {">", ">>", ">|", "&>", "&>>", "<>"}


def entries(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def is_prompt(e):
    if e.get("type") != "user" or e.get("isMeta"):
        return False
    origin = e.get("origin")
    if isinstance(origin, dict):
        return origin.get("kind") == "human"
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        return not c.startswith("<local-command") and not c.startswith("<command-name>")
    return isinstance(c, list) and any(isinstance(i, dict) and i.get("type") == "text" for i in c)


def tool_uses(es):
    for e in es:
        if e.get("type") != "assistant":
            continue
        for item in (e.get("message") or {}).get("content") or []:
            if isinstance(item, dict) and item.get("type") == "tool_use":
                yield item.get("name"), item.get("input") or {}


def explores_bash(cmd):
    return analyse([cmd])[0][0]


def records_bash(cmd):
    return analyse([cmd])[0][1]


def analyse(cmds, depth=0):
    """[(reads system state, writes a fact store)] per Bash command; the regex check when shfmt is missing
    or a command does not parse."""
    try:
        parsed = shellast.parse_many(cmds) if shellast and cmds and depth < 3 else []
    except shellast.ShfmtMissing:
        parsed = []
    if len(parsed) != len(cmds):
        parsed = [None] * len(cmds)
    return [(explores_legacy(c), records_legacy(c)) if not isinstance(p, list) else (explores_ast(p, depth), records_ast(p))
            for c, p in zip(cmds, parsed)]


def command(c):
    """The command's words (text, source) after wrappers such as sudo, env, timeout and xargs."""
    ws = list(zip(c.words, c.raw)) if c.kind == "CallExpr" else []
    while ws and ws[0][0] and os.path.basename(ws[0][0]) in WRAPPERS:
        wrapper = os.path.basename(ws[0][0])
        if wrapper == "command" and len(ws) > 1 and ws[1][0] in ("-v", "-V"):
            break  # a lookup, not a run
        ws.pop(0)
        while ws and ws[0][0] and (ws[0][0].startswith("-") or "=" in ws[0][0]):
            w = ws.pop(0)[0]
            if not w.startswith("--"):
                i = next((i for i, ch in enumerate(w[1:], 1) if ch in WRAPPERS[wrapper]), None)
                if i == len(w) - 1 and ws:  # -iu root: the value is the next word
                    ws.pop(0)
        if wrapper == "timeout" and ws:
            ws.pop(0)
    return ws


def kb_sub(ws):
    """The kb subcommand when the command is scripts/kb (possibly run by python), else None."""
    names = [os.path.basename(w or "") for w, _ in ws[:2]]
    if names[:1] == ["kb"]:
        rest = ws[1:]
    elif names[:1] and names[0].startswith("python") and names[1:] == ["kb"]:
        rest = ws[2:]
    else:
        return None
    return next((w for w, _ in rest if w and not w.startswith("-")), "")


def kb_writes(sub):
    return sub in KB_WRITE or sub.startswith("import-")


def explores_ast(cmds, depth):
    inner = []
    for c in cmds:
        ws = command(c)
        name = os.path.basename(ws[0][0] or "") if ws else ""
        if kb_sub(ws) is not None:
            continue  # kb arguments are paths, titles and probe commands, not reads of system state
        if name in STATE_CMDS:
            return True
        texts = [r.raw for r in c.redirs if r.raw] + list(c.assign_raw.values())
        if c.kind != "CallExpr":
            texts += [r for r in c.raw if c.kind != "FuncDecl"]
        elif name in SHELLS:
            inner += [r.body for r in c.redirs if r.body]
            scripts, rest = script(name, [w for w, _ in ws[1:]], [r for _, r in ws[1:]])
            inner += scripts
            texts += rest  # bash -c '...' _ /etc/x: the script's arguments
        elif name in ("echo", "printf") or (name == "git" and any(w in ("commit", "tag") for w, _ in ws)):
            pass  # messages and printed text are not reads
        else:
            args = [r for _, r in ws[1:]]
            if name in ("grep", "egrep", "fgrep", "rg"):
                args = drop_pattern(ws[1:])
            texts += args
        if any(SYS_PATH.search(" " + t) for t in texts):
            return True
    return any(e for e, _ in analyse(inner, depth + 1)) if inner else False


def script(name, words, raw):
    """([script a shell runs (bash -c '...') or the remote command of ssh], [source of other words])."""
    if name == "ssh":
        i = 0
        while i < len(words) and words[i] and words[i].startswith("-"):
            i += 2 if words[i][-1] in SSH_ARGS and len(words[i]) == 2 else 1
        rest = raw[i + 1:]
        return ([" ".join(w if w is not None else r for w, r in zip(words[i + 1:], rest))] if rest else []), []
    for i, w in enumerate(words):
        if w and w.startswith("-") and not w.startswith("--") and "c" in w and i + 1 < len(words):
            return [words[i + 1] if words[i + 1] is not None else raw[i + 1]], raw[:i + 1] + raw[i + 2:]
    return [], raw


def drop_pattern(ws):
    """grep's arguments without the pattern (the first operand unless -e gives it)."""
    out, explicit, skip, pattern_at = [], False, False, None
    for i, (w, r) in enumerate(ws):
        if skip:
            skip = False
            continue
        if w in ("-e", "--regexp"):
            explicit, skip = True, True
        elif w and (w.startswith("--regexp=") or (w.startswith("-e") and len(w) > 2)):
            explicit = True
        elif w and w.startswith("-"):
            out.append(r)
        elif pattern_at is None:
            pattern_at = len(out)
            out.append(r)
        else:
            out.append(r)
    if not explicit and pattern_at is not None:
        del out[pattern_at]
    return out


def records_ast(cmds):
    for c in cmds:
        for r in c.redirs:
            to_file = r.op in WRITE_REDIRS or (r.op == ">&" and not re.fullmatch(r"[0-9]*-?", r.target or "x"))
            if to_file and FACT_STORE.search(r.raw or ""):
                return True
        ws = command(c)
        if not ws:
            continue
        name, args = os.path.basename(ws[0][0] or ""), ws[1:]
        sub = kb_sub(ws)
        if sub is not None:
            if kb_writes(sub) and not any(w in ("-h", "--help") for w, _ in ws):
                return True  # kb add --help only prints usage: not a recording
            continue
        ops = [r for w, r in args if not (w and w.startswith("-"))]
        if name == "sed" and any(w and (w == "--in-place" or re.fullmatch(r"-[a-zA-Z]*i\S*", w)) for w, _ in args):
            hit = ops
        elif name == "tee":
            hit = ops
        elif name in ("cp", "mv", "install", "rsync"):
            t = [args[i + 1][1] for i, (w, _) in enumerate(args[:-1]) if w in ("-t", "--target-directory")]
            hit = t or ops[-1:]
        elif name == "git" and any(w in ("add", "commit") for w, _ in args):
            hit = [r + "/" for _, r in args]
        else:
            continue
        if any(FACT_STORE.search(h) for h in hit):
            return True
    return False


def kb_legacy(cmd):
    """(is a kb command, writes the store) for the regex path."""
    found = [(m.group(1), HELP.search(re.split(r"\|\||&&|[|;\n]", cmd[m.end():], 1)[0]) is not None)
             for m in KB_LEGACY.finditer(cmd)]
    return bool(found), any(kb_writes(x) and not h for x, h in found)


def explores_legacy(cmd):
    if kb_legacy(cmd)[0]:
        return False
    # Quoted literals and here-documents (commit messages, patterns) are not reads, except
    # the script given to a shell (bash -c '...') or to ssh, which is kept and checked.
    inner = re.findall(r"\b(?:ba|z)?sh\s+-c\s+'([^']*)'", cmd) + re.findall(r"\bssh\b[^'|;&]*'([^']*)'", cmd)
    cmd = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?.*?\n\1\b", "", cmd, flags=re.S)
    cmd = re.sub(r"'[^']*'", "''", cmd)
    cmd = re.sub(r'"[^"$]*"', '""', cmd)
    cmd = "\n".join([cmd] + inner)
    if SYS_PATH.search(cmd):
        return True
    for seg in SPLIT.split(cmd):
        words = LEAD.sub("", seg).split()
        if words and os.path.basename(words[0]) in STATE_CMDS:
            return True
    return False


def records_legacy(cmd):
    if kb_legacy(cmd)[1]:
        return True
    return bool(FACT_STORE.search(cmd) and WRITEY.search(cmd))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    if not path or not os.path.isfile(path):
        return
    main_es = list(entries(path))
    start = max((i for i, e in enumerate(main_es) if is_prompt(e)), default=None)
    if start is None:
        return
    turn = main_es[start:]
    t0 = main_es[start].get("timestamp", "")
    for sub in glob.glob(os.path.join(path[:-len(".jsonl")], "subagents", "*.jsonl")):
        turn += [e for e in entries(sub) if e.get("timestamp", "") >= t0]

    uses = list(tool_uses(turn))
    bash = [i.get("command", "") for n, i in uses if n == "Bash"]
    explored, recorded = [], False
    for cmd, (explores, records) in zip(bash, analyse(bash)):
        recorded = recorded or records
        if explores:  # kb probe and the other kb reads are never counted as exploring
            explored.append(cmd.strip().splitlines()[0][:60])
    for name, inp in uses:
        if name == "Bash":
            continue
        elif name in ("Read", "Grep", "Glob"):
            target = inp.get("file_path") or inp.get("path") or ""
            if SYS_PATH.search(" " + target):
                explored.append(f"{name} {target}"[:60])
        elif name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            if FACT_STORE.search(inp.get("file_path", "") or inp.get("notebook_path", "")):
                recorded = True
    if explored and not recorded:
        shown = "; ".join(explored[:3]) + (f"; +{len(explored) - 3} more" if len(explored) > 3 else "")
        print(f"this turn read system state ({len(explored)} calls: {shown}) and recorded no fact: "
              "record each stable fact the task relied on, with a Probe, in its home "
              "(instruction-layer, Recording explored facts), or confirm none needs recording")


if __name__ == "__main__":
    main()
