#!/usr/bin/env bash
# scripts/shellast.py: commands, words, redirects and contexts from shfmt's AST; fails closed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$(command -v python3)"
EMPTY="$(mktemp -d)"
trap 'rm -rf "$EMPTY"' EXIT

if ! command -v shfmt >/dev/null; then echo "SKIP  shfmt not installed"; exit 0; fi

"$PY" - "$ROOT/scripts" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import shellast as sa

bad = 0
def eq(name, got, want):
    global bad
    if got != want:
        bad += 1
        print(f"FAIL  {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok    {name}")

def calls(src):
    return [c for c in sa.parse(src) if c.kind == "CallExpr"]

def names(src):
    return [c.words[0] if c.words else None for c in calls(src)]

c = calls("A=1 B=$(x) cat 'a b' \"c$d\" e\\ f ~/g 2>/dev/null >f <<EOF\nbody $x\nEOF")[0]
eq("words: quotes and escapes removed, expansions None", c.words, ["cat", "a b", None, "e f", "~/g"])
eq("assigns", c.assigns, {"A": "1", "B": None})
eq("assign source text", c.assign_raw, {"A": "1", "B": "$(x)"})
eq("redirects", [(r.op, r.fd, r.target) for r in c.redirs], [(">", "2", "/dev/null"), (">", None, "f"), ("<<", None, "EOF")])
eq("heredoc body without the delimiter", c.redirs[2].body, "body $x\n")
eq("raw word text", c.raw[2], '"c$d"')
eq("name of \\rm is rm", calls("\\rm x")[0].name, "rm")
eq("name of r''m is rm", calls("r''m x")[0].name, "rm")
eq("a glob command name has no name", calls("/bin/r? x")[0].name, None)
eq("a brace command name has no name", calls("{rm,x}")[0].name, None)
eq("an expanded command name has no name", calls('"$(echo rm)" x')[0].name, None)
eq("$'..' with escapes is not literal", calls("echo $'\\x41'")[0].words[1], None)

def ctx(src, word):
    return sorted(next(c for c in calls(src) if c.words and c.words[0] == word).context)
eq("command substitution", ctx("echo $(rm x)", "rm"), ["cmdsubst"])
eq("backquotes", ctx("echo `rm x`", "rm"), ["backquote"])
eq("process substitution", ctx("diff <(rm x) y", "rm"), ["procsubst"])
eq("subshell", ctx("(rm x)", "rm"), ["subshell"])
eq("pipeline and negation", ctx("! a | rm x", "rm"), ["negated", "pipe"])
eq("background", ctx("cat x & touch y", "cat"), ["background"])
eq("not background after &", ctx("cat x & touch y", "touch"), [])
eq("function body", ctx("f() { rm x; }", "rm"), ["func"])
eq("coproc", ctx("coproc rm x", "rm"), ["coproc"])

nested = {
    "if/elif/else": "if a; then b; elif c; then d; else rm x; fi",
    "while/until": "while a; do b; done; until c; do rm x; done",
    "for items": "for i in $(rm x); do :; done",
    "C-style for": "for ((i=$(rm x); i<3; i++)); do :; done",
    "case": "case $(rm x) in a|b) c;; esac",
    "case body": "case y in a) rm x;; esac",
    "arithmetic command": "(( y = $(rm x) ))",
    "test clause": "[[ -f $(rm x) ]]",
    "declare array": "declare -a A=(1 $(rm x))",
    "local value": "f() { local y=$(rm x); }",
    "let": "let y=$(rm x)+1",
    "time": "time rm x",
    "parameter default": "echo ${y:-$(rm x)}",
    "parameter index": "echo ${a[$(rm x)]}",
    "parameter replace": "echo ${y/a/$(rm x)}",
    "array element": "a=(1 $(rm x))",
    "redirect target": "cat > $(rm x)",
    "here-string": "cat <<< $(rm x)",
    "heredoc body": "cat <<EOF\n$(rm x)\nEOF",
    "nested substitutions": "echo \"$(echo $(rm x))\"",
    "block with redirect": "{ rm x; } > /dev/null",
}
for label, src in nested.items():
    eq(f"finds rm in {label}", "rm" in names(src), True)
eq("quoted heredoc body is not parsed", "rm" in names("cat <<'EOF'\n$(rm x)\nEOF"), False)
eq("single-quoted text is not parsed", names("echo '$(rm x)'"), ["echo"])

def arith(src):
    return any(c.arith for c in sa.parse(src))
eq("[[ -eq ]] evaluates arithmetic", arith("[[ $x -eq 1 ]]"), True)
eq("[[ -v ]] evaluates arithmetic", arith("[[ -v x ]]"), True)
eq("$(( )) evaluates arithmetic", arith("echo $((x))"), True)
eq("slice with a variable evaluates arithmetic", arith("echo ${x:$o} ${x:1:n}"), True)
eq("literal slice, $(( )) and [[ -eq ]] on integers do not", arith("echo ${x:1:2} $((1+(2))) ${a[0]}; [[ 1 -eq 1 ]]"), False)
for src in ("echo $((x))", "(( x ))", "for ((i=x;;)); do :; done", "echo ${a[$x]}", "let x=1", "a[i]=1", "a=([i]=1)"):
    eq(f"{src} evaluates arithmetic", arith(src), True)
