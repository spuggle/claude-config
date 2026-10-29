#!/usr/bin/env python3
"""Stop-hook helper: did this turn look up a lot, or miss in the kb, without reflecting on it?

Usage: reflect.py TRANSCRIPT_PATH
Prints one problem line, or nothing. The window starts at the last prompt the user typed;
subagent transcripts only show kb writes (parsing and helpers come from explored-facts.py).
Lookups (main transcript only) = Read/Grep/Glob, kb ask|ls|find|get|links|search, Explore agents, read-only Bash. It fires when
lookups >= 6, or a kb miss (exit 1 / "not recorded") was followed by a kb hit, and no kb write
(add|set|close|link|ref|mv|edit|supersede) ran in the window. Claude never counts: this line does.
"""
import glob
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
_spec = importlib.util.spec_from_file_location("explored_facts", os.path.join(HERE, "explored-facts.py"))
ef = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ef)

MIN_LOOKUPS = 6
KB_LOOKUP = {"ask", "ls", "find", "get", "links", "search"}
READONLY = {
    "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "find", "stat", "wc", "file", "which", "type",
    "df", "free", "ps", "jq", "awk", "readlink", "realpath", "tree", "du", "pwd", "id", "uname", "date", "diff",
    "cmp", "sort", "uniq", "cut", "tr", "basename", "dirname", "test", "[", "ss", "lsof", "env", "printenv",
    "cd", "echo", "printf", "nl",
} | ef.STATE_CMDS
GIT_READ = {"log", "show", "diff", "status", "rev-parse", "ls-files", "grep", "blame", "describe", "rev-list",
            "cat-file", "ls-tree", "shortlog", "worktree-list"}
MISS = re.compile(r"not recorded|kb: not found:|^Exit code 1\b")
SILENCING_TYPES = {"warning", "context", "fact"}


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(i.get("text", "") for i in content if isinstance(i, dict))
    return ""


def silences(sub, args):
    """Only kb set, or kb add of a warning, context or fact, counts as the recording that silences reflect."""
    if sub == "set":
        return True
    if sub != "add":
        return False
    for i, w in enumerate(args):
        if w == "--type" and i + 1 < len(args):
            return args[i + 1] in SILENCING_TYPES
        if w and w.startswith("--type="):
            return w[7:] in SILENCING_TYPES
    return False


def classify_ast(cmd_nodes):
    """(lookup, kb lookup, kb write) for one parsed Bash command."""
    reads = kb_read = wrote = False
    ok = True
    for c in cmd_nodes:
        if any(r.op in ef.WRITE_REDIRS and (r.target or "") != "/dev/null" for r in c.redirs):
            ok = False
        ws = ef.command(c)
        if not ws:
            continue
        name, args = os.path.basename(ws[0][0] or ""), [w for w, _ in ws[1:]]
        sub = ef.kb_sub(ws)
        if sub is not None:
            if any(w in ("-h", "--help") for w, _ in ws):
                continue
            if silences(sub, args):
                wrote = True
            elif ef.kb_writes(sub):
                ok = False
            elif sub in KB_LOOKUP:
                kb_read = True
            else:
                ok = False
            continue
        if name == "git":
            sub_git = next((w for w in args if w and not w.startswith("-")), "")
            ok = ok and sub_git in GIT_READ
        elif name == "sed":
            ok = ok and not any(w and (w == "--in-place" or re.fullmatch(r"-[a-zA-Z]*i\S*", w)) for w in args)
        elif name == "find":
            ok = ok and not any(w in ("-exec", "-delete", "-execdir", "-ok") for w in args)
        elif name not in READONLY:
            ok = False
        reads = True
    return (ok and (reads or kb_read)) or kb_read, kb_read, wrote


