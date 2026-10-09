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
  ) > "$tmp/out" 2>&1
  rc=$?
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
  BIG_BYTES=1000; VERIFIED_BOOT=0; FAMILY=squash
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

# ---------------------------------------------------------------- run
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do run_test "$t"; done

PASS=$(grep -c P "$RESULTS" || true); FAIL=$(grep -c F "$RESULTS" || true); SKIP=$(grep -c S "$RESULTS" || true)
echo
echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"
(( FAIL == 0 ))
