#!/usr/bin/env bash
# probe-facts.py: unsafe() verdicts (allowlists on the shfmt AST), every reviewer bypass refused when
# run for real, and the behaviour without shfmt (nothing run, nothing linted).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PF="$ROOT/instruction-layer/scripts/probe-facts.py"
PY="$(command -v python3)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
if ! command -v shfmt >/dev/null; then echo "SKIP  shfmt not installed"; exit 0; fi

# Bypasses found in review rounds 1 and 2, plus arithmetic on variables. Each would run touch F.
REGRESSION=(
  "x='a[\$(touch F)]'; echo \"\${!x}\""
  "x='a[\$(touch F)]'; echo \${!x:-z}"
  "x='\$(touch F)'; echo \"\${x@P}\""
  "o=-v; [ \$o 'a[\$(touch F)]' ]"
  "for o in -v; do test \"\$o\" 'a[\$(touch F)]'; done"
  "p=\$(echo 'a[%(touch F)]' | tr % '\$'); o=\$(echo ' v' | tr ' ' -); [ \$o \"\$p\" ]"
  "x=\$'a[\\x24(touch F)]'; [[ -v \$x ]]"
  "x=\$'a[\\x24(touch F)]'; [[ \$x -eq 1 ]]"
  "x='a[\$(touch F)]'; [[ \$x -eq 1 ]]"
  "x='a[\$(touch F)]'; echo \$((x))"
  "x='a[\$(touch F)]'; s=abc; echo \${s:\$x}"
  "x='a[\$(touch F)]'; echo \${a[\$x]}"
  "x='a[\$(touch F)]'; (( x ))"
  "x='a[\$(touch F)]'; for ((i=x;;)); do break; done"
  "x='a[\$(touch F)]'; printf %d \"\$x\""
  "x='a[\$(touch F)]'; let y=x"
  "x='a[\$(touch F)]'; [ -v \"\$x\" ]"
  "x='a[\$(touch F)]'; ( [ -v \"\$x\" ] )"
  "true & [ -v 'a[\$(touch F)]' ]"
  "cat </dev/tcp/\$HOSTNAME/80; touch F"
  "systemctl --ho=localhost status; touch F"
  "systemctl --mach=x status; touch F"
  "systemctl --host=example.com status; touch F"
  "systemctl -Hexample.com status; touch F"
  "getent hosts \$(touch F)"
  "cat <(touch F)"
  "echo \$(echo \$(touch F))"
  # review round 3: a for loop assigning PATH or IFS; a computed argument that becomes an option
  "for PATH in /nonexistent; do cat /etc/hostname; done; /usr/bin/touch F"
  "for IFS in a; do cat /etc/hostname; done; touch F"
  "x=-Q; lspci \"\$x\"; touch F"
  "x=--follow; tail \"\$x\" /etc/hostname; touch F"
  "x=-Q; lspci ''\$x; touch F"
  "x=Q; lspci -\$x; touch F"
  "x=Q; lspci \"-\$x\"; touch F"
)