def classify_legacy(cmd):
    is_kb, wrote = ef.kb_legacy(cmd)
    if wrote:
        wrote = bool(re.search(r"\bkb\s+set\b", cmd) or re.search(r"--type[ =](warning|context|fact)\b", cmd))
    if is_kb:
        subs = [m.group(1) for m in ef.KB_LEGACY.finditer(cmd)]
        return (not wrote and any(s in KB_LOOKUP for s in subs)), (not wrote and any(s in KB_LOOKUP for s in subs)), wrote
    words = ef.LEAD.sub("", re.split(r"\|\||&&|[|;\n]", cmd)[0]).split()
    first = os.path.basename(words[0]) if words else ""
    ok = first in READONLY and not re.search(r"(?<![0-9&])>(?!\s*/dev/null|&)", cmd)
    return ok, False, False


def classify_bash(cmds):
    try:
        parsed = ef.shellast.parse_many(cmds) if ef.shellast and cmds else []
    except ef.shellast.ShfmtMissing:
        parsed = []
    if len(parsed) != len(cmds):
        parsed = [None] * len(cmds)
    return [classify_ast(p) if isinstance(p, list) else classify_legacy(c) for c, p in zip(cmds, parsed)]


def short(name, inp):
    if name == "Bash":
        return " ".join((inp.get("command") or "").split())[:40]
    if name == "Agent":
        return f"Agent {inp.get('subagent_type', '')}"
    target = inp.get("file_path") or inp.get("pattern") or inp.get("path") or ""
    return f"{name} {os.path.basename(target) if name == 'Read' else target}"[:40]


def analyse_sequence(es):
    """(calls [(label, chars)], kb miss then hit, kb write) for one transcript's entries in order."""
    uses, results, order = {}, {}, []
    for e in es:
        content = (e.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            if e.get("type") == "assistant" and item.get("type") == "tool_use":
                uses[item.get("id")] = (item.get("name"), item.get("input") or {})
                order.append(item.get("id"))
            elif e.get("type") == "user" and item.get("type") == "tool_result":
                results[item.get("tool_use_id")] = (text_of(item.get("content")), bool(item.get("is_error")))
    bash_ids = [i for i in order if uses[i][0] == "Bash"]
    cls = dict(zip(bash_ids, classify_bash([uses[i][1].get("command", "") for i in bash_ids])))
    calls, miss_seen, miss_then_hit, wrote = [], False, False, False
    for i in order:
        name, inp = uses[i]
        text, err = results.get(i, ("", False))
        kb_read = False
        if name in ("Read", "Grep", "Glob"):
            lookup = True
        elif name == "Agent":
            lookup = inp.get("subagent_type") == "Explore"
        elif name == "Bash":
            lookup, kb_read, w = cls[i]
            wrote = wrote or w
        else:
            lookup = False
        if lookup:
            calls.append((short(name, inp), len(text)))
        if kb_read:
            if err or MISS.search(text):
                miss_seen = True
            elif miss_seen:
                miss_then_hit = True
    return calls, miss_then_hit, wrote


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    if not path or not os.path.isfile(path):
        return
    main_es = list(ef.entries(path))
    start = max((i for i, e in enumerate(main_es) if ef.is_prompt(e)), default=None)
    if start is None:
        return
    t0 = main_es[start].get("timestamp", "")
    seqs = [main_es[start:]]
    for sub in sorted(glob.glob(os.path.join(path[:-len(".jsonl")], "subagents", "*.jsonl"))):
        seqs.append([e for e in ef.entries(sub) if e.get("timestamp", "") >= t0])
    calls, mth, wrote = analyse_sequence(seqs[0])
    for s in seqs[1:]:  # subagents only show whether a kb write happened
        wrote = wrote or analyse_sequence(s)[2]
    if wrote or not (len(calls) >= MIN_LOOKUPS or mth):
        return
    shown = "; ".join(l for l, _ in calls[:8]) + (f"; +{len(calls) - 8} more" if len(calls) > 8 else "")
    miss = " (a kb miss was followed by a hit)" if mth else ""
    print(f"reflect: lookups={len(calls)} ({shown}), chars={sum(n for _, n in calls)}{miss}. "
          "Judge: which results were irrelevant; what context would be needed again for this scenario; "
          "how many calls the info needed. Record with kb add <topic>/warnings/<id> --type warning ... "
          "and/or kb add <path> --type context ..., or confirm none is needed.")


if __name__ == "__main__":
    main()
