#!/usr/bin/env bash
# Fault-injection tests for netboot-android.sh. No network, no real DHCP server.
# Usage: tests/run.sh [name-filter]
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../netboot-android.sh"
FILTER=${1:-}
PASS=0; FAIL=0; SKIP=0
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

can_root() { [[ $(id -u) -eq 0 ]] || sudo -n true 2>/dev/null; }

# Every test runs in its own subshell with its own HOME and NETBOOT_HOME.
run_test() {
  local name=$1 tmp rc
  [[ -z $FILTER || $name == *"$FILTER"* ]] || return 0
  tmp=$(mktemp -d)
  (
    export HOME=$tmp NETBOOT_HOME=$tmp/netboot BACKUP_DIR=$tmp/bk T=$tmp
    cd "$HERE/.." || exit 99
    "$name"
  ) > "$tmp/out" 2>&1 &
  local pid=$! wd
  # a hanging test fails after TEST_TIMEOUT seconds instead of hanging the whole suite
  ( sleep "${TEST_TIMEOUT:-150}"; echo "TIMEOUT: test ran longer than ${TEST_TIMEOUT:-150}s" >> "$tmp/out"; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if (( rc == 0 )); then echo "ok   - $name"; echo P >> "$RESULTS"
  elif (( rc == 77 )); then echo "skip - $name ($(cat "$tmp/skip" 2>/dev/null))"; echo S >> "$RESULTS"
  else echo "FAIL - $name (exit $rc)"; sed 's/^/       | /' "$tmp/out" | tail -25; echo F >> "$RESULTS"; fi
  rm -rf "$tmp"
}

skip() { echo "$*" > "$T/skip"; exit 77; }
assert() { # assert "description" command...
  local d=$1; shift
  if "$@"; then return 0; fi
  echo "assertion failed: $d"; exit 1
}
src() {   # load the script's functions without running a command
  export NETBOOT_SOURCE_ONLY=1
  # shellcheck disable=SC1090
  source "$SCRIPT"
  set +e
  set_distro
}
mkroot() { mkdir -p "$ROOT" "$STATE" "$TFTP" "$HTTP" "$LIB" "$ATTEST"; }

# ---------------------------------------------------------------- tests
test_syntax() { bash -n "$SCRIPT"; }

test_root_guard() {
  out=$(NETBOOT_HOME=/ "$SCRIPT" backup 2>&1); rc=$?
  assert "refuses /" test $rc -eq 2
  out=$(NETBOOT_HOME=$HOME "$SCRIPT" backup 2>&1); rc=$?
  assert "refuses HOME" test $rc -eq 2
}

test_lock_live_and_stale() {
  mkdir -p "$NETBOOT_HOME/state/lock.d"
  sleep 30 & p=$!
  echo "$p $(sed 's/.*) //' /proc/$p/stat | awk '{print $20}')" > "$NETBOOT_HOME/state/lock.d/owner"
  "$SCRIPT" backup >/dev/null 2>&1; rc=$?
  kill $p 2>/dev/null
  assert "live lock gives exit 50" test $rc -eq 50
  echo "999999 1" > "$NETBOOT_HOME/state/lock.d/owner"
  mkdir -p "$NETBOOT_HOME/keys"; echo k > "$NETBOOT_HOME/keys/k"
  "$SCRIPT" backup >/dev/null 2>&1; rc=$?
  assert "stale lock is cleared and backup works" test $rc -eq 0
  assert "lock released" test ! -d "$NETBOOT_HOME/state/lock.d"
}

test_atomic_write() {
  src; mkroot
  echo old > "$ROOT/f"
  echo new | atomic_write "$ROOT/f"
  assert "content replaced" test "$(cat "$ROOT/f")" = new
  assert "no temp files left" test "$(ls "$ROOT" | grep -c 'f\.')" -eq 0
}

test_journal_replay() {
  can_root || skip "needs root or sudo"
  src; mkroot
  journal_push "touch '$T/undone'" >/dev/null
  assert "entry recorded" test "$(journal_count)" -eq 1
  journal_replay >/dev/null 2>&1
  assert "undo ran" test -f "$T/undone"
  assert "entry removed" test "$(journal_count)" -eq 0
}

test_heal_leftovers() {
  src; mkroot
  mkdir -p "$HTTP.new" "$STATE/.conf.abc"; echo x > "$MANIFEST.tmp"
  rmdir "$HTTP"; mkdir -p "$HTTP.old.123"; echo keep > "$HTTP.old.123/f"
  heal_safe >/dev/null 2>&1
  assert "staging removed" test ! -e "$HTTP.new"
  assert "temp conf removed" test ! -e "$STATE/.conf.abc"
  assert "manifest tmp removed" test ! -e "$MANIFEST.tmp"
  assert "previous http restored" test "$(cat "$HTTP/f")" = keep
}

mk_gate_env() {
  src; mkroot
  ( attest_init ) >/dev/null 2>&1 || skip "gpg/openssl not usable"
  BIG_BYTES=1000; VERIFIED_BOOT=0; FAMILY=squash; BOOT_LOADER=ipxe; BOOT_LOADER_AUTO=0
  KERNEL_REL=k; INITRD_REL=i; ROOTFS_REL=r.img; SHA_REL=""; UCODE_RELS=""
  echo b > "$TFTP/boot.ipxe"; echo e > "$TFTP/ipxe.efi"; echo u > "$TFTP/undionly.kpxe"
  head -c 5000 /dev/urandom > "$HTTP/r.img"; echo k > "$HTTP/k"; echo i > "$HTTP/i"
  echo c > "$DNSMASQ_CONF"; echo p > "$LIB/httpd.py"
  write_manifest >/dev/null 2>&1
}

test_gate_fast_and_small_tamper() {
  mk_gate_env
  ( verify_manifest ) >/dev/null 2>&1 || { echo "clean gate failed"; exit 1; }
  assert "big file checked by fingerprint" test "${#BIG_FAST[@]}" -ge 0
  echo evil > "$HTTP/k"
  ( verify_manifest ) >/dev/null 2>&1; rc=$?
  assert "tampered small file refused with exit 30" test $rc -eq 30
}

test_gate_big_tamper_caught() {
  mk_gate_env
  sleep 1.1
  printf 'Z' | dd of="$HTTP/r.img" bs=1 seek=7 conv=notrunc 2>/dev/null
  ( verify_manifest ) >/dev/null 2>&1; rc=$?
  assert "changed big file (new mtime) refused" test $rc -eq 30
}

test_gate_forged_mtime_caught_by_background() {
  mk_gate_env
  m=$(stat -c %Y "$HTTP/r.img")
  printf 'Z' | dd of="$HTTP/r.img" bs=1 seek=7 conv=notrunc 2>/dev/null
  touch -d "@$m" "$HTTP/r.img"
  verify_manifest >/dev/null 2>&1 || { echo "fast tier should pass a forged mtime"; exit 1; }
  mkdir -p "$RUN"; kill_servers() { :; }
  deep_verify_bg >/dev/null 2>&1; rc=$?
  assert "background verify fails" test $rc -ne 0
  assert "failure flag written" test -s "$RUN/DEEP_FAIL"
}

test_manifest_reuses_big_hashes() {
  mk_gate_env
  out=$(write_manifest 2>&1)
  assert "reuse message" grep -q "Reused hashes" <<<"$out"
}

test_hashfile_matches() {
  src; mkroot; write_libs
  head -c 3000000 /dev/urandom > "$T/b"
  a=$(python3 "$LIB/hashfile.py" "$T/b" sha256,sha512)
  assert "sha256" test "$(awk '$1=="sha256"{print $2}' <<<"$a")" = "$(sha256sum "$T/b" | cut -d' ' -f1)"
  assert "sha512" test "$(awk '$1=="sha512"{print $2}' <<<"$a")" = "$(sha512sum "$T/b" | cut -d' ' -f1)"
}

test_extract_is_atomic() {
  command -v bsdtar >/dev/null || skip "bsdtar missing"
  export ALLOW_UNVERIFIED=1
  src; mkroot
  mkdir -p "$T/w/casper"; echo V1 > "$T/w/casper/vmlinuz"; echo I1 > "$T/w/casper/initrd"
  tar -C "$T/w" -cf "$ISO" casper
  ( extract ) >/dev/null 2>&1 || { echo "first extract failed"; exit 1; }
  assert "v1 in place" test "$(cat "$HTTP/casper/vmlinuz")" = V1
  echo V2 > "$T/w/casper/vmlinuz"; tar -C "$T/w" -cf "$ISO" casper
  head -c 700 "$ISO" > "$ISO.bad"; mv "$ISO.bad" "$ISO"
  ( extract ) >/dev/null 2>&1; rc=$?
  assert "corrupt archive fails" test $rc -ne 0
  assert "v1 untouched" test "$(cat "$HTTP/casper/vmlinuz")" = V1
  assert "no staging left" test ! -e "$HTTP.new"
}

start_test_httpd() {
  src; mkroot; write_libs
  mkdir -p "$HTTP/casper" "$HTTP/iso"
  head -c 3000000 /dev/urandom > "$HTTP/casper/big"; echo hi > "$HTTP/boot.ipxe"
  head -c 1000 /dev/urandom > "$T/outside.iso"; ln -s "$T/outside.iso" "$HTTP/iso/x.iso"
  echo secret > "$T/secret"
  PHONE_IP=127.0.0.1; HTTP_PORT=$((20000 + RANDOM % 20000)); ISO="$T/outside.iso"
  start_http || { echo "httpd did not start"; cat "$HTTP_LOG.err" 2>/dev/null; exit 1; }
  B="http://127.0.0.1:$HTTP_PORT"
}

test_httpd_ranges_and_safety() {
  start_test_httpd
  code=$(curl -s -o "$T/r" -w '%{http_code}' -r 100-199 "$B/casper/big")
  assert "206 for range" test "$code" = 206
  assert "range bytes correct" cmp -s <(head -c 200 "$HTTP/casper/big" | tail -c 100) "$T/r"
  code=$(curl -s -o "$T/r2" -w '%{http_code}' -r -50 "$B/casper/big")
  assert "206 suffix" test "$code" = 206
  assert "suffix bytes correct" cmp -s <(tail -c 50 "$HTTP/casper/big") "$T/r2"
  assert "416 past end" test "$(curl -s -o /dev/null -w '%{http_code}' -r 9000000- "$B/casper/big")" = 416
  assert "traversal blocked" test "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/../secret")" = 403
  assert "allowed symlink served" test "$(curl -s -o /dev/null -w '%{http_code}' "$B/iso/x.iso")" = 200
  assert "missing is 404" test "$(curl -s -o /dev/null -w '%{http_code}' "$B/nope")" = 404
  assert "healthz" curl -fsS "$B/healthz" >/dev/null
  kill "$SERVE_HTTP_PID" 2>/dev/null
}

test_httpd_overload_returns_503() {
  start_test_httpd
  python3 - "$HTTP_PORT" <<'PY' || exit 1
import socket, sys, time, urllib.request
port = int(sys.argv[1]); socks = []
for _ in range(20):
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(b"GET /casper/big HTTP/1.1\r\nHost: x\r\n\r\n"); socks.append(s)
time.sleep(1)
try:
    urllib.request.urlopen("http://127.0.0.1:%d/boot.ipxe" % port, timeout=3); code = 200
except Exception as e:
    code = getattr(e, "code", 0)
for s in socks: s.close()
sys.exit(0 if code == 503 else 1)
PY
  kill "$SERVE_HTTP_PID" 2>/dev/null
}

