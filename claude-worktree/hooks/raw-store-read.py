"""Find a Bash command that reads or edits a store file directly, for guard-bash.sh.

The stores are docs/state.json and the files under docs/kb/ (also ~/.claude/skills/docs/kb).
Usage: raw-store-read.py < command
Exit 1 and print the offending command when one names a store file outside the store's tools
(scripts/kb, scripts/state.sh, scripts/check.sh), git and metadata-only commands; exit 0 otherwise.
Commands are parsed with shfmt (scripts/shellast.py); when that fails, any mention of a store
without kb or state.sh blocks. Inner commands of `bash -c` are checked too. Paths are normalised first
(`//`, `/./`, `x/../`). Also blocked: a recursive grep/rg/find -exec/cat on a parent directory of docs/kb
(`docs`, `~/.claude/skills/docs`, `docs/*`), `git show|cat-file|grep` of `<rev>:docs/kb/...`, and any command
other than cd/ls/stat/wc/kb after a `cd` into docs/kb (a bare `cd docs/kb && ls` is allowed).
"""
import os
import posixpath
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
import shellast  # noqa: E402

STORE = re.compile(r"state\.json|(?:^|[^\w.-])(?:\S*/)?docs/kb(?![\w.-])")
TOOLS = {"kb", "state.sh", "check.sh", "git"}
INTERPRETERS = re.compile(r"python[\d.]*$")
METADATA = {"ls", "stat", "wc", "test", "[", "[[", "realpath", "readlink", "basename", "dirname", "cd"}
AFTER_CD_OK = TOOLS | METADATA | {"echo", "true", "false", "pwd", ":", "printf"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag"}
GIT_READERS = {"show", "cat-file", "grep"}
PARENT = re.compile(r"(?:^|/)docs$")
PARENT_GLOB = re.compile(r"(?:^|/)docs/(?:\*+|\.)$")
STORE_DIR = re.compile(r"(?:^|/)docs/kb$")


def collapse(t):
    """Collapse // and /./ (and x/../) so a store path cannot hide behind them."""
    t = re.sub(r"/{2,}", "/", t)
    while "/./" in t:
        t = t.replace("/./", "/")
    if "/../" in t or t.endswith("/.."):
        t = posixpath.normpath(t)
    return t.rstrip("/") or t


def texts_of(cmd):
    out = []
    for w, r in zip(cmd.words, cmd.raw):
        t = w if w is not None else str(r).strip("\"'")
        out.append(collapse(t))
    return out


def names_store(cmd):
    texts = [collapse(str(t)) for t in cmd.raw] + texts_of(cmd)
    texts += [collapse(r.raw) if isinstance(r.raw, str) else "" for r in cmd.redirs]
    texts += [collapse(str(r.target or "")) for r in cmd.redirs]
    return any(STORE.search(t) for t in texts)


def operands(base, words):
    """The path operands of a command that reads files or trees (options and a grep pattern dropped)."""
    ops, pattern_given, i = [], False, 1
    while i < len(words):
        w = words[i]
        if w.startswith("-") and w != "-":
            if base in GREPS and (w in ("-e", "-f", "--regexp", "--file") or w.startswith(("--regexp=", "--file="))):
                pattern_given = True
                i += w in ("-e", "-f", "--regexp", "--file")
            i += 1
            continue
        ops.append(w)
        i += 1
    if base in GREPS and not pattern_given and ops:
        ops = ops[1:]
    return ops


def recursive(base, words):
    if base in ("rg", "ag"):
        return True
    for i, w in enumerate(words[1:], 1):
        if w in ("--recursive", "--dereference-recursive", "-d=recurse", "--directories=recurse"):
            return True
        if w == "-d" and words[i + 1:i + 2] == ["recurse"]:
            return True
        if re.fullmatch(r"-[A-Za-z]*[rR][A-Za-z]*", w):
            return True
    return False


def reads_parent(base, cmd):
    """True when a content-reading command targets a parent directory of docs/kb."""
    words = texts_of(cmd)
    if base in GREPS | {"cat"}:
        ops = operands(base, words)
        if any(PARENT_GLOB.search(o) for o in ops):
            return True
        return (base == "cat" or recursive(base, words)) and any(PARENT.search(o) for o in ops)
    if base == "find" and any(w in ("-exec", "-execdir", "-ok", "-okdir") for w in words):
        ops = []
        for w in words[1:]:
            if w.startswith("-") or w in ("(", "!"):
                break
            ops.append(w)
        return any(PARENT.search(o) or PARENT_GLOB.search(o) for o in ops)
    return False


def git_reads_store(cmd):
    words = texts_of(cmd)[1:]
    i = 0
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    return i < len(words) and words[i] in GIT_READERS and any(STORE.search(w) for w in words[i + 1:])


def check(src, depth=0):
    """Return the offending command text, or None."""
    try:
        cmds = shellast.parse(src)
    except (shellast.ShfmtMissing, shellast.ParseError):
        src = collapse(src)
        return src if STORE.search(src) and not re.search(r"state\.sh|(?<![\w-])kb(?![\w.-])\s", src) else None
    in_store = False
    for c in cmds:
        base = os.path.basename(c.name) if c.name else None
        if base == "cd":
            ops = [t for t in texts_of(c)[1:] if not t.startswith("-")]
            in_store = bool(ops) and bool(STORE_DIR.search(ops[-1]))
            continue
        if in_store and base not in AFTER_CD_OK and not (base in SHELLS or (base and INTERPRETERS.match(base))):
            return " ".join(c.raw)
        if base == "git" and git_reads_store(c):
            return " ".join(c.raw)
        if base and reads_parent(base, c):
            return " ".join(c.raw)
        if base in SHELLS and depth < 3:
            for i, w in enumerate(c.words[:-1]):
                if w in ("-c", "-lc", "-ec") and c.words[i + 1] is not None:
                    hit = check(c.words[i + 1], depth + 1)
                    if hit:
                        return hit
            if any(w and os.path.basename(w) in TOOLS for w in c.words[1:3]):
                continue
        if base and INTERPRETERS.match(base) and len(c.words) > 1 and c.words[1] and os.path.basename(c.words[1]) in TOOLS:
            continue  # python3 scripts/kb ...
        if not names_store(c):
            continue
        if base in TOOLS or base in METADATA:
            continue
        if base in SHELLS and "-c" in c.words:
            continue
        return " ".join(c.raw)
    return None


if __name__ == "__main__":
    hit = check(sys.stdin.read())
    if hit:
        print(hit.replace("\n", " ")[:200])
        sys.exit(1)