PATH="$PATH" "$PY" - "$PF" "${REGRESSION[@]}" <<'EOF' || failures=$((failures + 1))
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pf", sys.argv[1])
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)
# (probe, "ok" = runs / "no" = refused)
CASES = [(c, "no") for c in sys.argv[2:]] + [
    # every option and construct the real probes use
    ("cat /proc/meminfo | grep MemTotal", "ok"),
    ("cat /sys/class/power_supply/BAT*/charge_control_end_threshold", "ok"),
    ("for u in a b; do t=$(lsblk -no FSTYPE /dev/disk/by-uuid/$u 2>&1); [ \"$t\" = ntfs ] || { echo \"$u: $t\"; exit 1; }; done", "ok"),
    ("v=$(grep MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2); echo \"$v kB\"; [ \"$v\" -ge 1 ] && [ \"$v\" -le 3 ]", "ok"),
    ('[ "${v% *}" = 16 ] && [ "${v##* }" -le 3 ] && [ "${v#* }" -ge 1 ]', "ok"),
    ("v=$(df -BG --output=size / | tail -1 | tr -d ' G'); [ \"$v\" -ge 58 ]", "ok"),
    ("v=$(findmnt -no FSTYPE,UUID /); [ \"$(readlink -f /dev/disk/by-label/x)\" = \"$(readlink -f /y)\" ]", "ok"),
    ('[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] && id -nG | grep -qw docker && test -S /run/x.sock', "ok"),
    ("! systemctl is-enabled -q a.service b.service", "ok"),
    ("systemctl --user is-enabled -q hwlog.timer && grep -rqs '^SystemMaxUse=1G' /etc/systemd/journald.conf.d/", "ok"),
    ('v=$(getent passwd "$USER" | cut -d: -f7); echo "$v"; [ "$v" = /bin/fish ]', "ok"),
    ("getent group wheel", "ok"),
    ("hostname -I | grep -qw 192.0.2.1", "ok"),
    ("lspci -d 10de: | grep -q 'GA000M' && test -d /sys/module/nvidia", "ok"),
    ("ls /dev/disk/by-id/a /dev/disk/by-uuid/b >/dev/null", "ok"),
    ("grep -qx 'COUNTRY=DE' /etc/iw-regdomain", "ok"),
    ("test -d ~/project && test -f ~/.ssh/remote-host.pub", "ok"),
    ("cat x 2>/dev/null; cat x &>/dev/null; cat x >&2; cat x >/dev/null 2>&1; cat < /etc/hostname", "ok"),
    ("if test -f x; then cat x; else echo no; fi", "ok"),
    ("x=1; echo \"$x\" ${a[1]} ${s:1:2} $((1 + 2))", "ok"),
    ("c\\at x", "ok"),
    # refused: commands, constructs and options outside the allowlists
    ("sysctl -w vm.swappiness=10", "no"), ("sed -i s/a/b/ /etc/x", "no"), ("/bin/rm x", "no"),
    ("cat x & touch y", "no"), ("cat x & cat y", "no"), ("\\rm x", "no"), ("r''m x", "no"), ("{rm,x}", "no"),
    ('"$X" foo', "no"), ("$CMD x", "no"), ('"$(echo rm)" x', "no"), ("command rm x", "no"), ("xargs rm", "no"),
    ("eval cat x", "no"), ("printf %s x", "no"), ("cat x | tee /tmp/y", "no"), ("cat x || rm y", "no"),
    ("echo $(rm -rf /)", "no"), ("cat `cat x`", "no"), ("cat <(cat x)", "no"), ("cat ${x:-$(rm y)}", "no"),
    ("while false; do cat x; done", "no"), ("case x in a) cat;; esac", "no"), ("(cat x)", "no"),
    ("[[ -f /x ]]", "no"), ("f() { cat; }; f", "no"), ("time cat x", "no"), ("coproc cat x", "no"),
    ("declare x=1", "no"), ("select x in a; do cat; done", "no"), (">/tmp/f", "no"),
    ("ls /x > /tmp/f", "no"), ("ls 1>/tmp/f", "no"), ("cat x >>/tmp/f", "no"), ("cat x >|/tmp/f", "no"),
    ("cat >&/tmp/f", "no"), ("cat x &>/tmp/f", "no"), ("cat <>/tmp/x", "no"), ("echo a >&-", "no"),
    ("cat <<EOF\nhello\nEOF", "no"), ("cat <<< x", "no"), ("cat < \"$f\"", "no"), ("cat </dev/udp/h/53", "no"),
    ("PATH=/tmp cat x", "no"), ("LC_ALL=C cat x", "no"), ("PATH=/tmp", "no"), ("IFS=x", "no"), ("PS4=x", "no"),
    ("a[1]=x", "no"), ("a=(1 2)", "no"), ("a+=x", "no"),
    ("hostname foo", "no"), ("hostname --file=/x", "no"), ("grep --fi=x y", "no"), ("grep -E x y", "no"),
    ("tail -f x", "no"), ("findmnt --poll", "no"), ("cut -c1 x", "no"), ("cat -- -x", "ok"), ("cat *", "no"),
    ("systemctl restart x", "no"), ("systemctl --user", "no"), ("systemctl show -p x y", "ok"),
    ("systemctl -M c status", "no"), ("systemctl $x status", "no"), ("getent hosts example.com", "no"),
    ("getent", "no"), ("[ -n \"$v\" ]", "no"), ("[ $v = 16 ]", "no"), ("[ * = x ]", "no"), ("[ x", "no"),
    ("o=$(echo x); [ \"$o\" \"$p\" = x ]", "no"), ("[ \"$o\" x ]", "no"), ("test \"$a\" \"$b\" \"$c\"", "no"),
    ("x='$(id)'", "no"), ("echo '`id`'", "no"), ("x=$'\\x41'", "no"),
    ('echo "unterminated', "no"), ("{ " * 2000 + "true; " + "}; " * 2000, "no"),
    ("echo " + "$(echo " * 600 + "x" + ")" * 600, "no"),
]
bad = 0
for cmd, want in CASES:
    why = pf.unsafe(cmd)
    if ("no" if why else "ok") != want:
        bad += 1
        print(f"FAIL  {cmd[:120]!r}: {why or 'allowed'}, want {want}")
print(f"unsafe(): {len(CASES) - bad}/{len(CASES)} verdicts as expected")
sys.exit(1 if bad else 0)
EOF