test_watchdog_restarts_httpd() {
  can_root || skip "needs root or sudo"
  start_test_httpd
  printf '#!/bin/sh\necho $$ > "$PIDFILE"\nexec sleep 600\n' > "$T/fake-dnsmasq"; chmod +x "$T/fake-dnsmasq"
  export PIDFILE="$RUN/dnsmasq.pid"; mkdir -p "$RUN"
  DNSMASQ="$T/fake-dnsmasq"; DNSMASQ_CONF="$T/dm.conf"; touch "$DNSMASQ_CONF"; DNS_LOG="$ROOT/dnsmasq.log"
  net_check() { :; }
  start_dns; sleep 1
  watchdog >"$T/wd.out" 2>&1 & w=$!
  sleep 3; kill -9 "$SERVE_HTTP_PID"; sleep 8
  curl -fsS "$B/healthz" >/dev/null; rc=$?
  stop_dns; kill "$SERVE_HTTP_PID" "$w" 2>/dev/null
  assert "http answers again after kill -9" test $rc -eq 0
}

test_dnsmasq_without_a_pid_file_still_counts_as_alive() {
  can_root || skip "needs root or sudo"
  src; mkroot; mkdir -p "$RUN"
  printf '#!/bin/sh\nexec sleep 600\n' > "$T/fake-dnsmasq"; chmod +x "$T/fake-dnsmasq"
  DNSMASQ="$T/fake-dnsmasq"; DNSMASQ_CONF="$T/dm.conf"; touch "$DNSMASQ_CONF"; DNS_LOG="$ROOT/dnsmasq.log"
  start_dns
  wait_dns_up || { stop_dns; echo "healthy dnsmasq without a pid file was judged dead"; exit 1; }
  dns_alive || { stop_dns; echo "dns_alive false for a running dnsmasq"; exit 1; }
  stop_dns; kill "$DNS_JOB" 2>/dev/null
  exit 0
}

test_dnsmasq_that_exits_at_once_is_reported_dead() {
  can_root || skip "needs root or sudo"
  src; mkroot; mkdir -p "$RUN"
  printf '#!/bin/sh\necho "dnsmasq: failed to bind DHCP server socket" >&2\nexit 2\n' > "$T/fake-dnsmasq"; chmod +x "$T/fake-dnsmasq"
  DNSMASQ="$T/fake-dnsmasq"; DNSMASQ_CONF="$T/dm.conf"; touch "$DNSMASQ_CONF"; DNS_LOG="$ROOT/dnsmasq.log"
  start_dns
  wait_dns_up && { stop_dns; echo "a dnsmasq that exited was judged alive"; exit 1; }
  assert "its words are in the log" grep -q 'failed to bind' "$DNS_LOG"
}

test_restart_budget_gives_up() {
  src
  sleep() { :; }
  for _ in 1 2 3 4 5; do wd_budget || { echo "refused too early"; exit 1; }; done
  wd_budget && { echo "sixth restart should be refused"; exit 1; }
  exit 0
}

test_backup_restore_roundtrip() {
  mkdir -p "$NETBOOT_HOME"/{keys,state,downloads,http}
  echo K1 > "$NETBOOT_HOME/keys/k"; echo ISO > "$NETBOOT_HOME/downloads/a.iso"
  "$SCRIPT" backup >/dev/null 2>&1 || { echo "backup failed"; exit 1; }
  f=$(ls "$BACKUP_DIR"/netboot-manual-*.tar.gz | head -n1)
  assert "checksum file" test -s "$f.sha256"
  assert "meta file" test -s "$f.meta"
  echo K2 > "$NETBOOT_HOME/keys/k"
  "$SCRIPT" restore "$f" --dry-run >/dev/null 2>&1
  assert "dry run changes nothing" test "$(cat "$NETBOOT_HOME/keys/k")" = K2
  "$SCRIPT" restore "$f" >/dev/null 2>&1 || { echo "restore failed"; exit 1; }
  assert "keys restored" test "$(cat "$NETBOOT_HOME/keys/k")" = K1
  assert "downloads untouched" test "$(cat "$NETBOOT_HOME/downloads/a.iso")" = ISO
  echo junk >> "$f"
  "$SCRIPT" restore "$f" >/dev/null 2>&1; rc=$?
  assert "tampered archive refused" test $rc -ne 0
  assert "state not left half-restored" test ! -e "$NETBOOT_HOME.restore.NEW"
}

test_status_reports_problems() {
  out=$("$SCRIPT" status 2>&1); rc=$?
  assert "exit 1 when not ready" test $rc -eq 1
  assert "names a fix" grep -q "fix:" <<<"$out"
}

test_diagnose_flags_fat() {
  src; mkroot
  fs_type() { echo vfat; }
  diagnose
  hit=0; for t in "${F_TAG[@]}"; do [[ $t == FSTYPE ]] && hit=1; done
  assert "FAT drive is a FAIL finding" test $hit -eq 1
}

test_diagnose_detects_address_change() {
  src; mkroot
  mkdir -p "$STATE"; touch "$MANIFEST" "$LAYOUT"
  printf 'set base http://10.0.0.5:8000\n' > "$TFTP/boot.ipxe"
  resolve_network() { IFACE=eth9; PHONE_IP=10.0.0.9; }
  diagnose
  hit=0; for t in "${F_TAG[@]}"; do [[ $t == NETCHG ]] && hit=1; done
  assert "address change detected" test $hit -eq 1
}

test_error_hint_and_log() {
  mkdir -p "$NETBOOT_HOME/state/lock.d"
  sleep 30 & p=$!
  echo "$p $(sed 's/.*) //' /proc/$p/stat | awk '{print $20}')" > "$NETBOOT_HOME/state/lock.d/owner"
  out=$("$SCRIPT" backup 2>&1); kill $p 2>/dev/null
  assert "plain-English next step" grep -q "Next step" <<<"$out"
  assert "event logged" grep -q "exit code=50" "$NETBOOT_HOME/state/netboot.log"
}

# ---- easy mode (driven through a pseudo-terminal) ----
PTY_PY=$(cat <<'PY'
import os, pty, re, select, sys, time
answers = sys.argv[1].split("|") if sys.argv[1] else []
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out = b""; i = 0; end = time.time() + 40
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.6)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
    elif i < len(answers):
        os.write(fd, (answers[i] + "\n").encode()); i += 1
    else:
        break
print(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", out.decode(errors="replace")).replace("\r", ""))
PY
)

pty_run() {   # pty_run "answer1|answer2|..." command args...   -> output in $T/pty.out
  local answers=$1; shift
  python3 -I -c "$PTY_PY" "$answers" "$@" > "$T/pty.out" 2>&1
}

test_easy_first_run_asks_one_question() {
  pty_run "y|1|q" "$SCRIPT"
  assert "welcome shown" grep -q "FIRST TIME HERE" "$T/pty.out"
  assert "plain question shown" grep -q "What do you want to do?" "$T/pty.out"
  assert "rescue offered" grep -q "SystemRescue" "$T/pty.out"
  assert "no scary attestation warning" bash -c '! grep -q "Self-attestation is not set up" "$1"' _ "$T/pty.out"
  assert "choice remembered" grep -q "DISTRO='systemrescue'" "$NETBOOT_HOME/state/profile"
}

test_easy_ready_enter_runs_go() {
  cat > "$T/ready.sh" <<EOF
export NETBOOT_SOURCE_ONLY=1
source "$SCRIPT"
set_distro
mkdir -p "\$STATE"; echo "DISTRO='systemrescue'" > "\$PROFILE"
diagnose() { F_LVL=(OK); F_TAG=(DISK); F_MSG=(fine); F_FIX=(""); }
heal_safe() { :; }
go_cmd() { echo "GO-RAN"; }
easy_home
EOF
  pty_run "" bash "$T/ready.sh"
  assert "ready screen" grep -q "READY" "$T/pty.out"
  assert "waits instead of running" bash -c '! grep -q GO-RAN "$1"' _ "$T/pty.out"
  pty_run "" bash "$T/ready.sh" >/dev/null
  python3 -I -c "$PTY_PY" "|" bash "$T/ready.sh" > "$T/pty.out" 2>&1
  assert "Enter starts go" grep -q "GO-RAN" "$T/pty.out"
}

mk_signed_copy() {   # a private copy of the script, signed, then edited so its hash differs
  cp "$SCRIPT" "$T/nb.sh"; chmod +x "$T/nb.sh"
  "$T/nb.sh" attest-init >/dev/null 2>&1 || skip "gpg/openssl not usable"
  "$T/nb.sh" self-sign >/dev/null 2>&1 || exit 1
  echo "# edited" >> "$T/nb.sh"
}

test_changed_script_offers_resign() {
  mk_signed_copy
  pty_run "n" "$T/nb.sh" go
  assert "offers re-sign" grep -q "re-sign it now" "$T/pty.out"
  assert "declined: still refuses" grep -q "changed since it was last self-signed" "$T/pty.out"
  mk_signed_copy
  pty_run "y|q" "$T/nb.sh" go
  new=$(sha256sum "$T/nb.sh" | cut -d' ' -f1)
  assert "yes re-signs the edited script" grep -q "^$new" "$NETBOOT_HOME/attest/script.sha256"
}

test_yes_never_trusts_changed_script() {
  mk_signed_copy
  old=$(cat "$NETBOOT_HOME/attest/script.sha256")
  "$T/nb.sh" --yes go >/dev/null 2>&1 < /dev/null; rc=$?
  assert "refuses with integrity code" test $rc -eq 30
  assert "signature record unchanged" test "$(cat "$NETBOOT_HOME/attest/script.sha256")" = "$old"
}

test_shortcut_creates_executable() {
  "$SCRIPT" shortcut >/dev/null 2>&1 || { echo "shortcut failed"; exit 1; }
  assert "file exists and is executable" test -x "$HOME/.shortcuts/Boot-a-PC"
  assert "runs go with --yes" grep -q -- '--yes go' "$HOME/.shortcuts/Boot-a-PC"
}

test_unknown_command_suggests() {
  out=$("$SCRIPT" gx 2>&1); rc=$?
  assert "usage exit code" test $rc -eq 2
  assert "suggests go" grep -q "go" <<<"$out"
  assert "points to start here" grep -q "no arguments" <<<"$out"
}

test_help_has_start_here() {
  out=$("$SCRIPT" --help)
  assert "start here block" grep -q "START HERE" <<<"$out"
}

# ---- regression: Android's df has no -m (seen on a real phone) ----
test_free_mb_works_with_android_df() {
  src; mkdir -p "$T/bin"
  # toybox-style df: only -k, no -m and no -P
  cat > "$T/bin/df" <<'EOS'
#!/bin/sh
for a in "$@"; do case "$a" in -m|-P|-Pm|-Pk) echo "df: Unknown option '${a#-}' (see \"df --help\")" >&2; exit 1;; esac; done
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/fake 20971520 1048576 5242880 17% /"
EOS
  chmod +x "$T/bin/df"
  PATH="$T/bin:$PATH"
  got=$(free_mb "$T")
  assert "5 GB free read through df -k" test "$got" -eq 5120
  # df that fails entirely: falls back to stat -f and still returns a number
  printf '#!/bin/sh\nexit 1\n' > "$T/bin/df"
  got=$(free_mb "$T")
  assert "stat -f fallback gives a number" test "$got" -gt 0
  got=$(free_mb "$T/does/not/exist/yet")
  assert "missing path uses its parent" test "$got" -gt 0
}

test_guide_check_softens_only_fixable_failures() {
  src
  check() { echo "[-] Tool missing: gpg"; echo "[-] 3 required check(s) failed"; return 1; }
  check_soft >/dev/null 2>&1; assert "missing tools do not block the guide" test $? -eq 0
  check() { echo "[-] No root. Grant Termux root"; echo "[-] 1 required check(s) failed"; return 1; }
  check_soft >/dev/null 2>&1; assert "no root still blocks" test $? -ne 0
  check() { echo "[-] Storage: only 100 MB free"; echo "[-] 1 required check(s) failed"; return 1; }
  check_soft >/dev/null 2>&1; assert "no space still blocks" test $? -ne 0
  check() { echo "[+] all good"; return 0; }
  check_soft >/dev/null 2>&1; assert "clean check passes" test $? -eq 0
}