def nodes(src):
    return set().union(*(c.nodes for c in sa.parse(src)))
eq("nodes of words", nodes("echo 'a' \"$b\" $(c) $((1))") >= {"Lit", "SglQuoted", "DblQuoted", "ParamExp", "CmdSubst", "ArithmExp"}, True)
eq("nodes of loops and assignments", nodes("for ((;;)); do :; done; a[1]=x; b=(1); c+=1") >= {"CStyleLoop", "IndexAssign", "ArrayAssign", "AppendAssign"}, True)
eq("variable index evaluates arithmetic", arith("echo ${a[i]}"), True)
eq("[ -eq ] does not", arith('[ "$x" -eq 1 ]'), False)
eq("${a[1]} and ${v% *} do not", arith('echo ${a[1]} ${a[@]} "${v% *}"'), False)

eq("select loop kind", [c.kind for c in sa.parse("select x in a; do :; done")][0], "SelectClause")
def flag(src, attr):
    return any(getattr(c, attr) for c in sa.parse(src))
eq("${!x} is indirect", flag('echo "${!x}"', "indirect"), True)
eq("${!x:-z} is indirect", flag("echo ${!x:-z}", "indirect"), True)
eq("${x} is not indirect", flag("echo ${x} ${#x}", "indirect"), False)
eq("${x@P} is a transform", flag('echo "${x@P}"', "transform"), True)
eq("${x@Q} is a transform", flag("echo ${x@Q}", "transform"), True)
eq("${x:-@} is not", flag("echo ${x:-@}", "transform"), False)
for label, src in (("$(", "echo " + "$(" * 600 + "x" + ")" * 600), ("{", "{ " * 2000 + "x; " + "}; " * 2000)):
    try:
        sa.parse(src)
        eq(f"deep {label} nesting", "parsed", "ParseError")
    except sa.ParseError as e:
        eq(f"deep {label} nesting raises ParseError", "ParseError", "ParseError")
eq("redirect-only statement", [(c.kind, c.redirs[0].target) for c in sa.parse(">f")], [("", "f")])
eq("empty source", sa.parse(""), [])
for src in ('echo "unterminated', "if true; then", "a |"):
    try:
        sa.parse(src)
        eq(f"parse error: {src!r}", "parsed", "ParseError")
    except sa.ParseError:
        eq(f"parse error: {src!r}", "ParseError", "ParseError")
r = sa.parse_many(["echo a", "echo 'b", "echo c"])
eq("parse_many keeps order and per-source errors",
   [x[0].words if isinstance(x, list) else "error" for x in r], [["echo", "a"], "error", ["echo", "c"]])

# fail closed: unknown node types, and known nodes under fields the walker does not read
def walk(tree):
    try:
        sa._walk(b"x", tree)
        return "walked"
    except sa.ParseError as e:
        return str(e)
pos = {"Offset": 0}
lit = {"Type": "Lit", "Value": "x", "Pos": pos, "End": pos}
eq("unknown command type raises", walk({"Type": "File", "Stmts": [{"Cmd": {"Type": "NewClause"}}]}),
   "unhandled shell syntax: NewClause")
eq("unknown word part raises", walk({"Type": "File", "Stmts": [{"Cmd": {"Type": "CallExpr", "Args": [
    {"Parts": [{"Type": "NewPart"}], "Pos": pos, "End": pos}]}}]}), "unhandled shell syntax: NewPart")
eq("node under an unread field raises", walk({"Type": "File", "Stmts": [{"Cmd": {"Type": "CallExpr", "Args": [
    {"Parts": [lit], "Pos": pos, "End": pos}], "NewField": {"Type": "CmdSubst", "Stmts": []}}}]}),
   "unhandled shell syntax: CmdSubst")
sys.exit(1 if bad else 0)
EOF
rc=$?

# missing shfmt
out="$(PATH="$EMPTY" "$PY" -c "import sys; sys.path.insert(0, '$ROOT/scripts'); import shellast
try:
    shellast.parse('echo')
except shellast.ShfmtMissing:
    print('missing')")"
if [ "$out" = missing ]; then echo "ok    ShfmtMissing without shfmt"; else echo "FAIL  ShfmtMissing: $out"; rc=1; fi
# command line: exit 1 with a message on a parse error
out="$(printf 'echo "x' | "$PY" "$ROOT/scripts/shellast.py" 2>&1)"; got=$?
if [ "$got" -eq 1 ] && grep -q 'shellast: 1:6' <<<"$out"; then echo "ok    CLI parse error exits 1"; else echo "FAIL  CLI parse error: exit $got, $out"; rc=1; fi
exit "$rc"
