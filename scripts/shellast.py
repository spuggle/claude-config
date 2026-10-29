"""Parse bash with shfmt (--to-json) into a flat list of commands, so hooks need not tokenize shell.

parse(src) -> [Cmd]; raises ShfmtMissing when shfmt is not on PATH, ParseError when src is not bash.
parse_many(srcs) parses several sources concurrently; each result is a [Cmd] or a ParseError.

One Cmd per statement, nested ones included: a simple command (kind "CallExpr"), a compound
command (kind is its shfmt type: Block, IfClause, ForClause, TestClause, FuncDecl, ...; a select
loop is SelectClause) or a
redirect-only statement (kind ""). Commands inside $(...), `...`, <(...), function bodies and
subshells are listed too, with that context in Cmd.context. Every shfmt node is walked; a node
type this module does not know raises ParseError, so new syntax fails closed.
"""
import json
import re
import shutil
import subprocess


class ParseError(Exception):
    pass


class ShfmtMissing(Exception):
    pass


class Redir:
    __slots__ = ("op", "fd", "target", "raw", "body")

    def __init__(self, op, fd, target, raw, body):
        self.op, self.fd, self.target, self.raw, self.body = op, fd, target, raw, body

    def __repr__(self):
        return f"Redir({self.op!r}, fd={self.fd!r}, target={self.target!r}, body={self.body!r})"


class Cmd:
    """words/assign values are literal strings, or None when they hold an expansion or substitution.
    raw, assign_raw: the source text of each word and assigned value. pattern[i]: word i has an unquoted glob or brace pattern.
    context: subset of cmdsubst, backquote, procsubst, subshell, pipe, negated, background, func, coproc.
    arith: arithmetic evaluates something other than literal integers (a name or expansion there runs
    code held in a variable). indirect: a ${!...} expansion; transform: a ${x@op} expansion (@P runs code).
    nodes: the shfmt node types in this command's own words, redirects, assignments and loop header,
    plus IndexAssign, ArrayAssign and AppendAssign for those assignment forms."""
    __slots__ = ("kind", "words", "raw", "pattern", "assigns", "assign_raw", "redirs", "context", "arith",
                 "indirect", "transform", "nodes")

    def __init__(self, kind, context):
        self.kind, self.context = kind, context
        self.words, self.raw, self.pattern, self.assigns, self.assign_raw, self.redirs = [], [], [], {}, {}, []
        self.arith = self.indirect = self.transform = False
        self.nodes = set()

    @property
    def background(self):
        return "background" in self.context

    @property
    def name(self):
        """The command name when it is a plain literal (no expansion, glob or brace), else None."""
        if self.words and self.words[0] is not None and not self.pattern[0]:
            return self.words[0]
        return None

    def __repr__(self):
        return (f"Cmd({self.kind}, words={self.words}, assigns={self.assigns}, redirs={self.redirs}, "
                f"context={sorted(self.context)}, arith={self.arith}, indirect={self.indirect}, "
                f"transform={self.transform}, nodes={sorted(self.nodes)})")


WORD_PARTS = ("Lit", "SglQuoted", "DblQuoted", "ParamExp", "CmdSubst", "ArithmExp", "ProcSubst", "ExtGlob")
COMMANDS = ("CallExpr", "BinaryCmd", "Block", "Subshell", "IfClause", "WhileClause", "ForClause", "CaseClause",
            "FuncDecl", "ArithmCmd", "TestClause", "DeclClause", "LetClause", "TimeClause", "CoprocClause")
ARITH_TESTS = {"-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-v", "-R"}
PLAIN_INDEX = re.compile(r"[0-9]+|[@*]")
INTEGER = re.compile(r"[0-9]+")