# ---- regressions seen on a real phone ----
test_lock_is_seen_alive_by_a_child_process() {
  src; mkroot
  acquire_lock
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup >/dev/null 2>&1; rc=$?
  assert "a second run is refused (exit 50), not treated as stale" test $rc -eq 50
  assert "lock still there" test -d "$LOCK_DIR"
}

test_lock_survives_subshell_and_nested_use() {
  src; mkroot
  acquire_lock
  ( with_lock true )
  assert "subshell using with_lock does not free the parent's lock" test -d "$LOCK_DIR"
  ( serve_like() { release_lock; }; serve_like )
  assert "subshell release is a no-op for the parent's lock" test -d "$LOCK_DIR"
  release_lock
  assert "owner can release" test ! -d "$LOCK_DIR"
  ( with_lock true )
  assert "a lock taken only inside a subshell is freed again" test ! -d "$LOCK_DIR"
}

test_fix_commands_are_runnable_text() {
  src; mkroot
  diagnose
  for f in "${F_FIX[@]}"; do
    [[ $f == *"("* ]] && { echo "fix text has prose in parentheses: $f"; exit 1; }
  done
  exit 0
}

test_missing_tools_reported_first() {
  src; mkroot
  DNSMASQ=""; PYTHON=""
  diagnose
  hit=0; for i in "${!F_TAG[@]}"; do [[ ${F_TAG[$i]} == TOOLS && ${F_LVL[$i]} == FAIL ]] && hit=1; done
  assert "TOOLS finding is a FAIL" test $hit -eq 1
}

test_missing_tools_names_exactly_what_is_absent() {
  src
  mkdir -p "$T/bin"
  for x in curl gpg; do printf '#!/bin/sh\n' > "$T/bin/$x"; chmod +x "$T/bin/$x"; done
  printf '#!/bin/sh\n' > "$T/bin/dnsmasq"; chmod +x "$T/bin/dnsmasq"
  DNSMASQ="$T/bin/dnsmasq"; PYTHON=python3
  PATH="$T/bin"
  got=$(missing_tools)
  assert "reports openssl and bsdtar only" test "$got" = "openssl bsdtar"
}

test_termux_package_list_has_split_packages() {
  assert "openssl-tool is installed (openssl binary)" grep -q 'openssl-tool' "$SCRIPT"
  assert "bsdtar package is installed" grep -qE 'libarchive bsdtar' "$SCRIPT"
  assert "deps verifies the result" grep -q 'still missing' "$SCRIPT"
}

