#!/usr/bin/env python3
"""Run the Probe commands recorded next to facts and report the ones that no longer hold.

A fact line carries  Probe: `<read-only command>`  (exit 0 = the fact still holds)
or  Probe: none (<reason>)  when nothing can check it.

Usage:
  probe-facts.py [--budget SECONDS] [--ssh HOST] FILE...   run probes, print STALE lines, exit 1 if any
  probe-facts.py --lint FILE...                            check every '- ' bullet has a Probe and every probe is read-only
Probe safety needs shfmt: without it, probes are listed UNCHECKED and not run, and --lint skips them.
Importable (scripts/kb): verdicts(cmds) -> why unsafe or None per command; run_probes(cmds, ssh, budget, timeouts).
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "scripts"))
import shellast  # noqa: E402

PROBE = re.compile(r"Probe: `([^`]+)`")
PROBE_ANY = re.compile(r"Probe: (`[^`]+`|none \([^)]+\))")

# Probes must only read. A probe is parsed with shfmt (scripts/shellast.py) and checked against
# allowlists; anything not explicitly allowed is refused, not run. Without shfmt nothing is run.
# ALLOW_OPTS: command -> {option: takes a value}. Only these options are accepted (no abbreviations);
# extend it when a new probe needs another option.
ALLOW_OPTS = {
    "cat": {}, "cut": {"-d": True, "-f": True}, "df": {"--output": True, "-B": True}, "echo": {}, "exit": {},
    "false": {}, "findmnt": {"-n": False, "-o": True}, "free": {}, "getent": {},
    "grep": {"-q": False, "-r": False, "-s": False, "-w": False, "-x": False}, "head": {},
    "hostname": {"-I": False}, "id": {"-G": False, "-n": False}, "ls": {}, "lsblk": {"-n": False, "-o": True},
    "lscpu": {}, "lspci": {"-d": True}, "nproc": {}, "readlink": {"-f": False},
    "stat": {"-c": True, "-f": False}, "systemctl": {"--user": False, "-q": False, "-p": True, "--property": True, "--value": False}, "tail": {"-1": False},
    "tr": {"-d": False, "-s": False}, "true": {}, "uname": {}, "wc": {},
    "test": {"-d": False, "-e": False, "-f": False, "-S": False, "-ge": False, "-le": False},  # operators; = is not an option
}
ALLOW_OPTS["["] = ALLOW_OPTS["test"]
TEST_BINARY = {"=", "!=", "-ge", "-le", "-eq", "-ne", "-lt", "-gt"}
SYSTEMCTL_VERBS = re.compile(r"is-active|is-enabled|is-failed|show|cat|status|list-[a-z-]+")
GETENT_DBS = {"passwd", "group"}
KINDS = {"CallExpr", "BinaryCmd", "Block", "IfClause", "ForClause"}
NODES = {"Lit", "SglQuoted", "DblQuoted", "ParamExp", "CmdSubst", "WordIter",
         "ArithmExp", "BinaryArithm", "UnaryArithm", "ParenArithm", "Word"}  # arithmetic: literal numbers only
CONTEXTS = {"cmdsubst", "pipe", "negated"}
REDIRS = {(">", None, "/dev/null"), (">", "2", "/dev/null"), ("&>", None, "/dev/null"), (">&", "2", "1"),
          (">&", None, "2")}
SUBST_TEXT = ("$(", "`", "<(", ">(")
ASSIGN_NAME = re.compile(r"[a-z][a-z0-9_]*")
SAFE_LEAD = re.compile(r'"?[A-Za-z0-9_/~.,:]')  # a computed word must begin with one of these literally
DQ_WORD = re.compile(r'"(?:[^"\\]|\\.)*"')


def unsafe(cmd):
    """Return why a probe is not read-only, or None. Raises shellast.ShfmtMissing without shfmt."""
    return verdicts([cmd])[0]


def verdicts(cmds):
    parsed = shellast.parse_many(cmds) if cmds else []
    return [f"does not parse as bash ({p})" if isinstance(p, Exception) else unsafe_ast(p) for p in parsed]


def options(name, args):
    """Why the literal options in args are not allowed for name, or None; also returns the operands."""
    allowed, operands, i, end = ALLOW_OPTS[name], [], 0, False
    while i < len(args):
        w = args[i]
        i += 1
        if end or w is None or not w.startswith("-") or w == "-":
            operands.append(w)
        elif w == "--":
            end = True
        elif w.startswith("--"):
            opt = w.split("=", 1)[0]
            if opt not in allowed:
                return f"option {opt} not allowed for {name}; add it to ALLOW_OPTS", []
            if allowed[opt] and "=" not in w:
                i += 1
        elif name == "tail" and w in allowed:
            continue
        else:
            for j, ch in enumerate(w[1:], 1):
                if "-" + ch not in allowed:
                    return f"option -{ch} not allowed for {name}; add it to ALLOW_OPTS", []
                if allowed["-" + ch]:
                    i += j == len(w) - 1  # the value is the next word unless attached (-d:)
                    break
    return None, operands


def test_unsafe(args):
    """Why test/[ operands (text or None, source, unquoted glob) are unsafe: only allowed operators, and no
    expansion where an operator can stand, since -v or -R there runs code held in a string."""
    for t, _, _ in args:
        if t is not None and t.startswith("-") and t not in ALLOW_OPTS["test"]:
            return f"option {t} not allowed for test; add it to ALLOW_OPTS"
    if any(p or (t is None and not DQ_WORD.fullmatch(r)) for t, r, p in args):
        return "test with an unquoted expansion or glob (word splitting could make it -v)"
    lit, n = [t is not None for t, _, _ in args], len(args)
    if (n == 2 and not lit[0]) or (n == 3 and args[1][0] not in TEST_BINARY and not all(lit[:2])) \
            or (n > 3 and not all(lit)):
        return "test with an expansion where an operator can stand (it could be -v)"
    return None


def unsafe_ast(cmds):
    for c in cmds:
        if c.kind not in KINDS:
            return f"uses {c.kind or 'a redirect without a command'} (allowed: commands, pipelines, lists, if, for-in)"
        if c.context - CONTEXTS:
            return "runs code in " + ", ".join(sorted(c.context - CONTEXTS))
        if c.nodes - NODES:
            return "uses " + ", ".join(sorted(c.nodes - NODES))
        if c.arith:
            return "evaluates arithmetic on something other than literal numbers"
        if c.indirect or c.transform:
            return "uses ${!x} or ${x@op}, which can run code held in a variable"
        texts = c.words + list(c.assigns.values()) + [r.target for r in c.redirs]
        hit = next((t for t in texts if t and any(x in t for x in SUBST_TEXT)), None)
        if hit:
            return "literal text holds $(, `, <( or >(: " + hit
        if any(r.startswith("$'") and "\\" in r for r in c.raw + list(c.assign_raw.values())):
            return "uses $'...' escapes"
        for r in c.redirs:
            if (r.op, r.fd, r.target) in REDIRS:
                continue
            if r.op == "<" and r.fd is None and r.target and not r.target.startswith(("/dev/tcp/", "/dev/udp/")):
                continue
            return f"redirect {r.raw and (r.fd or '') + r.op + r.raw} not allowed (only >/dev/null, 2>/dev/null, " \
                   "&>/dev/null, 2>&1, >&2 and < from a literal path)"
        if c.assigns and c.words and c.kind == "CallExpr":
            return "assignment in front of a command"
        bad = next((n for n in c.assigns if not ASSIGN_NAME.fullmatch(n) or n in ("ifs", "ps4", "path")), None)
        if bad:
            return f"assigns {bad} (only lowercase variable names)"
        if c.kind != "CallExpr" or not c.words:
            continue
        name, args = c.name, c.words[1:]
        if name is None:
            return "command name is not a literal word: " + c.raw[0]
        if name in ("test", "["):
            ops = list(zip(args, c.raw[1:], c.pattern[1:]))
            if name == "[":
                if args[-1:] != ["]"]:
                    return "[ without ]"
                ops = ops[:-1]
            why = test_unsafe(ops)
            if why:
                return why
            continue
        if name not in ALLOW_OPTS:
            return f"command not on the read-only list: {name}"
        if any(p and not (w or "").startswith(("/", "~/")) for w, p in zip(args, c.pattern[1:])):
            return "a glob that does not start with / could expand to an option"
        # a computed word whose first character comes from an expansion can turn into an option at run time
        # (x=-Q; lspci "$x" queries DNS); echo and getent take no option that writes, executes or connects
        if name not in ("echo", "getent") and any(
                w is None and not SAFE_LEAD.match(r) for w, r in zip(args, c.raw[1:])):
            return f"{name} with a computed argument that does not start with a literal path or word " \
                   "(it could become an option)"
        why, operands = options(name, args)
        if why:
            return why
        if name == "systemctl":
            if None in args:
                return "systemctl with a computed argument"
            if not operands or not SYSTEMCTL_VERBS.fullmatch(operands[0]):
                return "systemctl verb other than is-*/show/cat/status/list-*"
        elif name == "getent" and (not operands or operands[0] not in GETENT_DBS):
            return "getent database other than passwd or group"
        elif name == "hostname" and operands:
            return "hostname with an argument sets the hostname"
    return None


def probes(paths):
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                for m in PROBE.finditer(line):
                    yield path, n, m.group(1)


def lint(paths):
    bad = 0
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if line.startswith("- ") and not PROBE_ANY.search(line):
                    print(f"NOPROBE {path}:{n} {line.strip()[:70]}")
                    bad += 1
    todo = list(probes(paths))
    try:
        found = verdicts([t[2] for t in todo])
    except shellast.ShfmtMissing:
        print("NOTE shfmt not installed; probe safety not checked")
        return 1 if bad else 0
    for (path, n, cmd), why in zip(todo, found):
        if why:
            print(f"UNSAFE  {path}:{n} {why}: {cmd}")
            bad += 1
    return 1 if bad else 0


def ssh_dropped(rc, out):
    """True when ssh failed to run the probe (exit 255 or a dropped connection), not when the probe ran and failed."""
    return rc == 255 or (rc != 0 and bool(re.search(r"Connection (reset|closed)|kex_exchange_identification", out or "")))


def run_probes(cmds, ssh=None, budget=30.0, timeouts=None):
    """Run every probe command at once, locally or over ssh; return one (status, detail) per command.
    status: "ok", "fail" (non-zero exit, refused as unsafe, or past its own timeout) or "unchecked" (still
    running when the budget ended). timeouts: optional per-probe seconds (None = budget only).
    Raises shellast.ShfmtMissing without shfmt: nothing is run then."""
    if ssh and ssh.startswith("-"):
        raise ValueError(f"ssh host must not start with '-': {ssh}")
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", ssh, "bash", "-s"] if ssh else ["bash", "-s"]
    timeouts = timeouts or [None] * len(cmds)
    deadline = time.monotonic() + budget
    found = verdicts(cmds)
    results = [None] * len(cmds)
    started = []
    for i, (cmd, why) in enumerate(zip(cmds, found)):
        if why:
            results[i] = ("fail", f"refused ({why})")
            continue
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, start_new_session=True)
        p.stdin.write(cmd)
        p.stdin.close()
        started.append((i, p, time.monotonic()))
    for i, p, t0 in started:
        own = t0 + timeouts[i] if timeouts[i] else None
        limit = deadline if own is None else min(deadline, own)
        try:
            out, _ = p.communicate(timeout=max(0.01, limit - time.monotonic()))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if own is not None and own <= deadline:
                results[i] = ("fail", f"timed out after {timeouts[i]:g}s")
            else:
                results[i] = ("unchecked", f"not finished within {budget:g}s")
            continue
        tries = 0
        while ssh and tries < 2 and ssh_dropped(p.returncode, out) and time.monotonic() < deadline:
            # ssh itself failed (sshd rate limit on parallel connections), not the probe: run it again, alone
            tries += 1
            time.sleep(1)
            p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, start_new_session=True)
            p.stdin.write(cmds[i])
            p.stdin.close()
            try:
                out, _ = p.communicate(timeout=max(0.01, limit - time.monotonic()))
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                out = ""
                p.returncode = 255
                break
        if p.returncode != 0:
            out = (out or "").strip()
            results[i] = ("fail", out.splitlines()[-1][:160] if out else f"exit {p.returncode}")
        else:
            results[i] = ("ok", "")
    return results


def main_run(todo, ssh, budget):
    """Run the probes; whatever has not finished by the deadline is killed and counted unchecked."""
    try:
        results = run_probes([t[2] for t in todo], ssh, budget)
    except shellast.ShfmtMissing:
        for path, n, cmd in todo:
            print(f"UNCHECKED {path}:{n} `{cmd}` (shfmt not installed)")
        return 0
    stale = unchecked = 0
    for (path, n, cmd), (status, detail) in zip(todo, results):
        if status == "fail":
            stale += 1
            print(f"STALE {path}:{n} `{cmd}` -> {detail}")
        elif status == "unchecked":
            unchecked += 1
    if unchecked:
        print(f"UNCHECKED {unchecked} probe(s): not finished within {budget:g}s")
    return 1 if stale else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lint", action="store_true")
    ap.add_argument("--budget", type=float, default=30.0, help="total seconds for all probes")
    ap.add_argument("--ssh", help="run the probes on this host")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.ssh and a.ssh.startswith("-"):
        ap.error("--ssh HOST must not start with '-'")
    if a.lint:
        return lint(a.files)
    todo = list(probes(a.files))
    if not todo:
        return 0
    return main_run(todo, a.ssh, a.budget)


if __name__ == "__main__":
    sys.exit(main())