# Run every regression probe for real (backtick-free, so they fit in a Probe: `...`): each must be
# refused, and F must never appear.
mkdir -p "$WORK/run"
for p in "${REGRESSION[@]}"; do printf -- '- fact. Probe: `%s`\n' "$p"; done > "$WORK/facts.md"
out="$(cd "$WORK/run" && "$PY" "$PF" --budget 5 "$WORK/facts.md" 2>&1)"
refused="$(grep -c -- '-> refused (' <<<"$out")"
if [ "$refused" -eq "${#REGRESSION[@]}" ] && [ ! -e "$WORK/run/F" ] && [ ! -e "$WORK/F" ]; then
  echo "ok    ${#REGRESSION[@]} regression probes refused when run; F not created"
else
  echo "FAIL  regression run: $refused/${#REGRESSION[@]} refused, F exists: $([ -e "$WORK/run/F" ] && echo yes || echo no)"
  sed 's/^/      /' <<<"$out"; failures=$((failures + 1))
fi
# and the real kb store passes validation, which lints every recorded probe
REAL_KB="${KB_DIR:-$ROOT/docs/kb}"
if [ -d "$REAL_KB" ]; then
  out="$(KB_DIR="$REAL_KB" python3 "$ROOT/scripts/kb" validate 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok    real kb store validates (probes linted)"; else echo "FAIL  kb validate: $out"; failures=$((failures + 1)); fi
else echo "skip  no kb store here (private layer)"; fi

# Without shfmt nothing is run and nothing is linted.
printf -- '- fact. Probe: `touch G`\n' > "$WORK/g.md"
out="$(cd "$WORK/run" && PATH="$WORK/none" "$PY" "$PF" --budget 3 "$WORK/g.md" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "UNCHECKED $WORK/g.md:1 \`touch G\` (shfmt not installed)" ] && [ ! -e "$WORK/run/G" ]; then
  echo "ok    without shfmt: probes UNCHECKED, none run"
else
  echo "FAIL  without shfmt run: exit $rc: $out"; failures=$((failures + 1))
fi
out="$(PATH="$WORK/none" "$PY" "$PF" --lint "$WORK/g.md" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "NOTE shfmt not installed; probe safety not checked" ]; then
  echo "ok    without shfmt: --lint notes it and exits 0"
else
  echo "FAIL  without shfmt lint: exit $rc: $out"; failures=$((failures + 1))
fi
# --ssh HOST starting with '-' would be read by ssh as an option: refused
out="$("$PY" "$PF" --ssh=-oProxyCommand=x "$WORK/g.md" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "must not start with" <<<"$out"; then echo "ok    --ssh refuses a host starting with -"; else echo "FAIL  --ssh -host: exit $rc: $out"; failures=$((failures + 1)); fi
# ssh dropped by the server (exit 255, "Connection reset") is retried; a probe that ran and failed is not
mkdir -p "$WORK/bin"
cat >"$WORK/bin/ssh" <<'FAKE'
#!/bin/bash
echo x >>"$FAKE_COUNT"
if [ "$(wc -l <"$FAKE_COUNT")" -le "${FAKE_DROPS:-0}" ]; then echo "Connection reset by 192.0.2.1 port 22" >&2; exit 255; fi
exec bash -s
FAKE
chmod +x "$WORK/bin/ssh"
printf -- '- a. Probe: `test -d /`\n' >"$WORK/s1.md"
printf -- '- a. Probe: `false`\n' >"$WORK/s2.md"
export FAKE_COUNT="$WORK/count"
: >"$FAKE_COUNT"; out="$(FAKE_DROPS=1 PATH="$WORK/bin:$PATH" "$PY" "$PF" --ssh h "$WORK/s1.md" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(wc -l <"$FAKE_COUNT")" -eq 2 ]; then echo "ok    ssh drop retried once and passes"; else echo "FAIL  ssh drop retry: exit $rc, $(wc -l <"$FAKE_COUNT") runs: $out"; failures=$((failures + 1)); fi
: >"$FAKE_COUNT"; out="$(FAKE_DROPS=0 PATH="$WORK/bin:$PATH" "$PY" "$PF" --ssh h "$WORK/s2.md" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$(wc -l <"$FAKE_COUNT")" -eq 1 ] && grep -q STALE <<<"$out"; then echo "ok    a probe that ran and failed is not retried"; else echo "FAIL  real failure: exit $rc, $(wc -l <"$FAKE_COUNT") runs: $out"; failures=$((failures + 1)); fi
: >"$FAKE_COUNT"; out="$(FAKE_DROPS=9 PATH="$WORK/bin:$PATH" "$PY" "$PF" --ssh h "$WORK/s1.md" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$(wc -l <"$FAKE_COUNT")" -eq 3 ]; then echo "ok    persistent ssh failure stops after 2 retries"; else echo "FAIL  persistent drop: exit $rc, $(wc -l <"$FAKE_COUNT") runs: $out"; failures=$((failures + 1)); fi
[ "$failures" -eq 0 ]