# ---- one-time GitHub build, pinned (a local fake GitHub stands in for the real one) ----
mk_fake_github() {
  src; mkroot
  ( attest_init ) >/dev/null 2>&1 || skip "gpg/openssl not usable"
  TARGET_ARCH=x86_64; set_distro
  WEB="$T/web"; mkdir -p "$WEB/files"; PORT=$((20000 + RANDOM % 20000))
  SLUG=SecTrollz/netboot-android; COMMIT=0123456789abcdef0123456789abcdef01234567; TAG=ipxe-x86_64-111
  fp=$(ca_fpr_hex "$ATTEST/ca.crt")
  { printf 'MZ'; head -c 200 /dev/urandom; python3 -c "import sys;sys.stdout.buffer.write(bytes.fromhex('$fp'))"; } > "$WEB/files/ipxe.efi"
  head -c 5000 /dev/urandom > "$WEB/files/undionly.kpxe"
  ( cd "$WEB/files" && sha256sum ipxe.efi undionly.kpxe > SHA256SUMS )
  cp "$HERE/../.github/workflows/build-ipxe.yml" "$WEB/files/workflow.yml"
  cafp=$(openssl x509 -in "$ATTEST/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)
  write_fake_github "$WORKFLOW_SHA256" "$cafp"
  cat > "$WEB/server.py" <<'PY'
import http.server, json, sys
port, routes_file = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        routes = json.load(open(routes_file))
        f = routes.get(self.path.split("?")[0])
        if not f:
            self.send_response(404); self.end_headers(); return
        data = open(f, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  python3 "$WEB/server.py" "$PORT" "$WEB/routes.json" & WEBPID=$!
  sleep 1
  export GITHUB_API_BASE="http://127.0.0.1:$PORT" GITHUB_RAW_BASE="http://127.0.0.1:$PORT" IPXE_CURL_OPTS=""
}

write_fake_github() {   # write_fake_github WORKFLOW_HASH_IN_NOTES CA_FINGERPRINT_IN_NAME
  python3 - "$WEB" "$PORT" "$SLUG" "$TAG" "$COMMIT" "$1" "$2" <<'PY'
import json, os, sys
web, port, slug, tag, commit, wfhash, cafp = sys.argv[1:8]
files = web + "/files/"
assets = [{"name": n, "browser_download_url": "http://127.0.0.1:%s/dl/%s" % (port, n)}
          for n in ("ipxe.efi", "undionly.kpxe", "SHA256SUMS")]
rel = {"tag_name": tag, "draft": False, "name": "iPXE loader (x86_64) for CA " + cafp,
       "body": "workflow-sha256: %s\ncommit: %s\n" % (wfhash, commit), "assets": assets}
def dump(name, obj):
    path = web + "/" + name
    json.dump(obj, open(path, "w")); return path
base = "/repos/" + slug
routes = {
    base + "/releases": dump("rel_list.json", [rel]),
    base + "/releases/tags/" + tag: dump("rel_one.json", rel),
    base + "/git/ref/tags/" + tag: dump("ref.json", {"object": {"type": "commit", "sha": commit}}),
    "/%s/%s/.github/workflows/build-ipxe.yml" % (slug, commit): files + "workflow.yml",
}
for n in ("ipxe.efi", "undionly.kpxe", "SHA256SUMS"):
    routes["/dl/" + n] = files + n
json.dump(routes, open(web + "/routes.json", "w"))
PY
}

stop_fake_github() { kill "$WEBPID" 2>/dev/null; }

test_first_approval_pins_and_installs() {
  mk_fake_github
  ( ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  [[ $rc -eq 0 ]] || sed 's/^/    fetch said: /' "$T/f.out" | tail -12
  assert "approval succeeds" test $rc -eq 0
  assert "loader installed" test -s "$TFTP/ipxe.efi"
  assert "pin written" test -s "$STATE/loader-x86_64.pin"
  assert "pin is signed" test -s "$STATE/loader-x86_64.pin.asc"
  assert "pin records the tag" grep -q "^tag=$TAG" "$STATE/loader-x86_64.pin"
  assert "pin is verifiable" loader_pin_matches
}

test_without_approval_nothing_is_installed() {
  mk_fake_github
  ( ipxe_fetch <<<"n" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "declined" test $rc -ne 0
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
  assert "no pin" test ! -s "$STATE/loader-x86_64.pin"
}

test_pinned_loader_is_always_the_one_restored() {
  mk_fake_github
  ( ipxe_fetch <<<"y" ) >/dev/null 2>&1
  good=$(sha256sum "$TFTP/ipxe.efi" | cut -d' ' -f1)
  rm -f "$TFTP/ipxe.efi" "$TFTP/undionly.kpxe"
  ( ipxe_fetch ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "restore works with no prompt" test $rc -eq 0
  assert "restored bytes are the approved ones" test "$(sha256sum "$TFTP/ipxe.efi" | cut -d' ' -f1)" = "$good"
}

test_pinned_refuses_a_swapped_release() {
  mk_fake_github
  ( ipxe_fetch <<<"y" ) >/dev/null 2>&1
  # an attacker re-uploads different bytes to the same release, with matching checksums
  { printf 'MZ'; head -c 300 /dev/urandom; } > "$WEB/files/ipxe.efi"
  ( cd "$WEB/files" && sha256sum ipxe.efi undionly.kpxe > SHA256SUMS )
  rm -f "$TFTP/ipxe.efi"
  ( ipxe_fetch ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "swapped release refused with exit 30" test $rc -eq 30
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_build_that_ran_another_workflow_is_refused() {
  mk_fake_github
  write_fake_github "$(printf 'x' | sha256sum | cut -d' ' -f1)" "$cafp"
  ( ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "notes with a different workflow hash refused (30)" test $rc -eq 30
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_workflow_changed_at_the_built_commit_is_refused() {
  mk_fake_github
  echo "# tampered" >> "$WEB/files/workflow.yml"     # notes still claim the reviewed hash
  ( ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "tampered workflow at that commit refused (30)" test $rc -eq 30
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_bad_checksum_is_refused() {
  mk_fake_github
  printf 'tamper' >> "$WEB/files/ipxe.efi"
  ( ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "tampered download refused with exit 30" test $rc -eq 30
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_loader_without_my_ca_is_refused() {
  mk_fake_github
  { printf 'MZ'; head -c 400 /dev/urandom; } > "$WEB/files/ipxe.efi"
  ( cd "$WEB/files" && sha256sum ipxe.efi undionly.kpxe > SHA256SUMS )
  ( ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "foreign loader refused with exit 30" test $rc -eq 30
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_builds_for_other_certificates_are_ignored() {
  mk_fake_github
  write_fake_github "$WORKFLOW_SHA256" "AA:BB:CC"
  ( ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "no loader for my certificate" test $rc -ne 0
  assert "tells what to do" grep -q "ipxe-request" "$T/f.out"
}

test_failed_provenance_is_refused_and_good_provenance_is_recorded() {
  mk_fake_github
  mkdir -p "$T/gh"
  cat > "$T/gh/gh" <<'EOS'
#!/bin/sh
[ "$1" = auth ] && exit 0
[ "$1" = attestation ] && exit "${FAKE_GH_VERIFY_RC:-0}"
exit 0
EOS
  chmod +x "$T/gh/gh"
  PATH="$T/gh:$PATH"
  ( export FAKE_GH_VERIFY_RC=1; ipxe_fetch <<<"y" ) >"$T/f.out" 2>&1; rc=$?
  assert "provenance mismatch refused (30)" test $rc -eq 30
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
  ( export FAKE_GH_VERIFY_RC=0; ipxe_fetch <<<"y" ) >"$T/f2.out" 2>&1; rc=$?
  stop_fake_github
  assert "good provenance accepted" test $rc -eq 0
  assert "pin records attested=yes" grep -q '^attested=yes' "$STATE/loader-x86_64.pin"
}

test_unattested_default_is_no() {
  mk_fake_github
  ( ipxe_fetch </dev/null ) >"$T/f.out" 2>&1; rc=$?     # Enter/default only
  stop_fake_github
  assert "without provenance the default answer is NOT to approve" test $rc -ne 0
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_yes_flag_cannot_approve_a_loader() {
  mk_fake_github
  ASSUME_YES=1 IPXE_CLOUD_OK=0; ( ipxe_fetch ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "--yes refused (exit 2)" test $rc -eq 2
  assert "nothing installed" test ! -s "$TFTP/ipxe.efi"
}

test_heal_restores_the_approved_loader() {
  mk_fake_github
  ( ipxe_fetch <<<"y" ) >/dev/null 2>&1
  good=$(sha256sum "$TFTP/ipxe.efi" | cut -d' ' -f1)
  echo corrupt > "$TFTP/ipxe.efi"
  diagnose
  hit=0; for i in "${!F_TAG[@]}"; do [[ ${F_TAG[$i]} == LOADERPIN && ${F_LVL[$i]} == FAIL ]] && hit=1; done
  assert "status flags the changed loader" test $hit -eq 1
  heal_safe >/dev/null 2>&1
  stop_fake_github
  assert "heal put the approved bytes back" test "$(sha256sum "$TFTP/ipxe.efi" | cut -d' ' -f1)" = "$good"
}

test_cloud_flow_reuses_the_pin_without_questions() {
  mk_fake_github
  ( ipxe_fetch <<<"y" ) >/dev/null 2>&1
  rm -f "$TFTP/ipxe.efi"
  ( ipxe_cloud </dev/null ) >"$T/f.out" 2>&1; rc=$?
  stop_fake_github
  assert "no questions, success" test $rc -eq 0
  assert "loader back" test -s "$TFTP/ipxe.efi"
  assert "did not ask for a new build" bash -c '! grep -q "Do the one-time GitHub build" "$1"' _ "$T/f.out"
}

test_workflow_hash_constant_and_pins_are_current() {
  f="$HERE/../.github/workflows/build-ipxe.yml"
  src
  assert "script pins the reviewed workflow hash" test "$WORKFLOW_SHA256" = "$(sha256sum "$f" | cut -d' ' -f1)"
  assert "checkout pinned to a commit hash" grep -qE 'actions/checkout@[0-9a-f]{40}' "$f"
  assert "attestation action pinned to a commit hash" grep -qE 'actions/attest-build-provenance@[0-9a-f]{40}' "$f"
  assert "no movable action tags" bash -c '! grep -E "uses: .*@(v[0-9]|main|master|latest)" "$1" | grep -q .' _ "$f"
  assert "release is tied to the building commit" grep -q -- '--target "$GITHUB_SHA"' "$f"
  assert "records the workflow hash" grep -q 'workflow-sha256' "$f"
  assert "rejects private keys" grep -q 'PRIVATE KEY' "$f"
  assert "inputs go through env (no script injection)" grep -q 'CA_B64: ${{ inputs.ca_pem_b64 }}' "$f"
  assert "no input is expanded inside run blocks" bash -c '! grep -E "^ +[a-z]" "$1" | grep -E "\\$\\{\\{ *inputs\\." | grep -v "CA_B64:\|TARGET:" | grep -q .' _ "$f"
}

test_ipxe_request_prints_public_cert_only() {
  src; mkroot
  ( attest_init ) >/dev/null 2>&1 || skip "gpg/openssl not usable"
  out=$(ipxe_request 2>&1)
  assert "has the workflow page link" grep -q 'actions/workflows/build-ipxe.yml' <<<"$out"
  assert "warns about the default-branch requirement" grep -q 'default branch' <<<"$out"
  assert "request file written" test -s "$HOME/ipxe-request.txt"
  dec=$(base64 -d < "$HOME/ipxe-request.txt")
  assert "request is a certificate" grep -q 'BEGIN CERTIFICATE' <<<"$dec"
  assert "request has no private key" bash -c '! grep -q "PRIVATE KEY" <<<"$1"' _ "$dec"
}

test_cross_cpu_build_error_points_to_phone_build() {
  body=$(sed -n "/^build_ipxe() {/,/^}/p" "$SCRIPT")
  grep -q 'ipxe-phone' <<<"$body"
}

# ---- on-phone cross build (Termux + proot-distro Debian), simulated ----
mk_phone_sim() {   # pretend: arm64 phone in Termux, PC is x86_64
  src; mkroot
  ( attest_init ) >/dev/null 2>&1 || skip "gpg/openssl not usable"
  mkdir -p "$T/bin"
  # stand-in proot-distro: logs the call, then runs the command after "--" natively
  cat > "$T/bin/proot-distro" <<'EOS'
#!/bin/bash
echo "$*" >> "$PROOT_LOG"
case "$1" in
  login) shift; while [[ $# -gt 0 && $1 != -- ]]; do shift; done; shift; PATH="$GUEST_BIN:$PATH" exec "$@" ;;
  *) exit 0 ;;
esac
EOS
  # the cross-compiler exists only inside the Debian guest, as on a real phone
  export GUEST_BIN="$T/guestbin"; mkdir -p "$GUEST_BIN"
  have_cross_gcc() { [[ :$PATH: == *":$GUEST_BIN:"* ]]; }
  printf '#!/bin/sh\necho x86_64-linux-gnu\n' > "$GUEST_BIN/x86_64-linux-gnu-gcc"; chmod +x "$GUEST_BIN/x86_64-linux-gnu-gcc"
  cat > "$T/bin/make" <<'EOS'
#!/bin/bash
echo "make $*" >> "$MAKE_LOG"
dir=.; trust=""
while [[ $# -gt 0 ]]; do case "$1" in -C) dir=$2; shift ;; TRUST=*) trust=${1#TRUST=} ;; esac; shift; done
[[ $dir == . ]] && exit 0
mkdir -p "$dir/bin-x86_64-efi" "$dir/bin"
fp=$(openssl x509 -in "$trust" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
{ printf 'MZ'; head -c 100 /dev/urandom; python3 -c "import sys;sys.stdout.buffer.write(bytes.fromhex('$fp'))"; } > "$dir/bin-x86_64-efi/ipxe.efi"
head -c 300 /dev/urandom > "$dir/bin/undionly.kpxe"
EOS
  chmod +x "$T/bin/"*
  export PROOT_LOG="$T/proot.log" MAKE_LOG="$T/make.log"; : > "$PROOT_LOG"; : > "$MAKE_LOG"
  PATH="$T/bin:$PATH"
  # a tiny local "iPXE" repo so the pinned clone step has something to fetch
  git init -q "$T/ipxe-src" && git -C "$T/ipxe-src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  IPXE_REPO="$T/ipxe-src"; IPXE_COMMIT=$(git -C "$T/ipxe-src" rev-parse HEAD)
  git_pin_opts() { GIT_PIN_OPTS=(); }
  HOST_ARCH=aarch64; IS_TERMUX=1; TARGET_ARCH=x86_64; IPXE_CROSS=""; set_distro
}

test_phone_builds_x86_loader_through_the_debian_box() {
  mk_phone_sim
  ( build_ipxe ) >"$T/b.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    build said: /' "$T/b.out" | tail -12
  assert "build succeeds" test $rc -eq 0
  assert "loader installed" test -s "$TFTP/ipxe.efi"
  assert "ran inside the Debian box" grep -q 'login debian' "$PROOT_LOG"
  assert "cross prefix passed to make" grep -q 'CROSS=x86_64-linux-gnu-' "$MAKE_LOG"
  assert "no host CC= override" bash -c '! grep -q " CC=" "$1"' _ "$MAKE_LOG"
  assert "public inputs staged inside the source folder" grep -q "TRUST=$SRC_DIR/xin/ca.crt" "$MAKE_LOG"
}

test_debian_box_cannot_see_your_keys() {
  mk_phone_sim
  ( build_ipxe ) >"$T/b.out" 2>&1
  assert "only the source folder is shared" grep -q -- "--bind $SRC_DIR:$SRC_DIR" "$PROOT_LOG"
  assert "attestation folder is never shared" bash -c '! grep -q "$1" "$2"' _ "$ATTEST" "$PROOT_LOG"
  assert "the whole data folder is never shared" bash -c '! grep -q -- "--bind $1:$1" "$2"' _ "$ROOT" "$PROOT_LOG"
  assert "no private key was copied in" bash -c '! ls "$1"/xin | grep -qi key' _ "$SRC_DIR"
}

test_phone_without_box_is_told_the_one_command() {
  src; mkroot
  ( attest_init ) >/dev/null 2>&1 || skip "gpg/openssl not usable"
  HOST_ARCH=aarch64; IS_TERMUX=1; TARGET_ARCH=x86_64; IPXE_CROSS=""; set_distro
  have_cross_gcc() { return 1; }
  PATH="$T/emptybin:/usr/bin:/bin"; mkdir -p "$T/emptybin"
  git_pin_opts() { GIT_PIN_OPTS=(); }
  ( build_ipxe ) >"$T/b.out" 2>&1; rc=$?
  assert "refuses" test $rc -ne 0
  assert "names ipxe-phone" grep -q 'ipxe-phone' "$T/b.out"
}

test_guide_defaults_to_the_one_time_pinned_github_build() {
  cat > "$T/ip.sh" <<EOF
export NETBOOT_SOURCE_ONLY=1
source "$SCRIPT"
TARGET_ARCH=arm64          # this machine is x86_64, so the CPUs differ
set_distro
g_done_ipxe() { return 1; }
ipxe_phone() { echo "PHONE-BUILD-RAN"; }
ipxe_cloud() { echo "CLOUD-RAN"; }
guided_ipxe
EOF
  python3 -I -c "$PTY_PY" "|" bash "$T/ip.sh" > "$T/pty.out" 2>&1
  assert "Enter picks the one-time GitHub build" grep -q "CLOUD-RAN" "$T/pty.out"
  assert "on-phone build is still offered" grep -q "x86_64 compiler" "$T/pty.out"
  assert "phone build not run by default" bash -c '! grep -q PHONE-BUILD-RAN "$1"' _ "$T/pty.out"
}

# ---- seen on a real phone: running inside a proot Linux (no /dev/fd, no phone network) ----
test_script_never_uses_process_substitution() {
  # <( ) needs /dev/fd, which a proot Linux may not have
  hits=$(grep -nE '(^|[^<])<\(|>\(' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  [[ -z $hits ]] || { echo "process substitution found:"; echo "$hits"; exit 1; }
}

test_serve_refuses_inside_proot_with_a_clear_reason() {
  src; mkroot
  IS_PROOT=1
  ( serve ) >"$T/s.out" 2>&1; rc=$?
  assert "refuses with the environment exit code" test $rc -eq 10
  assert "says proot" grep -q 'proot' "$T/s.out"
  assert "tells you to go back to Termux" grep -q 'Termux' "$T/s.out"
}

test_build_uses_a_cross_compiler_already_on_the_system() {
  mk_phone_sim
  rm -f "$T/bin/proot-distro"; IS_TERMUX=0          # a plain arm64 Linux with the cross-compiler installed
  PATH="$GUEST_BIN:$PATH"
  ( build_ipxe ) >"$T/b.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    build said: /' "$T/b.out" | tail -10
  assert "build succeeds" test $rc -eq 0
  assert "cross prefix used" grep -q 'CROSS=x86_64-linux-gnu-' "$MAKE_LOG"
  assert "no proot-distro involved" bash -c '! test -s "$1"' _ "$PROOT_LOG"
}

test_proot_build_flow_uses_the_termux_certificate() {
  mk_phone_sim
  rm -f "$T/bin/proot-distro"; IS_TERMUX=0; IS_PROOT=1; PATH="$GUEST_BIN:$PATH"
  cp "$ATTEST/ca.crt" "$T/termux-ca.crt"
  ( proot_build_flow <<<"$T/termux-ca.crt" ) >"$T/b.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    flow said: /' "$T/b.out" | tail -10
  assert "flow succeeds" test $rc -eq 0
  assert "loader built" test -s "$TFTP/ipxe.efi"
  assert "builds with the copied certificate" grep -q "TRUST=$T/termux-ca.crt" "$MAKE_LOG"
  assert "prints the copy-back steps" grep -q 'import-ipxe' "$T/b.out"
  assert "never asks for private keys" bash -c '! grep -qi "private key" "$1" || grep -q "PRIVATE KEY" "$1"' _ "$T/b.out"
}

test_proot_build_flow_refuses_private_keys_and_non_ca() {
  mk_phone_sim
  rm -f "$T/bin/proot-distro"; IS_TERMUX=0; IS_PROOT=1; PATH="$GUEST_BIN:$PATH"
  { echo "-----BEGIN PRIVATE KEY-----"; echo abc; echo "-----END PRIVATE KEY-----"; } > "$T/bad.key"
  ( proot_build_flow <<<"$T/bad.key" ) >"$T/b.out" 2>&1; rc=$?
  assert "private key refused (30)" test $rc -eq 30
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/leaf.key" -out "$T/leaf.crt" -subj /CN=leaf -days 2 \
    -addext basicConstraints=critical,CA:FALSE >/dev/null 2>&1 || skip "openssl cannot make the test certificate"
  ( proot_build_flow <<<"$T/leaf.crt" ) >"$T/b2.out" 2>&1; rc=$?
  assert "a non-CA certificate is refused (30)" test $rc -eq 30
  assert "nothing built" test ! -s "$TFTP/ipxe.efi"
}

test_importing_your_own_loader_replaces_the_github_approval() {
  mk_fake_github
  ( ipxe_fetch <<<"y" ) >/dev/null 2>&1
  assert "pinned first" test -s "$STATE/loader-x86_64.pin"
  mkdir -p "$T/mine"; cp "$TFTP/ipxe.efi" "$T/mine/ipxe.efi"; cp "$TFTP/undionly.kpxe" "$T/mine/undionly.kpxe"
  printf 'x' >> "$T/mine/undionly.kpxe"          # a different, self-built file
  ( import_ipxe "$T/mine" ) >"$T/i.out" 2>&1
  stop_fake_github
  assert "approval cleared" test ! -s "$STATE/loader-x86_64.pin"
  assert "tells you" grep -q 'approval was cleared' "$T/i.out"
  heal_safe >/dev/null 2>&1
  assert "heal does not overwrite your own loader" test "$(sha256sum "$TFTP/undionly.kpxe" | cut -d' ' -f1)" = "$(sha256sum "$T/mine/undionly.kpxe" | cut -d' ' -f1)"
}

# ---- seen on a real phone: a finished 6 GB download was deleted over a key-lookup problem ----
mk_fetch_env() {   # the script's own (resumable) file server stands in for the Ubuntu mirror
  PORT=$((20000 + RANDOM % 20000))
  export ISO_URL="http://127.0.0.1:$PORT/x.iso"      # must be set BEFORE the script is sourced
  src; mkroot; write_libs
  # never let a test download a real image
  [[ $ISO_URL == http://127.0.0.1:* && $U_ISO_URL == "$ISO_URL" ]] || { echo "refusing: ISO_URL override did not take effect"; exit 1; }
  WEBDIR="$T/srv/a/b/mirror"; mkdir -p "$WEBDIR"     # deeper than the finder looks
  head -c 3000000 /dev/urandom > "$WEBDIR/x.iso"
  HTTPD_LOG="$T/web.log" python3 "$LIB/httpd.py" 127.0.0.1 "$PORT" "$WEBDIR" >/dev/null 2>&1 & WEBPID=$!
  sleep 1
  mkdir -p "$DL"
  prepare_keyring() { :; }
  VCOUNT_FILE="$T/vcount"; echo 0 > "$VCOUNT_FILE"
}

fake_verify() {   # fake_verify RC...  returns each rc in turn (last one repeats), leaving the records fetch expects
  FAKE_RCS=("$@")
  verify_download() {
    local n; n=$(cat "$VCOUNT_FILE"); echo $((n+1)) > "$VCOUNT_FILE"
    local rc=${FAKE_RCS[$n]:-${FAKE_RCS[${#FAKE_RCS[@]}-1]}}
    if [[ $rc -eq 0 ]]; then : > "$VERIFY_REC.tmp"; echo abc123 > "$VERIFY_REC.sha"; fi
    return "$rc"
  }
}

gets() { grep -c 'GET /x.iso' "$T/web.log" || true; }

test_key_or_network_trouble_keeps_the_finished_download() {
  mk_fetch_env; fake_verify 1
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "fetch reports a problem (exit 20)" test $rc -eq 20
  assert "the finished download is kept as the ISO" test -s "$ISO"
  assert "same size as the mirror's file" test "$(file_size "$ISO")" = "$(file_size "$WEBDIR/x.iso")"
  assert "no partial file left behind" test ! -e "$ISO.part"
  assert "says it was kept" grep -q 'kept' "$T/f.out"
}

test_next_run_only_verifies_it_does_not_download_again() {
  mk_fetch_env; fake_verify 1 0
  ( fetch ) >/dev/null 2>&1
  before=$(gets)
  ( fetch ) >"$T/f2.out" 2>&1; rc=$?
  after=$(gets)
  kill $WEBPID 2>/dev/null
  assert "second run succeeds" test $rc -eq 0
  assert "no second download" test "$before" = "$after"
  assert "marked verified" iso_is_verified
}

test_a_genuinely_bad_image_is_discarded() {
  mk_fetch_env; fake_verify 30
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "exit 30" test $rc -eq 30
  assert "image removed" test ! -e "$ISO"
  assert "partial removed" test ! -e "$ISO.part"
}

test_a_stale_partial_file_gets_exactly_one_clean_retry() {
  mk_fetch_env; fake_verify 30 0
  head -c 100000 "$WEBDIR/x.iso" | tr 'a-z' 'A-Z' > "$ISO.part"        # a corrupt partial from an earlier run
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  [[ $rc -eq 0 ]] || sed 's/^/    fetch said: /' "$T/f.out" | tail -12
  assert "ends verified after one retry" test $rc -eq 0
  assert "downloaded the clean copy" test "$(sha256sum < "$ISO" | cut -d' ' -f1)" = "$(sha256sum < "$WEBDIR/x.iso" | cut -d' ' -f1)"
  assert "mentions the retry" grep -q 'from scratch, once' "$T/f.out"
}

test_missing_key_is_caught_before_the_big_download() {
  mk_fetch_env; fake_verify 0
  prepare_keyring() { die "$E_NET" "key not confirmed"; }
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "stops with the network exit code" test $rc -eq 20
  assert "nothing was downloaded" test "$(gets)" = 0
  assert "no ISO or partial" bash -c '! test -e "$1" && ! test -e "$1.part"' _ "$ISO"
}

test_ubuntu_has_a_second_independent_key_source() {
  src
  for d in ubuntu ubuntu24; do
    DISTRO=$d; TARGET_ARCH=x86_64; set_distro
    assert "$d has a package-archive key source" bash -c '[[ $1 == deb:https://archive.ubuntu.com/* ]]' _ "$KEY_EXTRA_URL"
  done
}

test_key_can_be_taken_from_a_deb_package() {
  src
  need_ok=0; command -v bsdtar >/dev/null && need_ok=1
  [[ $need_ok -eq 1 ]] || skip "bsdtar missing"
  mkdir -p "$T/pkg/usr/share/keyrings"
  echo "KEYRING-BYTES" > "$T/pkg/usr/share/keyrings/ubuntu-cdimage-keyring.gpg"
  ( cd "$T/pkg" && bsdtar -czf ../data.tar.gz ./usr ) ; echo 2.0 > "$T/debian-binary"
  ( cd "$T" && bsdtar --format ar -cf fake_1.deb debian-binary data.tar.gz )
  deb_extract_member "$T/fake_1.deb" usr/share/keyrings/ubuntu-cdimage-keyring.gpg "$T/out.gpg"
  assert "extracted the right file" test "$(cat "$T/out.gpg")" = "KEYRING-BYTES"
  assert "a missing member fails cleanly" bash -c '! deb_extract_member "$1" nope/none "$2"' _ "$T/fake_1.deb" "$T/o2" 2>/dev/null || true
  idx='<a href="ubuntu-keyring_2021.03.26_all.deb">a</a> <a href="ubuntu-keyring_2026.08.18_all.deb">b</a> <a href="ubuntu-keyring_2023.11.28.1_all.deb">c</a> <a href="other_9.9_all.deb">x</a>'
  assert "newest package is chosen" test "$(latest_deb_name ubuntu-keyring <<<"$idx")" = "ubuntu-keyring_2026.08.18_all.deb"
}

test_one_key_source_is_refused_unless_you_say_otherwise() {
  src
  assert "default needs two sources" test "$KEY_MIN_SOURCES" = 2
}

test_a_mirror_that_cannot_resume_restarts_cleanly() {
  mk_fetch_env; fake_verify 0
  kill $WEBPID 2>/dev/null; sleep 0.5
  ( cd "$WEBDIR" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) & WEBPID=$!    # no Range support
  sleep 1
  head -c 100000 "$WEBDIR/x.iso" | tr 'a-z' 'A-Z' > "$ISO.part"
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "completes" test $rc -eq 0
  assert "clean copy, not the corrupt prefix" test "$(sha256sum < "$ISO" | cut -d' ' -f1)" = "$(sha256sum < "$WEBDIR/x.iso" | cut -d' ' -f1)"
  assert "said why it started over" grep -q 'does not support resuming' "$T/f.out"
}

# ---- reuse an earlier download instead of downloading again ----
mk_old_download() {   # mk_old_download NAME  (a complete copy of the mirror's image in a Downloads folder)
  mkdir -p "$T/Downloads"
  export EXTRA_ISO_DIRS="$T/Downloads"
}

test_an_earlier_download_is_found_and_not_fetched_again() {
  mk_old_download; mk_fetch_env; fake_verify 0
  cp "$WEBDIR/x.iso" "$T/Downloads/x.iso"
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "succeeds" test $rc -eq 0
  assert "found it" grep -q 'Found an earlier download' "$T/f.out"
  assert "no GET of the image at all" test "$(gets)" = 0
  assert "verified" iso_is_verified
  assert "the original is untouched" test -s "$T/Downloads/x.iso"
}

test_an_unfinished_download_elsewhere_is_resumed() {
  mk_old_download; mk_fetch_env; fake_verify 0
  head -c 1500000 "$WEBDIR/x.iso" > "$T/Downloads/x.iso.part"
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "succeeds" test $rc -eq 0
  assert "says it resumed" grep -q 'Found an unfinished download' "$T/f.out"
  assert "got the complete, correct file" test "$(sha256sum < "$ISO" | cut -d' ' -f1)" = "$(sha256sum < "$WEBDIR/x.iso" | cut -d' ' -f1)"
  assert "only the rest was fetched (partial-content reply)" grep -q ' 206 ' "$T/web.log"
}

test_a_wrong_size_file_is_ignored_not_trusted() {
  mk_old_download; mk_fetch_env; fake_verify 0
  head -c 1000000 "$WEBDIR/x.iso" > "$T/Downloads/x.iso"
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "still succeeds" test $rc -eq 0
  assert "ignored the short file" grep -q 'Ignoring' "$T/f.out"
  assert "downloaded the real image" test "$(file_size "$ISO")" = "$(file_size "$WEBDIR/x.iso")"
}

test_your_file_is_never_deleted_even_if_it_fails_verification() {
  mk_old_download; mk_fetch_env; fake_verify 30
  cp "$WEBDIR/x.iso" "$T/Downloads/x.iso"
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "refused (30)" test $rc -eq 30
  assert "the original file is still there" test -s "$T/Downloads/x.iso"
}

test_iso_option_uses_the_file_you_name() {
  mkdir -p "$T/mine"; export ISO_FILE="$T/mine/whatever-name.iso"
  mk_fetch_env; fake_verify 0
  cp "$WEBDIR/x.iso" "$ISO_FILE"
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "succeeds" test $rc -eq 0
  assert "no download" test "$(gets)" = 0
  unset ISO_FILE
}

test_iso_option_with_a_missing_file_is_a_clear_error() {
  export ISO_FILE="$T/nope.iso"
  mk_fetch_env
  ( fetch ) >"$T/f.out" 2>&1; rc=$?
  kill $WEBPID 2>/dev/null
  assert "usage error (2)" test $rc -eq 2
  assert "names the file" grep -q 'nope.iso' "$T/f.out"
}

test_ct_paging_loop_counter_is_not_clobbered() {
  # seen on a real phone: "arithmetic syntax error ... 2 17174131604" in ct_current
  src; mkroot; write_libs
  PYTHON=python3
  : > "$T/ct.calls"
  ct_get() {   # first page has results, the next page is empty
    echo x >> "$T/ct.calls"
    if [[ $(wc -l < "$T/ct.calls") -eq 1 ]]; then
      echo '[{"id":"11","dns_names":["a.example"],"pubkey_sha256":"00","not_before":"2020-01-01T00:00:00Z","not_after":"2099-01-01T00:00:00Z"},{"id":"17174131604"}]' > "$2"
    else
      echo '[]' > "$2"
    fi
  }
  sleep() { :; }
  out=$(ct_current a.example "$T" 2>&1); rc=$?
  assert "no arithmetic error" bash -c '! grep -q "arithmetic syntax" <<<"$1"' _ "$out"
  assert "succeeds" test $rc -eq 0
  assert "second page was requested" test "$(wc -l < "$T/ct.calls")" -ge 2
}

# ---- the automatic backup is a convenience, not a requirement ----
count_backups() { local f n=0; for f in "$BACKUP_DIR"/netboot-*.tar.gz; do [[ -e $f ]] && n=$((n+1)); done; echo "$n"; }

mk_backup_env() {
  src; mkroot
  mkdir -p "$ROOT/keys" "$ROOT/downloads" "$ROOT/http"
  echo k1 > "$ROOT/keys/k"; echo big > "$ROOT/downloads/x.iso"; echo served > "$ROOT/http/f"
  AUTO_BACKUP=1; BACKUP_FP_FILE="$BACKUP_DIR/.last-fingerprint"
}

test_auto_backup_runs_once_then_skips_when_nothing_changed() {
  mk_backup_env
  auto_backup serve >/dev/null 2>&1
  assert "first run makes a backup" test "$(count_backups)" -eq 1
  sleep 1.1
  out=$(auto_backup serve 2>&1)
  assert "second run makes none" test "$(count_backups)" -eq 1
  assert "says why" grep -q 'Nothing has changed' <<<"$out"
}

test_auto_backup_runs_again_when_a_real_file_changes() {
  mk_backup_env
  auto_backup serve >/dev/null 2>&1
  sleep 1.1; echo k2 > "$ROOT/keys/k"
  auto_backup serve >/dev/null 2>&1
  assert "changed keys trigger a new backup" test "$(count_backups)" -eq 2
}

test_logs_locks_and_big_downloads_do_not_trigger_a_backup() {
  mk_backup_env
  auto_backup serve >/dev/null 2>&1
  sleep 1.1
  echo line >> "$STATE/netboot.log"; echo now > "$STATE/last-serve"; echo x > "$ROOT/http.log"
  mkdir -p "$STATE/lock.d"; echo 1 > "$STATE/lock.d/owner"
  echo "more iso bytes" >> "$ROOT/downloads/x.iso"; echo more >> "$ROOT/http/f"
  auto_backup serve >/dev/null 2>&1
  assert "still only one backup" test "$(count_backups)" -eq 1
}

test_a_failing_backup_never_stops_serving() {
  mk_backup_env
  backup_create() { return 1; }
  out=$(auto_backup serve 2>&1); rc=$?
  assert "auto_backup returns success" test $rc -eq 0
  assert "tells you it carried on" grep -q 'continuing without it' <<<"$out"
}

test_backup_auto_off_is_remembered_and_the_flag_skips_one_run() {
  src; mkroot
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup-auto off >/dev/null 2>&1
  assert "saved in the settings file" grep -q "^AUTO_BACKUP='0'" "$STATE/backup.conf"
  mkdir -p "$ROOT/keys"; echo k > "$ROOT/keys/k"
  out=$(NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup-auto 2>&1)
  assert "reports only-when-asked" grep -q 'ONLY WHEN YOU ASK' <<<"$out"
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup-auto on >/dev/null 2>&1
  assert "can be turned back on" grep -q "^AUTO_BACKUP='1'" "$STATE/backup.conf"
  out=$(NETBOOT_SOURCE_ONLY=0 "$SCRIPT" --no-backup backup-auto 2>&1)
  assert "--no-backup is understood" grep -q 'ONLY WHEN YOU ASK' <<<"$out"
}

test_a_manual_backup_always_runs() {
  mk_backup_env
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup >/dev/null 2>&1; sleep 1.1
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup >/dev/null 2>&1
  assert "two manual backups, two archives" test "$(count_backups)" -eq 2
}

# ---- Ubuntu's signed boot files (shim + grub): Secure Boot route ----
mk_fake_archive() {   # a local stand-in for archive.ubuntu.com, signed with a throwaway key
  src; mkroot
  command -v bsdtar >/dev/null && command -v xz >/dev/null || skip "bsdtar/xz missing"
  DISTRO=ubuntu; TARGET_ARCH=x86_64; BOOT_LOADER=shim; set_distro
  A="$T/arch"; GH="$T/archgpg"; mkdir -p "$A" "$GH"; chmod 700 "$GH"
  gpg --homedir "$GH" --batch --passphrase '' --quick-gen-key "Fake Archive <a@a>" ed25519 sign never >/dev/null 2>&1 || skip "gpg cannot make a key"
  FPR=$(gpg --homedir "$GH" --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')
  gpg --homedir "$GH" --export "$FPR" > "$T/archive-keyring.gpg"
  UBUNTU_ARCHIVE_FPRS="$FPR"
  # packages: each deb holds the files shim_fetch pulls out
  mkdir -p "$T/pk/shim/usr/lib/shim" "$T/pk/grub/usr/lib/grub/x86_64-efi-signed" "$A/pool/main/s/shim-signed" "$A/pool/main/g/grub2-signed"
  printf 'MZ-shim-signed-by-microsoft' > "$T/pk/shim/usr/lib/shim/shimx64.efi.signed.latest"
  printf 'MZ-mokmanager' > "$T/pk/shim/usr/lib/shim/mmx64.efi"
  printf 'MZ-grub-net-signed-by-canonical' > "$T/pk/grub/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed"
  echo 2.0 > "$T/debian-binary"
  mkdir -p "$T/d1" "$T/d2"; cp "$T/debian-binary" "$T/d1/"; cp "$T/debian-binary" "$T/d2/"
  ( cd "$T/pk/shim" && bsdtar -czf "$T/d1/data.tar.gz" ./usr ) && ( cd "$T/d1" && bsdtar --format ar -cf "$A/pool/main/s/shim-signed/shim-signed_9_amd64.deb" debian-binary data.tar.gz )
  ( cd "$T/pk/grub" && bsdtar -czf "$T/d2/data.tar.gz" ./usr ) && ( cd "$T/d2" && bsdtar --format ar -cf "$A/pool/main/g/grub2-signed/grub-efi-amd64-signed_9_amd64.deb" debian-binary data.tar.gz )
  build_fake_release
  vfetch() { local rel=${1#"$UBUNTU_ARCHIVE"/}; [[ -f $A/$rel ]] || return 1; cp "$A/$rel" "$2"; }
  fetch_key_source() { cp "$T/archive-keyring.gpg" "$2"; }
}

build_fake_release() {   # (re)writes the package list and the signed release file
  local d="$A/dists/resolute/main/binary-amd64" sh gr
  mkdir -p "$d"
  sh=$(sha256sum "$A/pool/main/s/shim-signed/shim-signed_9_amd64.deb" | cut -d' ' -f1)
  gr=$(sha256sum "$A/pool/main/g/grub2-signed/grub-efi-amd64-signed_9_amd64.deb" | cut -d' ' -f1)
  printf 'Package: shim-signed\nVersion: 9\nFilename: pool/main/s/shim-signed/shim-signed_9_amd64.deb\nSHA256: %s\n\nPackage: grub-efi-amd64-signed\nVersion: 9\nFilename: pool/main/g/grub2-signed/grub-efi-amd64-signed_9_amd64.deb\nSHA256: %s\n' "$sh" "$gr" > "$d/Packages"
  xz -c "$d/Packages" > "$d/Packages.xz"
  printf 'Origin: Ubuntu\nCodename: resolute\nSHA256:\n %s %s main/binary-amd64/Packages.xz\n' "$(sha256sum "$d/Packages.xz" | cut -d' ' -f1)" "$(stat -c %s "$d/Packages.xz")" > "$A/dists/resolute/Release"
  gpg --homedir "$GH" --batch --yes --clearsign --output "$A/dists/resolute/InRelease" "$A/dists/resolute/Release" >/dev/null 2>&1
}

test_ubuntu_signed_boot_files_are_fetched_and_verified() {
  mk_fake_archive
  ( shim_fetch ) >"$T/s.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    shim said: /' "$T/s.out" | tail -14
  assert "succeeds" test $rc -eq 0
  assert "shim installed" test "$(cat "$TFTP/shimx64.efi")" = "MZ-shim-signed-by-microsoft"
  assert "netboot grub installed as grubx64.efi" test "$(cat "$TFTP/grubx64.efi")" = "MZ-grub-net-signed-by-canonical"
  assert "mokmanager installed" test -s "$TFTP/mmx64.efi"
  assert "record written" grep -q '^shim-signed=9' "$STATE/shim-x86_64.built-from"
  assert "shim_ready" shim_ready
}

test_release_signed_by_another_key_is_refused() {
  mk_fake_archive
  GH2="$T/evilgpg"; mkdir -p "$GH2"; chmod 700 "$GH2"
  gpg --homedir "$GH2" --batch --passphrase '' --quick-gen-key "Evil <e@e>" ed25519 sign never >/dev/null 2>&1
  gpg --homedir "$GH2" --batch --yes --clearsign --output "$A/dists/resolute/InRelease" "$A/dists/resolute/Release" >/dev/null 2>&1
  ( shim_fetch ) >"$T/s.out" 2>&1; rc=$?
  assert "refused (30)" test $rc -eq 30
  assert "nothing installed" test ! -e "$TFTP/shimx64.efi"
}

test_a_tampered_package_list_is_refused() {
  mk_fake_archive
  printf 'Package: shim-signed\nVersion: 99\nFilename: pool/evil.deb\nSHA256: 00\n' | xz -c > "$A/dists/resolute/main/binary-amd64/Packages.xz"
  ( shim_fetch ) >"$T/s.out" 2>&1; rc=$?
  assert "refused (30)" test $rc -eq 30
  assert "nothing installed" test ! -e "$TFTP/shimx64.efi"
}

test_a_tampered_package_is_refused() {
  mk_fake_archive
  printf 'tamper' >> "$A/pool/main/s/shim-signed/shim-signed_9_amd64.deb"
  ( shim_fetch ) >"$T/s.out" 2>&1; rc=$?
  assert "refused (30)" test $rc -eq 30
  assert "nothing installed" test ! -e "$TFTP/shimx64.efi"
}

test_a_downgrade_to_an_older_version_is_not_chosen() {
  mk_fake_archive
  # a second pocket advertises an OLDER version: the newer one must win
  mkdir -p "$A/dists/resolute-updates/main/binary-amd64"
  sed 's/^Version: 9/Version: 3/' "$A/dists/resolute/main/binary-amd64/Packages" > "$A/dists/resolute-updates/main/binary-amd64/Packages"
  xz -c "$A/dists/resolute-updates/main/binary-amd64/Packages" > "$A/dists/resolute-updates/main/binary-amd64/Packages.xz"
  printf 'Codename: resolute\nSHA256:\n %s 1 main/binary-amd64/Packages.xz\n' "$(sha256sum "$A/dists/resolute-updates/main/binary-amd64/Packages.xz" | cut -d' ' -f1)" > "$A/dists/resolute-updates/Release"
  gpg --homedir "$GH" --batch --yes --clearsign --output "$A/dists/resolute-updates/InRelease" "$A/dists/resolute-updates/Release" >/dev/null 2>&1
  ( shim_fetch ) >"$T/s.out" 2>&1; rc=$?
  assert "succeeds" test $rc -eq 0
  assert "kept version 9" grep -q '^shim-signed=9$' "$STATE/shim-x86_64.built-from"
}

test_shim_mode_is_ubuntu_x86_64_only() {
  src; mkroot
  BOOT_LOADER=shim; DISTRO=debian; TARGET_ARCH=x86_64; set_distro
  ( shim_fetch ) >"$T/s.out" 2>&1; rc=$?
  assert "refused for other systems (exit 2)" test $rc -eq 2
}

test_configure_in_shim_mode_writes_grub_cfg_and_shim_dhcp_settings() {
  src; mkroot
  DISTRO=ubuntu; TARGET_ARCH=x86_64; BOOT_LOADER=shim; set_distro
  mkdir -p "$TFTP" "$HTTP/casper" "$HTTP/iso" "$RUN"
  printf 'MZ-s' > "$TFTP/shimx64.efi"; printf 'MZ-g' > "$TFTP/grubx64.efi"; printf 'MZ-m' > "$TFTP/mmx64.efi"
  echo K > "$HTTP/casper/vmlinuz"; echo I > "$HTTP/casper/initrd"; echo R > "$HTTP/iso/ubuntu.iso"
  printf "KERNEL_REL='casper/vmlinuz'\nINITRD_REL='casper/initrd'\nROOTFS_REL='iso/ubuntu.iso'\nSHA_REL=''\nBASEDIR=''\nUCODE_RELS=''\n" > "$LAYOUT"
  resolve_network() { IFACE=wlan0; MODE=proxy; PHONE_IP=192.168.0.230; NET=192.168.0.0; MASK=255.255.255.0; PREFIX_LEN=24; BASE_URL="http://192.168.0.230:$HTTP_PORT"; IS_HOTSPOT=0; }
  ( configure ) >"$T/c.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    configure said: /' "$T/c.out" | tail -10
  assert "configure succeeds without iPXE or keys" test $rc -eq 0
  assert "grub.cfg exists" test -s "$TFTP/grub/grub.cfg"
  assert "grub loads the kernel over http from the phone" grep -q 'linux (http,192.168.0.230:8000)/casper/vmlinuz' "$TFTP/grub/grub.cfg"
  assert "kernel args carry the image URL" grep -q 'url=http://192.168.0.230:8000/iso/ubuntu.iso' "$TFTP/grub/grub.cfg"
  assert "initrd line" grep -q 'initrd (http,192.168.0.230:8000)/casper/initrd' "$TFTP/grub/grub.cfg"
  assert "dhcp hands UEFI PCs the shim" grep -q 'dhcp-boot=tag:efi64,shimx64.efi' "$DNSMASQ_CONF"
  assert "pxe menu entry uses the shim" grep -q 'X86-64_EFI.*shimx64.efi' "$DNSMASQ_CONF"
  assert "iPXE is not offered" bash -c '! grep -q "ipxe.efi" "$1"' _ "$DNSMASQ_CONF"
  assert "shim, grub and grub.cfg are in the integrity manifest" bash -c 'grep -q " tftp/shimx64.efi$" "$1" && grep -q " tftp/grub/grub.cfg$" "$1" && grep -q " tftp/grubx64.efi$" "$1"' _ "$MANIFEST"
}

test_status_asks_for_shim_files_in_shim_mode() {
  src; mkroot
  DISTRO=ubuntu; TARGET_ARCH=x86_64; BOOT_LOADER=shim; set_distro
  diagnose
  hit=""; for i in "${!F_TAG[@]}"; do [[ ${F_TAG[$i]} == IPXE ]] && hit="${F_LVL[$i]}|${F_FIX[$i]}"; done
  assert "missing shim is a FAIL with the fetch command" test "$hit" = "FAIL|$0 shim-fetch"
}

test_guide_offers_ubuntus_signed_files_first_and_remembers_the_choice() {
  cat > "$T/ip.sh" <<EOT
export NETBOOT_SOURCE_ONLY=1
source "$SCRIPT"
DISTRO=ubuntu; TARGET_ARCH=x86_64; set_distro
mkdir -p "\$STATE"
g_done_ipxe() { return 1; }
shim_fetch() { echo "SHIM-FETCH-RAN"; }
guided_ipxe
echo "LOADER=\$BOOT_LOADER"
cat "\$PROFILE" | grep BOOT_LOADER
EOT
  python3 -I -c "$PTY_PY" "|" bash "$T/ip.sh" > "$T/pty.out" 2>&1
  assert "Enter picks Ubuntu's signed files" grep -q "SHIM-FETCH-RAN" "$T/pty.out"
  assert "mentions Secure Boot" grep -q "Secure Boot" "$T/pty.out"
  assert "never tells you to turn it off" bash -c '! grep -qi "secure boot off\|disable secure boot" "$1"' _ "$T/pty.out"
  assert "route remembered in the profile" grep -q "BOOT_LOADER_PICK='shim'" "$T/pty.out"
}

test_other_distros_never_see_the_shim_offer() {
  cat > "$T/ip2.sh" <<EOT
export NETBOOT_SOURCE_ONLY=1
source "$SCRIPT"
DISTRO=debian; TARGET_ARCH=x86_64; set_distro
g_done_ipxe() { return 1; }
ipxe_cloud() { echo "CLOUD"; }
guided_ipxe
EOT
  python3 -I -c "$PTY_PY" "|" bash "$T/ip2.sh" > "$T/pty.out" 2>&1
  assert "no shim question for Debian" bash -c '! grep -q "signed boot files" "$1"' _ "$T/pty.out"
}

test_shim_flag_beats_a_saved_ipxe_profile() {
  src; mkroot
  printf "DISTRO='ubuntu'\nBOOT_LOADER_PICK='ipxe'\n" > "$PROFILE"
  CLI_SET=" BOOT_LOADER"; BOOT_LOADER=shim
  load_profile
  assert "command line wins" test "$BOOT_LOADER" = shim
}

test_secure_boot_never_needs_touching_on_ubuntu_by_default() {
  src; mkroot
  DISTRO=ubuntu; TARGET_ARCH=x86_64; BOOT_LOADER=auto; BOOT_LOADER_AUTO=1; set_distro
  assert "Ubuntu defaults to the signed route" test "$BOOT_LOADER" = shim
  DISTRO=debian; set_distro
  assert "other distros fall back to iPXE" test "$BOOT_LOADER" = ipxe
  DISTRO=ubuntu; set_distro
  assert "and back again" test "$BOOT_LOADER" = shim
  # an old profile that merely stored the old default must not pin iPXE
  printf "DISTRO='ubuntu'\nBOOT_LOADER='ipxe'\n" > "$PROFILE"; BOOT_LOADER=auto; BOOT_LOADER_AUTO=1
  load_profile; set_distro
  assert "old default is ignored" test "$BOOT_LOADER" = shim
  # a deliberate pick is kept
  printf "DISTRO='ubuntu'\nBOOT_LOADER_PICK='ipxe'\n" > "$PROFILE"; BOOT_LOADER=auto; BOOT_LOADER_AUTO=1
  load_profile; set_distro
  assert "deliberate pick wins" test "$BOOT_LOADER" = ipxe
  save_profile
  assert "auto is not written down" bash -c '! grep -q "BOOT_LOADER=.shim" "$1"' _ "$PROFILE"
}

test_pc_instructions_do_not_ask_for_secure_boot_changes_on_the_signed_route() {
  src; mkroot
  DISTRO=ubuntu; TARGET_ARCH=x86_64; BOOT_LOADER=auto; BOOT_LOADER_AUTO=1; set_distro
  PHONE_IP=192.168.0.5; IFACE=wlan0
  pc_instructions > "$T/pc.out" 2>&1 || true
  assert "says leave it alone" grep -q "Do NOT touch Secure Boot" "$T/pc.out"
}

mk_fake_usb() {
  USB_CFG="$T/cfg/usb_gadget"; USB_UDC_DIR="$T/udc"; USB_KCONFIG="$T/no-config.gz"
  mkdir -p "$USB_CFG/android0" "$USB_UDC_DIR/fake.udc"
  echo fake.udc > "$USB_CFG/android0/UDC"; echo configured > "$USB_UDC_DIR/fake.udc/state"
  head -c 4096 /dev/urandom > "$ISO"
  printf '%s %s %s\n' deadbeef "$(file_size "$ISO")" "$(file_mtime "$ISO")" > "$ISO_VERIFIED"
}

test_usb_drive_mode_binds_the_verified_iso_read_only_and_restores_everything() {
  can_root || skip "needs root or sudo"
  src; mkroot; mk_fake_usb; IS_TERMUX=0
  ( usb_boot_start ) > "$T/usb.out" 2>&1 & u=$!
  for _ in $(seq 1 30); do [[ -s $USB_CFG/netboot-android/UDC ]] && break; sleep 0.5; done
  G="$USB_CFG/netboot-android"
  assert "our gadget points at the ISO" test "$(cat "$G/functions/mass_storage.0/lun.0/file")" = "$ISO"
  assert "read-only" test "$(cat "$G/functions/mass_storage.0/lun.0/ro")" = 1
  assert "bound to the controller" test "$(cat "$G/UDC")" = fake.udc
  assert "the old gadget was let go" test -z "$(tr -d '\n' < "$USB_CFG/android0/UDC")"
  assert "tells the user what to do" grep -q 'USB DRIVE MODE' "$T/usb.out"
  kill -TERM "$u" 2>/dev/null; wait "$u" 2>/dev/null
  assert "old gadget restored" test "$(cat "$USB_CFG/android0/UDC")" = fake.udc
  assert "our gadget is unbound" test -z "$(tr -d '\n' < "$G/UDC" 2>/dev/null)"
  assert "our function link is gone" test ! -e "$G/configs/c.1/mass_storage.0"
}

test_usb_drive_mode_refuses_an_unverified_iso() {
  src; mkroot; mk_fake_usb; IS_TERMUX=0
  rm -f "$ISO_VERIFIED"
  out=$( ( usb_boot_start ) 2>&1 ); rc=$?
  assert "refused with the integrity exit code" test $rc -eq 30
  assert "says what to do" grep -q 'fetch' <<<"$out"
  assert "nothing was created" test ! -e "$USB_CFG/netboot-android"
}

test_usb_drive_mode_waits_for_the_cable_instead_of_failing() {
  can_root || skip "needs root or sudo"
  src; mkroot; mk_fake_usb; IS_TERMUX=0
  rm -rf "$USB_UDC_DIR/fake.udc"; echo > "$USB_CFG/android0/UDC"       # no cable yet: no controller listed
  ( usb_boot_start ) > "$T/usb.out" 2>&1 & u=$!
  sleep 5
  assert "still running, not failed" kill -0 "$u"
  assert "says it is waiting" grep -q 'Waiting for the USB cable' "$T/usb.out"
  assert "everything else is prepared already" test "$(cat "$USB_CFG/netboot-android/functions/mass_storage.0/lun.0/file")" = "$ISO"
  mkdir -p "$USB_UDC_DIR/fake.udc"; echo configured > "$USB_UDC_DIR/fake.udc/state"   # cable plugged in
  for _ in $(seq 1 30); do [[ -s $USB_CFG/netboot-android/UDC ]] && break; sleep 0.5; done
  assert "connected once the cable appeared" test "$(cat "$USB_CFG/netboot-android/UDC")" = fake.udc
  kill -TERM "$u" 2>/dev/null; wait "$u" 2>/dev/null
  exit 0
}

test_usb_selinux_block_offers_permissive_for_the_session_and_restores_it() {
  src; mkroot; mk_fake_usb; IS_TERMUX=0; IS_ANDROID=1
  LOG="$T/se.log"; : > "$LOG"
  mkdir -p "$T/fakebin"
  printf '#!/bin/sh\nif [ "$1" = 0 ]; then : > "%s/permissive"; else rm -f "%s/permissive"; fi\necho "setenforce $1" >> "%s"\n' "$T" "$T" "$LOG" > "$T/fakebin/setenforce"
  chmod +x "$T/fakebin/setenforce"; export PATH="$T/fakebin:$PATH"
  run_root() {   # fake su: getenforce says Enforcing until setenforce 0 is run
    case "$1" in
      getenforce) [[ -f $T/permissive ]] && echo Permissive || echo Enforcing ;;
      *"ln -sf"*) [[ -f $T/permissive ]] || { echo "ln: cannot create symbolic link: Operation not permitted" >&2; return 1; }; bash -c "$1" ;;
      *) bash -c "$1" ;;
    esac
  }
  ask_yn() { return 0; }
  ( usb_boot_start ) > "$T/usb.out" 2>&1 & u=$!
  for _ in $(seq 1 40); do [[ -s $USB_CFG/netboot-android/UDC ]] && break; sleep 0.5; done
  assert "SELinux lowered only after being asked" grep -q '^setenforce 0$' "$LOG"
  assert "connected after the retry" test "$(cat "$USB_CFG/netboot-android/UDC")" = fake.udc
  kill -TERM "$u" 2>/dev/null; wait "$u" 2>/dev/null || true
  assert "SELinux put back at the end" test "$(tail -n1 "$LOG")" = "setenforce 1"
}

test_usb_selinux_block_with_a_no_answer_stays_enforcing_and_explains() {
  src; mkroot; mk_fake_usb; IS_TERMUX=0; IS_ANDROID=1
  LOG="$T/se.log"; : > "$LOG"
  run_root() {
    case "$1" in
      getenforce) echo Enforcing ;;
      "setenforce "*) echo "$1" >> "$LOG" ;;
      *"ln -sf"*) echo "ln: cannot create symbolic link: Operation not permitted" >&2; return 1 ;;
      *) bash -c "$1" ;;
    esac
  }
  ask_yn() { return 1; }
  out=$( ( usb_boot_start ) 2>&1 ); rc=$?
  assert "fails with a clear message" test $rc -ne 0
  assert "never lowered SELinux" bash -c '! grep -q "setenforce 0" "$1"' _ "$LOG"
  assert "mentions the blocker" grep -q 'Operation not permitted' <<<"$out"
}

test_usb_falls_back_to_the_phones_own_gadget_when_ours_is_refused() {
  src; mkroot; mk_fake_usb; IS_TERMUX=0
  mkdir -p "$USB_CFG/android0/configs/b.1"
  run_root() {   # a phone whose kernel refuses links inside our own gadget only
    case "$1" in
      *"ln -sf"*"configs/c.1"*) echo "ln: cannot create symbolic link: Operation not permitted" >&2; return 1 ;;
      *) bash -c "$1" ;;
    esac
  }
  ( usb_boot_start ) > "$T/usb.out" 2>&1 & u=$!
  for _ in $(seq 1 40); do grep -q 'USB DRIVE MODE' "$T/usb.out" 2>/dev/null && break; sleep 0.5; done
  assert "tells what it is doing" grep -q "phone's own USB setup" "$T/usb.out"
  assert "the drive lives in the phone's own gadget" test "$(cat "$USB_CFG/android0/functions/mass_storage.nb0/lun.0/file")" = "$ISO"
  assert "linked into its configuration" test -L "$USB_CFG/android0/configs/b.1/f_nb"
  assert "connected" test "$(cat "$USB_CFG/android0/UDC")" = fake.udc
  kill -TERM "$u" 2>/dev/null; wait "$u" 2>/dev/null || true
  assert "link removed at the end" test ! -e "$USB_CFG/android0/configs/b.1/f_nb"
  assert "phone's own USB handed back" test "$(cat "$USB_CFG/android0/UDC")" = fake.udc
}

test_usb_check_reports_a_phone_without_gadget_support() {
  can_root || skip "needs root or sudo"
  src; mkroot; USB_CFG="$T/none/usb_gadget"; USB_UDC_DIR="$T/none/udc"
  usb_check >"$T/c.out" 2>&1 && { echo "unsupported phone reported as fine"; exit 1; }
  assert "explains" grep -q 'cannot act as a USB drive' "$T/c.out"
}

test_backups_are_off_unless_asked_for() {
  src; mkroot
  mkdir -p "$ROOT/keys"; echo k > "$ROOT/keys/k"
  assert "default is off" test "$AUTO_BACKUP" = 0
  out=$(auto_backup serve 2>&1)
  assert "serve/clean make no backup" test "$(count_backups)" -eq 0
  assert "and say nothing about it" test -z "$out"
}

test_backup_flag_opts_in_for_one_run() {
  src; mkroot
  out=$(NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup-auto 2>&1)
  assert "status says only when asked" grep -q 'ONLY WHEN YOU ASK' <<<"$out"
  out=$(NETBOOT_SOURCE_ONLY=0 "$SCRIPT" --backup backup-auto 2>&1)
  assert "--backup turns it on for the run" grep -q 'AUTOMATIC' <<<"$out"
  out=$(NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup-auto 2>&1)
  assert "but does not stick" grep -q 'ONLY WHEN YOU ASK' <<<"$out"
}

test_a_manual_backup_and_restore_safety_copy_still_work_with_auto_off() {
  src; mkroot
  mkdir -p "$ROOT/keys"; echo k1 > "$ROOT/keys/k"
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" backup >/dev/null 2>&1
  assert "manual backup works" test "$(count_backups)" -eq 1
  f=$(ls "$BACKUP_DIR"/netboot-manual-*.tar.gz | head -n1)
  sleep 1.1; echo k2 > "$ROOT/keys/k"
  NETBOOT_SOURCE_ONLY=0 "$SCRIPT" restore "$f" >/dev/null 2>&1
  assert "restore keeps its safety copy of what it overwrote" test "$(count_backups)" -eq 2
  assert "restored" test "$(cat "$ROOT/keys/k")" = k1
}

# ---- never redo a finished step ----
stub_steps() {   # every real step just records that it ran
  STEPLOG="$T/steps.log"; : > "$STEPLOG"
  for fn in check_soft deps attest_init self_sign pins_refresh fetch extract configure attest_report offsite_wizard run_step; do
    eval "$fn() { echo $fn >> \"\$STEPLOG\"; }"
  done
}

all_done() { for fn in g_done_check g_done_deps g_done_attest g_done_sign g_done_pins g_done_fetch g_done_extract g_done_configure g_done_report g_done_ipxe; do eval "$fn() { return 0; }"; done; }

test_a_fully_finished_guide_runs_no_step_and_asks_nothing() {
  src; mkroot; stub_steps; all_done
  printf "DISTRO='ubuntu'\n" > "$PROFILE"; : > "$STATE/offsite.asked"
  GUIDE_WELCOMED=1 ASSUME_YES=1
  ( guided ) >"$T/g.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    guide said: /' "$T/g.out" | tail -8
  echo "steps run: $(tr '\n' ' ' < "$STEPLOG")"
  assert "guide ends fine" test $rc -eq 0
  assert "no setup step ran" bash -c '! grep -vxE "run_step" "$1" | grep -q .' _ "$STEPLOG"
  assert "says so" grep -q 'already done' "$T/g.out"
  assert "counts them" grep -qE 'Skipped [0-9]+ step' "$T/g.out"
  assert "asked no question" bash -c '! grep -qE "Do this step now|Do it again" "$1"' _ "$T/g.out"
}

test_only_the_unfinished_step_runs() {
  src; mkroot; stub_steps; all_done
  g_done_fetch() { return 1; }
  printf "DISTRO='ubuntu'\n" > "$PROFILE"; : > "$STATE/offsite.asked"
  GUIDE_WELCOMED=1 ASSUME_YES=1
  ( guided ) >"$T/g.out" 2>&1
  ran=$(grep -vxE 'run_step' "$STEPLOG" | tr '\n' ' ')
  assert "only fetch ran" test "$ran" = "fetch "
}

test_redo_offers_finished_steps_again() {
  src; mkroot; stub_steps; all_done
  printf "DISTRO='ubuntu'\n" > "$PROFILE"; : > "$STATE/offsite.asked"
  GUIDE_WELCOMED=1 ASSUME_YES=1 GUIDE_REDO=1
  ( guided ) >"$T/g.out" 2>&1
  assert "it asks again" grep -q 'Do it again anyway' "$T/g.out"
}

test_done_checks_tell_the_truth() {
  src; mkroot
  # deps
  missing_tools() { echo "openssl"; }
  g_done_deps && { echo "deps wrongly done"; exit 1; }
  missing_tools() { echo ""; }; g_done_deps || { echo "deps wrongly not done"; exit 1; }
  # sign
  self_status() { echo changed; }; g_done_sign && { echo "changed script counted as signed"; exit 1; }
  self_status() { echo ok; }; g_done_sign || { echo "signed script not counted"; exit 1; }
  # pins
  pin_hosts_for_target() { echo a.example; echo b.example; }
  active_pins() { [[ $1 == a.example ]] && echo PIN; }
  g_done_pins && { echo "a host without a pin counted as done"; exit 1; }
  active_pins() { echo PIN; }
  g_done_pins || { echo "valid pins not counted"; exit 1; }
  # extract: layout alone is not enough, the files must exist
  printf "KERNEL_REL='k'\nINITRD_REL='i'\nROOTFS_REL='r'\n" > "$LAYOUT"
  g_done_extract && { echo "extract counted without files"; exit 1; }
  mkdir -p "$HTTP"; echo k > "$HTTP/k"; echo i > "$HTTP/i"; echo r > "$HTTP/r"
  g_done_extract || { echo "extract not counted with files"; exit 1; }
  exit 0
}

test_configure_is_redone_only_when_the_network_or_extraction_changed() {
  src; mkroot; BOOT_LOADER=ipxe; BOOT_LOADER_AUTO=0
  mkdir -p "$TFTP"
  echo "set base http://192.168.0.5:8000" > "$TFTP/boot.ipxe"
  : > "$LAYOUT"; sleep 1.1; : > "$MANIFEST"
  echo "iface=wlan0 loader=ipxe" > "$STATE/$DISTRO-$TARGET_ARCH.config"
  resolve_network() { IFACE=wlan0; PHONE_IP=192.168.0.5; }
  g_done_configure || { echo "same network should count as done"; exit 1; }
  resolve_network() { IFACE=wlan0; PHONE_IP=192.168.0.99; }
  g_done_configure && { echo "address change should not count as done"; exit 1; }
  resolve_network() { IFACE=wlan0; PHONE_IP=192.168.0.5; }
  sleep 1.1; touch "$LAYOUT"          # re-extracted after configuring
  g_done_configure && { echo "re-extract should require configuring again"; exit 1; }
  exit 0
}

test_signed_report_is_current_only_if_newer_than_the_configuration() {
  src; mkroot
  mkdir -p "$ATTEST/reports"
  : > "$MANIFEST"; sleep 1.1; : > "$ATTEST/reports/r1.asc"
  g_done_report || { echo "newer report should count"; exit 1; }
  sleep 1.1; : > "$MANIFEST"
  g_done_report && { echo "older report should not count"; exit 1; }
  exit 0
}

test_all_command_skips_finished_steps() {
  src; mkroot; stub_steps; all_done
  g_done_extract() { return 1; }
  serve() { echo serve >> "$STEPLOG"; }
  ( run_all ) >"$T/a.out" 2>&1
  ran=$(tr '\n' ' ' < "$STEPLOG")
  assert "only the unfinished steps plus fetch's own check and serve" test "$ran" = "fetch extract serve "
}

test_cloud_backup_question_is_asked_only_once() {
  src; mkroot; stub_steps; all_done
  printf "DISTRO='ubuntu'\n" > "$PROFILE"
  GUIDE_WELCOMED=1 ASSUME_YES=1
  ( guided ) >/dev/null 2>&1
  assert "asked the first time" grep -q offsite_wizard "$STEPLOG"
  assert "remembered" test -f "$STATE/offsite.asked"
  : > "$STEPLOG"
  ( guided ) >/dev/null 2>&1
  assert "not asked again" bash -c '! grep -q offsite_wizard "$1"' _ "$STEPLOG"
}

# ---------------------------------------------------------------- run
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do run_test "$t"; done

PASS=$(grep -c P "$RESULTS" || true); FAIL=$(grep -c F "$RESULTS" || true); SKIP=$(grep -c S "$RESULTS" || true)
echo
echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"
(( FAIL == 0 ))
