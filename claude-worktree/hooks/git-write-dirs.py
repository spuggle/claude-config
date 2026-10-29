"""Find the git operations a Bash command would run locally, for guard-bash.sh.

Usage: git-write-dirs.py <cwd> < command

Prints one tab-separated line per finding: kind, directory, argument, invocation.
Tabs and newlines inside fields are replaced by spaces, so each finding stays one
line of exactly four fields.
Kinds: write (changes the checkout it runs in; the argument is the subcommand), ref (changes a branch or tag
named in the argument, wherever it runs), push, stash (bare stash, pop, save, drop,
clear, push without -m), alias (git -c alias.*, which can hide any subcommand),
sudo (sudo, doas, pkexec or run0 in command position).
Arguments of unknown commands are never looked into, so a command run on another
host (ssh, mosh, docker exec, kubectl exec) yields nothing; inner commands of
known local launchers (bash -c, tmux new, systemd-run, env, nohup...) are parsed.
"""
import bisect
import os
import re
import sys

WRITE_OPS = {"commit", "merge", "rebase", "reset", "cherry-pick", "revert", "am", "switch", "checkout", "restore",
             "clean", "rm", "mv", "apply", "pull"}
HOME = os.path.expanduser("~")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "coproc"}
# argv wrappers: (options taking a separate argument, number of leading positional args to skip)
WRAPPERS = {
    "nohup": (set(), 0), "setsid": (set(), 0), "exec": ({"-a"}, 0), "command": (set(), 0), "builtin": (set(), 0),
    "nice": ({"-n"}, 0), "ionice": ({"-c", "-n", "-p"}, 0), "stdbuf": ({"-i", "-o", "-e"}, 0),
    "timeout": ({"-s", "-k", "--signal", "--kill-after"}, 1), "chronic": (set(), 0), "unbuffer": (set(), 0),
    "xargs": ({"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "--arg-file", "--delimiter", "--max-args",
               "--max-procs", "--max-lines", "--replace"}, 0),
    "sudo": ({"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "--user", "--group", "--chdir"}, 0),
    "doas": ({"-u", "-C"}, 0), "pkexec": ({"--user"}, 0), "run0": ({"-u", "--user", "-D", "--chdir"}, 0),
    "time": ({"-f", "-o", "--format", "--output"}, 0),
}
ROOT_TOOLS = {"sudo", "doas", "pkexec", "run0", "su"}
SUDO_PROBE_FLAGS = {"-n", "--non-interactive", "-k", "--reset-timestamp", "-K", "--remove-timestamp", "-V",
                    "--version", "-h", "--help", "-l", "--list"}
FLOCK_ARG_OPTS = {"-w", "-E", "--timeout", "--conflict-exit-code"}
PARALLEL_ARG_OPTS = {"-j", "--jobs", "-S", "--sshlogin", "-a", "--arg-file", "--colsep", "-C", "-d", "--delimiter",
                     "-I", "-n", "-N", "--joblog", "--results", "--tmpdir", "--workdir", "-E", "--env", "--timeout",
                     "--delay"}
GIT_ARG_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--exec-path"}
TMUX_CMDS = {"new", "new-session", "new-window", "neww", "split-window", "splitw", "respawn-pane", "respawnp",
             "respawn-window", "respawnw"}
TMUX_ARG_OPTS = {"-c", "-e", "-F", "-f", "-l", "-n", "-s", "-t", "-x", "-y", "-L", "-S", "-T"}
SYSTEMD_RUN_ARG_OPTS = {"-u", "--unit", "-p", "--property", "--description", "--slice", "-E", "--setenv", "--uid",
                        "--gid", "--nice", "--working-directory", "--on-active", "--on-boot", "--on-startup",
                        "--on-unit-active", "--on-unit-inactive", "--on-calendar", "--on-timezone-change",
                        "--on-clock-change", "--path-property", "--socket-property", "--timer-property", "--slice-inherit"}
BRANCH_MODIFY = {"-d", "-D", "--delete", "-f", "--force", "-m", "-M", "--move", "-c", "-C", "--copy"}
TAG_ARG_OPTS = {"-m", "--message", "-F", "--file", "-u", "--local-user", "--cleanup", "--format", "--sort",
                "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--color", "--trailer"}
BRANCH_ARG_OPTS = {"-u", "--set-upstream-to", "--format", "--sort", "--contains", "--no-contains", "--merged",
                   "--no-merged", "--points-at", "--color"}


def expand(path, cwd):
    for prefix in ("~", "$HOME", "${HOME}"):
        if path == prefix:
            path = HOME
        elif path.startswith(prefix + "/"):
            path = HOME + path[len(prefix):]
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(cwd, path))


OPS = sorted([";;&", ";;", ";&", "&&", "||", "|&", "&>>", "&>", ">>", ">&", ">|", "<<<", "<<-", "<<", "<&", "<>",
              "|", "&", ";", "(", ")", "<", ">"], key=len, reverse=True)
REDIRS = {"&>>", "&>", ">>", ">&", ">|", "<<<", "<&", "<>", "<", ">"}


class Heredoc:
    def __init__(self, delim, strip_tabs, quoted):
        self.delim, self.strip_tabs, self.quoted, self.body = delim, strip_tabs, quoted, None


_LINE_INDEX = {}


def line_index(s, strip_tabs):
    """Map each line of s (tabs stripped for <<-) to the sorted offsets where it starts; built once per string."""
    key = (id(s), strip_tabs)
    cached = _LINE_INDEX.get(key)
    if cached is not None and cached[0] is s:
        return cached[1]
    index, pos = {}, 0
    for line in s.split("\n"):
        index.setdefault(line.lstrip("\t") if strip_tabs else line, []).append(pos)
        pos += len(line) + 1
    _LINE_INDEX[key] = (s, index)
    return index


class Lexer:
    """A small Bash lexer. Items: ("word", text, subs), ("op", text), ("redir", text), ("heredoc", Heredoc).

    subs are the sources of command substitutions ($(...), `...`, <(...), >(...)) found unquoted or inside
    double quotes; single-quoted text never yields any. Here-document bodies are read after the newline that
    ends their line; a delimiter that never appears leaves the text to be lexed as commands. With nested=True
    the lexer stops at the ")" that closes a $( substitution and records its position in self.end.
    """

    def __init__(self, s, start=0, nested=False):
        self.s, self.i, self.nested, self.end = s, start, nested, None
        self.items, self.pending = [], []
        self.buf, self.subs, self.inword, self.quoted = [], [], False, False
        self.want_delim, self.depth, self.case_depth = None, 0, 0

    def flush(self):
        if not self.inword:
            return
        text = "".join(self.buf)
        if self.want_delim is not None:
            doc = Heredoc(text, self.want_delim, self.quoted)
            self.pending.append(doc)
            self.items.append(("heredoc", doc))
            self.want_delim = None
        else:
            if not self.quoted:
                self.case_depth += {"case": 1, "esac": -1}.get(text, 0)
            self.items.append(("word", text, self.subs))
        self.buf, self.subs, self.inword, self.quoted = [], [], False, False

    def add(self, text, quoted=False):
        self.buf.append(text)
        self.inword = True
        self.quoted = self.quoted or quoted

    def substitution(self, i):
        """i is just after '$('; return the index after the closing ')'."""
        inner = Lexer(self.s, i, nested=True)
        inner.run()
        self.subs.append(self.s[i:inner.end])
        return inner.end + 1

    def backticks(self, i):
        """i is just after the opening backtick; return the index after the closing one."""
        s, j, out = self.s, i, []
        while j < len(s) and s[j] != "`":
            if s[j] == "\\" and j + 1 < len(s):
                out.append(s[j + 1])
                j += 2
                continue
            out.append(s[j])
            j += 1
        if j >= len(s):
            raise ValueError("unterminated backtick")
        self.subs.append("".join(out))
        return j + 1

    def skip_balanced(self, i, open_ch, close_ch, depth=1):
        s = self.s
        while i < len(s) and depth:
            depth += {open_ch: 1, close_ch: -1}.get(s[i], 0)
            i += 1
        if depth:
            raise ValueError("unbalanced " + open_ch)
        return i

    def dollar(self, i, in_dq):
        """s[i] is '$'; consume an expansion and return the next index, or None if '$' is literal."""
        s = self.s
        nxt = s[i + 1:i + 2]
        if s.startswith("$((", i):
            j = self.skip_balanced(i + 3, "(", ")", 2)
            self.add(s[i:j], True)
            return j
        if nxt == "(":
            j = self.substitution(i + 2)
            self.add(s[i:j], True)
            return j
        if nxt == "{":
            j = self.skip_balanced(i + 2, "{", "}")
            self.add(s[i:j], True)
            return j
        if nxt == "'" and not in_dq:
            j, out = i + 2, []
            while j < len(s) and s[j] != "'":
                if s[j] == "\\" and j + 1 < len(s):
                    out.append({"n": "\n", "t": "\t"}.get(s[j + 1], s[j + 1]))
                    j += 2
                    continue
                out.append(s[j])
                j += 1
            if j >= len(s):
                raise ValueError("unterminated $'")
            self.add("".join(out), True)
            return j + 1
        return None

    def double_quoted(self, i, terminator='"'):
        """Scan double-quoted text from i up to the terminator (None: end of input); return the next index."""
        s = self.s
        self.add("", True)
        while i < len(s):
            c = s[i]
            if terminator and c == terminator:
                return i + 1
            if c == "\\" and i + 1 < len(s):
                self.add(s[i + 1] if s[i + 1] in '$`"\\\n' else s[i:i + 2], True)
                i += 2
            elif c == "$":
                j = self.dollar(i, True)
                if j is None:
                    self.add(c, True)
                    i += 1
                else:
                    i = j
            elif c == "`":
                i = self.backticks(i + 1)
            else:
                self.add(c, True)
                i += 1
        if terminator:
            raise ValueError("unterminated double quote")
        return i

    def read_heredocs(self):
        s, pos, bodies = self.s, self.i, []
        for doc in self.pending:
            starts = line_index(s, doc.strip_tabs).get(doc.delim, [])
            k = bisect.bisect_left(starts, pos)
            if k == len(starts):
                self.pending = []
                return
            start = starts[k]
            bodies.append(s[pos:max(pos, start - 1)])
            nl = s.find("\n", start)
            pos = nl + 1 if nl >= 0 else len(s)
        for doc, body in zip(self.pending, bodies):
            doc.body = body
        self.pending = []
        self.i = min(pos, len(s))

    def run(self):
        s = self.s
        while self.i < len(s):
            i, c = self.i, s[self.i]
            if c in " \t\r":
                self.flush()
                self.i += 1
            elif c == "\\":
                if s[i + 1:i + 2] == "\n":
                    self.i += 2
                else:
                    self.add(s[i + 1:i + 2], True)
                    self.i += 2
            elif c == "\n":
                self.flush()
                self.items.append(("op", "\n"))
                self.i += 1
                self.read_heredocs()
            elif c == "#" and not self.inword:
                nl = s.find("\n", i)
                self.i = nl if nl >= 0 else len(s)
            elif c == "'":
                j = s.find("'", i + 1)
                if j < 0:
                    raise ValueError("unterminated single quote")
                self.add(s[i + 1:j], True)
                self.i = j + 1
            elif c == '"':
                self.i = self.double_quoted(i + 1)
            elif c == "$":
                j = self.dollar(i, False)
                if j is None:
                    self.add(c)
                    self.i += 1
                else:
                    self.i = j
            elif c == "`":
                self.add("", True)
                self.i = self.backticks(i + 1)
            elif c in "<>" and s[i + 1:i + 2] == "(" and not self.inword:
                self.add(s[i:i + 2], True)
                j = self.substitution(i + 2)
                self.add(s[i + 2:j], True)
                self.i = j
            elif c in ";&|()<>":
                op = next(o for o in OPS if s.startswith(o, i))
                self.i = i + len(op)
                if (op in REDIRS or op in ("<<", "<<-")) and self.inword and not self.quoted \
                        and "".join(self.buf).isdigit():
                    self.buf, self.subs, self.inword = [], [], False
                self.flush()
                if op in ("<<", "<<-"):
                    self.want_delim = op == "<<-"
                elif op in REDIRS:
                    self.items.append(("redir", op))
                else:
                    if self.nested and op == ")" and self.depth == 0 and self.case_depth <= 0:
                        self.end = i
                        return self.items
                    if op == "(":
                        self.depth += 1
                    elif op == ")" and self.depth:
                        self.depth -= 1
                    self.items.append(("op", op))
            else:
                self.add(c)
                self.i += 1
        self.flush()
        if self.nested:
            raise ValueError("unterminated $(")
        return self.items


def text_substitutions(text):
    """Command substitutions in text that is expanded like a double-quoted string (an unquoted here-document)."""
    lexer = Lexer(text)
    lexer.double_quoted(0, terminator=None)
    return lexer.subs


class Command:
    def __init__(self, pipe_from):
        self.words, self.subs, self.docs, self.herestrings, self.pipe_from = [], [], [], [], pipe_from

    def stdin_texts(self):
        texts = [d.body for d in self.docs if d.body is not None] + self.herestrings
        src = self.pipe_from
        if src and src.words:
            name, args = os.path.basename(src.words[0]), src.words[1:]
            if name == "echo":
                texts.append(" ".join(a for a in args if not a.startswith("-")))
            elif name == "printf":
                operands = [a for a in args if not a.startswith("-")]
                texts.extend(operands)
                texts.append(" ".join(operands))
            elif name == "cat":
                texts.extend(src.stdin_texts())
        return texts


def build_commands(items):
    """Group lexer items into Commands, with "(" and ")" markers for subshell scope."""
    out, cur, target, pipe_from = [], None, None, None
    for item in items:
        kind = item[0]
        if kind in ("word", "redir", "heredoc") and cur is None:
            cur = Command(pipe_from)
        if kind == "word":
            cur.subs.extend(item[2])
            if target is not None:
                if target == "<<<":
                    cur.herestrings.append(item[1])
                target = None
            else:
                cur.words.append(item[1])
        elif kind == "redir":
            target = item[1]
        elif kind == "heredoc":
            cur.docs.append(item[1])
        else:
            op = item[1]
            if cur is not None:
                out.append(cur)
            pipe_from = cur if op in ("|", "|&") else None
            cur, target = None, None
            if op in ("(", ")"):
                out.append(op)
    if cur is not None:
        out.append(cur)
    return out


def skip_options(words, i, arg_opts, positionals=0):
    while i < len(words) and words[i].startswith("-") and words[i] != "-":
        if words[i] == "--":
            i += 1
            break
        i += 2 if words[i] in arg_opts else 1
    return i + positionals


def flags_and_names(args, arg_opts):
    """Split a subcommand's arguments into its flags (short ones one letter each) and its positionals."""
    flags, names, k = set(), [], 0
    while k < len(args):
        a = args[k]
        if a == "--":
            names.extend(args[k + 1:])
            break
        if a.startswith("--"):
            flags.add(a.split("=", 1)[0])
        elif a.startswith("-") and len(a) > 1:
            flags.update("-" + ch for ch in a[1:])
        else:
            names.append(a)
        k += 2 if a in arg_opts else 1
    return flags, names


def write_detail(sub, rest):
    """The argument of a write finding: the subcommand, or a finer form for index-only reset and restore.

    reset-index: git reset without a mode, with no operands, with --, or with two or more operands (it only
    changes the index). reset-one:<x>: git reset <x>, index-only unless <x> names a commit (guard-bash checks).
    restore-staged: git restore --staged without --worktree.
    """
    if sub == "reset":
        flags, names = flags_and_names(rest, {"--pathspec-from-file"})
        if flags & {"--hard", "--soft", "--mixed", "--merge", "--keep"}:
            return sub
        if not names or "--" in rest or len(names) >= 2:
            return "reset-index"
        return "reset-one:" + names[0]
    if sub == "restore":
        flags, _ = flags_and_names(rest, {"-s", "--source", "--pathspec-from-file"})
        if flags & {"-S", "--staged"} and not flags & {"-W", "--worktree"}:
            return "restore-staged"
    return sub


def bare_stash(rest):
    """Stash forms that act on the shared stack without a tag: bare, pop, save, drop, clear, push without -m."""
    if not rest or rest[0] in ("pop", "save", "drop", "clear") or rest[0].startswith("-"):
        return True
    if rest[0] == "push":
        return not any(a in ("-m", "--message") or a.startswith("--message=")
                       or (a.startswith("-") and not a.startswith("--") and "m" in a[1:]) for a in rest[1:])
    return False


def option_value(args, short, long):
    """The value of -<short> (also inside a group such as -qc) or --long[=value], or None."""
    for k, a in enumerate(args):
        if a == long or (a.startswith("-") and not a.startswith("--") and short in a[1:]):
            return args[k + 1] if k + 1 < len(args) else None
        if a.startswith(long + "="):
            return a.split("=", 1)[1]
    return None


def is_sudo_probe(options, command):
    """sudo -n true, sudo -n -l, sudo -k ...: checks or drops cached credentials without running anything."""
    if command not in ([], ["true"], [":"]) or not all(o in SUDO_PROBE_FLAGS for o in options):
        return False
    return bool(command) <= ("-n" in options or "--non-interactive" in options) and \
        (bool(command) or bool(options))


class Finder:
    def __init__(self):
        self.out = []

    def emit(self, kind, directory, invocation, arg=""):
        fields = [re.sub(r"[\t\r\n]", " ", f) for f in (kind, directory, arg, invocation)]
        self.out.append("\t".join(fields))

    def parse_string(self, command, cwd, depth=0):
        if depth > 20:
            raise RecursionError("nesting too deep")
        current, saved = cwd, []
        for cmd in build_commands(Lexer(command).run()):
            if cmd == "(":
                saved.append(current)
                continue
            if cmd == ")":
                current = saved.pop() if saved else current
                continue
            for sub in cmd.subs:
                self.parse_string(sub, current, depth + 1)
            for doc in cmd.docs:
                if doc.body is not None and not doc.quoted:
                    for sub in text_substitutions(doc.body):
                        self.parse_string(sub, current, depth + 1)
            current = self.parse_words(cmd.words, current, cmd.stdin_texts())
        return current

    def parse_words(self, words, cwd, stdin=()):
        """Handle one simple command; return the working directory afterwards."""
        i = 0
        while i < len(words):
            w, base = words[i], os.path.basename(words[i])
            if w in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
                i += 1
            elif w == "function":
                i += 2
            elif w == "time":
                i += 1
                while i < len(words) and words[i] in ("-p", "--"):
                    i += 1
            elif base == "env":
                i += 1
                while i < len(words) and (words[i].startswith("-") or "=" in words[i]):
                    if words[i] in ("-C", "--chdir") and i + 1 < len(words):
                        cwd = expand(words[i + 1], cwd)
                    elif words[i].startswith("--chdir="):
                        cwd = expand(words[i].split("=", 1)[1], cwd)
                    i += 2 if words[i] in {"-u", "-C", "--unset", "--chdir", "-S"} else 1
            elif base == "su":
                self.emit("sudo", cwd, " ".join(words[i:]))
                command = option_value(words[i + 1:], "c", "--command")
                if command is not None:
                    self.parse_string(command, cwd)
                return cwd
            elif base in WRAPPERS:
                opts, positionals = WRAPPERS[base]
                j = skip_options(words, i + 1, opts, positionals)
                if base in ROOT_TOOLS and not (base == "sudo" and is_sudo_probe(words[i + 1:j], words[j:])):
                    self.emit("sudo", cwd, " ".join(words[i:]))
                i = j
            else:
                break
        if i >= len(words):
            return cwd
        name, args = os.path.basename(words[i]), words[i + 1:]
        if name in ("cd", "pushd"):
            if not args:
                return HOME
            return cwd if args[0].startswith("-") else expand(args[0], cwd)
        if name == "git":
            self.parse_git(args, cwd)
        elif name in SHELLS:
            self.parse_shell(args, cwd, stdin)
        elif name in ("eval", "watch"):
            j = skip_options(args, 0, {"-n", "--interval", "-d"}) if name == "watch" else 0
            self.parse_string(" ".join(args[j:]), cwd)
        elif name == "flock":
            self.parse_flock(args, cwd)
        elif name == "script":
            command = option_value(args, "c", "--command")
            if command is not None:
                self.parse_string(command, cwd)
        elif name == "find":
            k = 0
            while k < len(args):
                if args[k] in ("-exec", "-execdir", "-ok", "-okdir"):
                    end = k + 1
                    while end < len(args) and args[end] not in (";", "+"):
                        end += 1
                    self.parse_words(args[k + 1:end], cwd)
                    k = end
                k += 1
        elif name == "parallel":
            j = skip_options(args, 0, PARALLEL_ARG_OPTS)
            end = j
            while end < len(args) and not args[end].startswith(":::"):
                end += 1
            self.parse_string(" ".join(args[j:end]), cwd)
        elif name == "tmux":
            self.parse_tmux(args, cwd)
        elif name == "systemd-run":
            self.parse_systemd_run(args, cwd)
        return cwd

    def parse_shell(self, args, cwd, stdin):
        """bash/sh/zsh...: -c runs its first operand; with no script operand (or -s) the shell runs stdin."""
        j, has_c, has_s = 0, False, False
        while j < len(args):
            a = args[j]
            if a == "--":
                j += 1
                break
            if a in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
                j += 2
            elif a.startswith("--"):
                j += 1
            elif a[:1] in "-+" and len(a) > 1:
                has_c = has_c or "c" in a[1:]
                has_s = has_s or "s" in a[1:]
                j += 1
            else:
                break
        if has_c:
            if j < len(args):
                self.parse_string(args[j], cwd)
        elif has_s or j >= len(args):
            for text in stdin:
                self.parse_string(text, cwd)

    def parse_flock(self, args, cwd):
        """flock [options] <file> (-c <command> | <command> [args])."""
        j = skip_options(args, 0, FLOCK_ARG_OPTS, 1)
        while j < len(args):
            a = args[j]
            if a in ("-c", "--command") and j + 1 < len(args):
                self.parse_string(args[j + 1], cwd)
                return
            if a.startswith("--command="):
                self.parse_string(a.split("=", 1)[1], cwd)
                return
            if not a.startswith("-"):
                self.parse_words(args[j:], cwd)
                return
            j += 2 if a in FLOCK_ARG_OPTS else 1

    def parse_tmux(self, args, cwd):
        j = skip_options(args, 0, TMUX_ARG_OPTS)
        if j >= len(args) or args[j] not in TMUX_CMDS:
            return
        j += 1
        start = cwd
        positional = []
        while j < len(args):
            a = args[j]
            if a.startswith("-") and len(a) > 1 and not positional:
                if a in TMUX_ARG_OPTS and j + 1 < len(args):
                    if a == "-c":
                        start = expand(args[j + 1], cwd)
                    j += 2
                    continue
                j += 1
                continue
            positional.append(a)
            j += 1
        if positional:
            self.parse_string(" ".join(positional), start)

    def parse_systemd_run(self, args, cwd):
        j, start = 0, cwd
        while j < len(args) and args[j].startswith("-"):
            a = args[j]
            if a == "--":
                j += 1
                break
            if a in {"-H", "--host", "-M", "--machine"} or a.startswith(("--host=", "--machine=")):
                return
            if a.startswith("--working-directory="):
                start = expand(a.split("=", 1)[1], cwd)
            elif a == "--working-directory" and j + 1 < len(args):
                start = expand(args[j + 1], cwd)
            j += 2 if a in SYSTEMD_RUN_ARG_OPTS else 1
        if j < len(args):
            self.parse_words(args[j:], start)

    def parse_git(self, args, cwd):
        target, git_dir, work_tree = cwd, None, None
        j = 0
        while j < len(args) and args[j].startswith("-"):
            a = args[j]
            key, eq, val = a.partition("=")
            if eq and key in GIT_ARG_OPTS:
                j += 1
            elif a in GIT_ARG_OPTS and j + 1 < len(args):
                key, val = a, args[j + 1]
                j += 2
            else:
                j += 1
                continue
            if key in ("-c", "--config-env") and val.lower().startswith("alias."):
                self.emit("alias", target, "git " + " ".join(args))
            if key == "-C":
                target = expand(val, target)
            elif key == "--git-dir":
                git_dir = expand(val, target)
            elif key == "--work-tree":
                work_tree = expand(val, target)
        if work_tree:
            target = work_tree
        elif git_dir:
            target = os.path.dirname(git_dir) if os.path.basename(git_dir) == ".git" else git_dir
        if j >= len(args):
            return
        sub, rest = args[j], args[j + 1:]
        inv = "git " + " ".join(args[:j + 2])
        if "--help" in rest or rest == ["-h"]:
            return
        if sub == "push":
            self.emit("push", target, "git " + " ".join(args))
        elif sub == "stash" and bare_stash(rest):
            self.emit("stash", target, "git " + " ".join(args))
        elif sub == "fetch":
            for spec in [a for a in rest if not a.startswith("-")][1:]:
                dst = spec.partition(":")[2]
                if dst:
                    self.emit("ref", target, "git " + " ".join(args), dst if dst.startswith("refs/") else "refs/heads/" + dst)
        elif sub == "symbolic-ref":
            flags, names = flags_and_names(rest, {"-m"})
            if flags & {"-d", "--delete"} or len(names) >= 2:
                self.emit("write", target, "git " + " ".join(args), sub)
            if len(names) >= 2 and names[0] == "HEAD":
                self.emit("ref", target, "git " + " ".join(args), names[1])
        elif sub in WRITE_OPS:
            self.emit("write", target, "git " + " ".join(args[:j + 1]), write_detail(sub, rest))
        elif sub == "worktree" and rest and rest[0] in ("remove", "move", "prune"):
            self.emit("write", target, inv, sub)
        elif sub == "branch":
            self.parse_branch(rest, target, "git " + " ".join(args))
        elif sub == "update-ref":
            k = skip_options(rest, 0, {"-m"})
            if "--stdin" in rest:
                self.emit("ref", target, "git " + " ".join(args), "--stdin")
            elif k < len(rest):
                self.emit("ref", target, "git " + " ".join(args), rest[k])
        elif sub == "tag":
            flags, names = flags_and_names(rest, TAG_ARG_OPTS)
            if flags & {"-d", "--delete"}:
                changed = names
            elif flags & {"-f", "--force"}:
                changed = names[:1]
            else:
                changed = []
            for name in changed:
                self.emit("ref", target, "git " + " ".join(args), "refs/tags/" + name)

    def parse_branch(self, rest, target, inv):
        flags, names = flags_and_names(rest, BRANCH_ARG_OPTS)
        if not flags & BRANCH_MODIFY:
            return
        if flags & {"-m", "-M", "--move", "-c", "-C", "--copy"}:
            pair = ["HEAD", names[0]] if len(names) == 1 else names[:2]
            changed = pair if flags & {"-m", "-M", "--move"} else pair[1:]
        elif flags & {"-d", "-D", "--delete"}:
            changed = names
        else:
            changed = names[:1]
        for name in changed:
            self.emit("ref", target, inv, name if name == "HEAD" or name.startswith("refs/") else "refs/heads/" + name)


LAUNCHERS = {"tmux", "bash", "sh", "zsh", "systemd-run", "ssh", "nohup", "setsid", "sudo", "env", "timeout", "xargs",
             "exec", "time", "watch"}


def fallback(finder, command, cwd):
    """Unparseable input: the old quote-blind split, which errs towards finding git commands."""
    current = cwd
    for segment in re.split(r"&&|\|\||;|\||\n|\(|\)|`", command):
        raw = segment.split()
        words = [w.strip("'\"") for w in raw]
        if not words:
            continue
        if words[0] == "cd" and len(words) > 1:
            current = expand(words[1], current)
            continue
        if words[0] in ROOT_TOOLS:
            finder.emit("sudo", current, " ".join(words))
        for i, word in enumerate(words):
            if word != "git":
                continue
            if i == 0 or words[i - 1] in {"sudo", "env", "time", "nohup", "exec", "setsid", "timeout", "xargs"} \
                    or (raw[i][:1] in "'\"" and any(w in LAUNCHERS for w in words[:i])):
                finder.parse_git(words[i + 1:], current)


def main():
    command, cwd = sys.stdin.read(), sys.argv[1]
    finder = Finder()
    try:
        finder.parse_string(command, cwd)
    except Exception:
        finder.out = []
        fallback(finder, command, cwd)
    if finder.out:
        print("\n".join(finder.out))


main()