def _unescape(v, dq):
    if dq:
        return re.sub(r'\\([$`"\\\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), v)
    return re.sub(r"\\(.)", lambda m: "" if m.group(1) == "\n" else m.group(1), v, flags=re.S)


def _is_pattern(v):
    v = re.sub(r"\\.", "", v, flags=re.S)
    return bool(re.search(r"[*?]|\[.*\]|\{.*(,|\.\.).*\}", v))


class _Walker:
    def __init__(self, data):
        self.b = data
        self.out = []
        self.seen = set()

    def raw(self, n):
        return self.b[n["Pos"]["Offset"]:n["End"]["Offset"]].decode("utf-8", "replace")

    def typed(self, n, types):
        t = n.get("Type")
        if t not in types:
            raise ParseError(f"unhandled shell syntax: {t}")
        self.seen.add(id(n))
        return t

    def stmts(self, lst, ctx):
        for s in lst or []:
            self.stmt(s, ctx)

    def stmt(self, s, ctx):
        if s.get("Negated"):
            ctx = ctx | {"negated"}
        if s.get("Background"):
            ctx = ctx | {"background"}
        n = s.get("Cmd")
        c = Cmd(self.typed(n, COMMANDS) if n else "", ctx)
        self.out.append(c)
        c.redirs = [self.redir(r, ctx, c) for r in s.get("Redirs") or []]
        if not n:
            return
        t = c.kind
        if t == "CallExpr":
            for a in n.get("Assigns") or []:
                self.assign(a, ctx, c)
            for w in n.get("Args") or []:
                self.add_word(w, ctx, c)
        elif t == "BinaryCmd":
            sub = ctx | {"pipe"} if n["Op"] in ("|", "|&") else ctx
            self.stmt(n["X"], sub)
            self.stmt(n["Y"], sub)
        elif t == "Block":
            self.stmts(n.get("Stmts"), ctx)
        elif t == "Subshell":
            self.stmts(n.get("Stmts"), ctx | {"subshell"})
        elif t == "IfClause":
            while n:
                self.stmts(n.get("Cond"), ctx)
                self.stmts(n.get("Then"), ctx)
                n = n.get("Else")
        elif t == "WhileClause":
            self.stmts(n.get("Cond"), ctx)
            self.stmts(n.get("Do"), ctx)
        elif t == "ForClause":
            loop = n["Loop"]
            if n.get("Select"):
                c.kind = "SelectClause"
            lt = self.typed(loop, ("WordIter", "CStyleLoop"))
            c.nodes.add(lt)
            if lt == "WordIter":
                c.assigns[loop["Name"]["Value"]] = None  # the loop variable is assigned like any other
                for w in loop.get("Items") or []:
                    self.add_word(w, ctx, c)
            else:
                for k in ("Init", "Cond", "Post"):
                    if loop.get(k):
                        self.arith(loop[k], ctx, c)
            self.stmts(n.get("Do"), ctx)
        elif t == "CaseClause":
            self.add_word(n["Word"], ctx, c)
            for item in n.get("Items") or []:
                for w in item.get("Patterns") or []:
                    self.add_word(w, ctx, c)
                self.stmts(item.get("Stmts"), ctx)
        elif t == "FuncDecl":
            c.words, c.raw, c.pattern = [n["Name"]["Value"]], [n["Name"]["Value"]], [False]
            self.stmt(n["Body"], ctx | {"func"})
        elif t == "ArithmCmd":
            self.arith(n["X"], ctx, c)
        elif t == "TestClause":
            self.lit(c, "[[")
            self.test(n["X"], ctx, c)
            self.lit(c, "]]")
        elif t == "DeclClause":
            self.lit(c, n["Variant"]["Value"])
            for a in n.get("Args") or []:
                if a.get("Naked"):
                    if a.get("Value"):
                        self.add_word(a["Value"], ctx, c)
                    else:
                        self.lit(c, a["Name"]["Value"])
                else:
                    self.assign(a, ctx, c)
        elif t == "LetClause":
            self.lit(c, "let")
            for e in n.get("Exprs") or []:
                self.arith(e, ctx, c)
        elif t == "TimeClause":
            self.lit(c, "time")
            if n.get("Stmt"):
                self.stmt(n["Stmt"], ctx)
        elif t == "CoprocClause":
            self.lit(c, "coproc")
            if n.get("Name"):
                self.add_word(n["Name"], ctx, c)
            self.stmt(n["Stmt"], ctx | {"coproc"})

    def lit(self, c, v):
        c.words.append(v)
        c.raw.append(v)
        c.pattern.append(False)

    def add_word(self, w, ctx, c):
        text, pattern = self.word(w, ctx, c)
        c.words.append(text)
        c.raw.append(self.raw(w))
        c.pattern.append(pattern)

    def word(self, w, ctx, c):
        if "Type" in w:
            self.typed(w, ("Word",))
        return self.parts(w.get("Parts") or [], ctx, c, False)

    def parts(self, parts, ctx, c, dq):
        text, pattern = "", False
        for p in parts:
            t = self.typed(p, WORD_PARTS)
            c.nodes.add(t)
            if t == "Lit":
                text = text if text is None else text + _unescape(p.get("Value", ""), dq)
                pattern = pattern or (not dq and _is_pattern(p.get("Value", "")))
            elif t == "SglQuoted":
                lit = not (p.get("Dollar") and "\\" in p.get("Value", ""))
                text = text + p.get("Value", "") if lit and text is not None else None
            elif t == "DblQuoted":
                sub, _ = self.parts(p.get("Parts") or [], ctx, c, True)
                text = text + sub if sub is not None and text is not None else None
            elif t == "ExtGlob":
                pattern = True
                text = text if text is None else text + p["Op"] + p["Pattern"].get("Value", "") + ")"
            else:
                text = None
                if t == "ParamExp":
                    self.param(p, ctx, c)
                elif t == "CmdSubst":
                    self.stmts(p.get("Stmts"), ctx | {"backquote" if p.get("Backquotes") else "cmdsubst"})
                elif t == "ProcSubst":
                    self.stmts(p.get("Stmts"), ctx | {"procsubst"})
                elif t == "ArithmExp":
                    self.arith(p["X"], ctx, c)
        return text, pattern

    def param(self, p, ctx, c):
        c.indirect = c.indirect or bool(p.get("Excl"))
        c.transform = c.transform or (p.get("Exp") or {}).get("Op") == "@"
        if p.get("Index"):
            self.arith(p["Index"], ctx, c, index=True)
        if p.get("Slice"):
            for k in ("Offset", "Length"):
                if p["Slice"].get(k):
                    self.arith(p["Slice"][k], ctx, c)
        if p.get("Repl"):
            for k in ("Orig", "With"):
                if p["Repl"].get(k):
                    self.word(p["Repl"][k], ctx, c)
        if p.get("Exp") and p["Exp"].get("Word"):
            self.word(p["Exp"]["Word"], ctx, c)

    def arith(self, n, ctx, c, index=False):
        """Walk an arithmetic expression; anything but literal integers (or @/* as a subscript) sets c.arith."""
        if not self.constant(n, ctx, c, index):
            c.arith = True

    def constant(self, n, ctx, c, index=False):
        t = self.typed(n, ("BinaryArithm", "UnaryArithm", "ParenArithm", "Word"))
        c.nodes.add(t)
        if t == "Word":
            text, _ = self.word(n, ctx, c)
            return text is not None and bool((PLAIN_INDEX if index else INTEGER).fullmatch(text))
        ok = self.constant(n["X"], ctx, c)
        return self.constant(n["Y"], ctx, c) and ok if t == "BinaryArithm" else ok

    def test(self, n, ctx, c):
        t = self.typed(n, ("BinaryTest", "UnaryTest", "ParenTest", "Word"))
        c.nodes.add(t)
        if t == "Word":
            self.add_word(n, ctx, c)
        elif t == "ParenTest":
            self.test(n["X"], ctx, c)
        elif t == "UnaryTest":
            c.arith = c.arith or n["Op"] in ARITH_TESTS
            self.lit(c, n["Op"])
            self.test(n["X"], ctx, c)
        else:
            if n["Op"] in ARITH_TESTS and not all(
                    x.get("Type") == "Word" and INTEGER.fullmatch(self.raw(x)) for x in (n["X"], n["Y"])):
                c.arith = True
            self.test(n["X"], ctx, c)
            self.lit(c, n["Op"])
            self.test(n["Y"], ctx, c)

    def assign(self, a, ctx, c):
        name = a["Name"]["Value"]
        if a.get("Append"):
            c.nodes.add("AppendAssign")
        if a.get("Index"):
            c.nodes.add("IndexAssign")
            self.arith(a["Index"], ctx, c, index=True)
        value = ""
        if a.get("Value"):
            value, _ = self.word(a["Value"], ctx, c)
            c.assign_raw[name] = self.raw(a["Value"])
        if a.get("Array"):
            c.nodes.add("ArrayAssign")
            value = None
            for e in a["Array"].get("Elems") or []:
                if e.get("Index"):
                    self.arith(e["Index"], ctx, c, index=True)
                if e.get("Value"):
                    self.word(e["Value"], ctx, c)
        c.assigns[name] = value

    def redir(self, r, ctx, c):
        target, raw, body = None, None, None
        if r.get("Word"):
            target, _ = self.word(r["Word"], ctx, c)
            raw = self.raw(r["Word"])
        if r.get("Hdoc"):
            self.parts(r["Hdoc"].get("Parts") or [], ctx, c, True)
            body = self.raw(r["Hdoc"])
            if target and body.endswith(target):  # shfmt's Hdoc span ends after the delimiter line
                body = body[:-len(target)]
        return Redir(r["Op"], (r.get("N") or {}).get("Value"), target, raw, body)


def _typed_ids(tree):
    ids, stack = {}, [tree]
    while stack:
        n = stack.pop()
        if isinstance(n, dict):
            if "Type" in n:
                ids[id(n)] = n["Type"]
            stack.extend(n.values())
        elif isinstance(n, list):
            stack.extend(n)
    return ids


def _walk(data, tree):
    if tree.get("Type") != "File":
        raise ParseError("shfmt returned no File node")
    w = _Walker(data)
    w.seen.add(id(tree))
    w.stmts(tree.get("Stmts"), frozenset())
    missed = {t for i, t in _typed_ids(tree).items() if i not in w.seen}
    if missed:
        raise ParseError("unhandled shell syntax: " + ", ".join(sorted(missed)))
    return w.out


def parse_many(srcs, timeout=5.0, batch=32):
    shfmt = shutil.which("shfmt")
    if not shfmt:
        raise ShfmtMissing("shfmt not found on PATH")
    results = []
    for i in range(0, len(srcs), batch):
        procs = []
        for src in srcs[i:i + batch]:
            data = src.encode("utf-8", "surrogateescape")
            p = subprocess.Popen([shfmt, "-ln", "bash", "--to-json"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:  # feed every process before reading any, so they all parse at once
                p.stdin.write(data)
            except BrokenPipeError:
                pass
            p.stdin.close()
            procs.append((data, p))
        for data, p in procs:
            try:
                out, err = p.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                p.kill()
                p.communicate()
                results.append(ParseError("shfmt timed out"))
                continue
            if p.returncode != 0:
                msg = err.decode("utf-8", "replace").strip().splitlines()
                results.append(ParseError(msg[0] if msg else f"shfmt exit {p.returncode}"))
                continue
            try:
                results.append(_walk(data, json.loads(out)))
            except ParseError as e:
                results.append(e)
            except RecursionError:
                results.append(ParseError("too deeply nested"))
            except (ValueError, KeyError, TypeError, AttributeError) as e:
                results.append(ParseError(f"unexpected shfmt output: {e!r}"))
    return results


def parse(src, timeout=5.0):
    r = parse_many([src], timeout)[0]
    if isinstance(r, ParseError):
        raise r
    return r


if __name__ == "__main__":
    import sys
    try:
        for cmd in parse(sys.stdin.read()):
            print(cmd)
    except (ParseError, ShfmtMissing) as e:
        sys.exit(f"shellast: {e}")
