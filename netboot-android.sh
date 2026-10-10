#!/usr/bin/env bash
# =============================================================================
#  netboot-android.sh
#  Verified PXE live boot of Linux ISOs, served from a rooted Android phone
#  (Termux) or from any Linux machine.
# =============================================================================
#
#  WHAT IT DOES
#    The phone (or Linux host) becomes a PXE boot server on your network. A PC
#    set to network boot receives iPXE over TFTP, and iPXE pulls a live Linux
#    kernel, initrd, and root image over HTTP from the phone.
#
#  CHAIN OF TRUST (every link is checked by this script)
#    1. Vendor signing keys. Fingerprints are embedded below. Each key is
#       fetched from at least two independent sources, and the signing key or
#       subkey must be present on at least two of them.
#    2. Vendor signatures. An ISO is accepted only after a signature from the
#       embedded vendor key verifies (signed checksum list or ISO signature).
#    3. TLS pinning. Metadata hosts are pinned by public key (SPKI). Pins are
#       refreshed from Certificate Transparency logs, and the key a server
#       presents must appear in CT. A key that is not in CT means interception.
#    4. Local attestation identity. A GPG key (signs reports and this script's
#       hash) and an X.509 code-signing CA (signs boot files) are generated on
#       this device.
#    5. iPXE is built from source at a pinned commit with the local CA embedded.
#       Its built-in script refuses to run boot.ipxe, the kernel, or any initrd
#       unless the signature verifies against that CA.
#    6. Integrity gate. Every served file is re-hashed against the manifest
#       before the servers start.
#    7. Signed attestation reports tie all of the above together and can be
#       re-verified at any time.
#
#  LIMITS
#    - The large root image that the initrd downloads after boot (the Ubuntu
#      ISO, the Debian or Parrot squashfs, the Fedora squashfs) is not
#      signature-checked on the client. Arch and SystemRescue verify theirs
#      with checksum=y.
#    - Self-verification is tamper evidence. Someone who can edit this script
#      can also edit the check. Compare the `fingerprints` output against a copy
#      kept on another device for real assurance.
#    - Embedded pins and vendor data were collected on 2026-10-08. Run
#      `pins refresh` on your own device before first use.
# =============================================================================
set -euo pipefail
umask 022

SCRIPT_VERSION="2026.10.09-easy"
RELEASE_TIME=""   # upload time (UTC epoch) set by release-stamp; must equal the upstream commit time

# =============================================================================
# Platform detection
# =============================================================================
IS_TERMUX=0; [[ ${PREFIX:-} == *com.termux* ]] && IS_TERMUX=1
IS_PROOT=0
if [[ -n ${PROOT_TMP_DIR:-}${PROOT_L2S_DIR:-} ]] || grep -q '^TracerPid:[[:space:]]*[1-9]' /proc/self/status 2>/dev/null; then IS_PROOT=1; fi
IS_ANDROID=0; [[ -e /system/build.prop || -n ${ANDROID_ROOT:-} ]] && IS_ANDROID=1
HOST_ARCH=$(uname -m)
SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")

find_bin() {
  local name=$1 c
  for c in "$(command -v "$name" 2>/dev/null || true)" \
           "${PREFIX:-/nonexistent}/bin/$name" "/usr/sbin/$name" "/sbin/$name" "/usr/bin/$name"; do
    if [[ -n $c && -x $c ]]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

DNSMASQ="${DNSMASQ:-$(find_bin dnsmasq || true)}"
PYTHON="${PYTHON:-$(find_bin python3 || find_bin python || true)}"

# Is an x86_64 cross-compiler installed on this (arm64) system? Kept as a function so tests can stub it.
have_cross_gcc() { command -v x86_64-linux-gnu-gcc >/dev/null 2>&1; }

# Programs the whole flow needs. Prints the missing ones, space separated.
missing_tools() {
  local t m=""
  for t in curl gpg openssl bsdtar; do command -v "$t" >/dev/null 2>&1 || m+="$t "; done
  [[ -n ${DNSMASQ:-} && -x ${DNSMASQ:-} ]] || m+="dnsmasq "
  [[ -n ${PYTHON:-} ]] || m+="python3 "
  printf '%s' "${m% }"
}

# =============================================================================
# Paths
# =============================================================================
ROOT="${NETBOOT_HOME:-$HOME/netboot}"
TFTP="$ROOT/tftp"
HTTP="$ROOT/http"
DL="$ROOT/downloads"
PIN_DIR="$ROOT/pins"
KEYS_DIR="$ROOT/keys"
SRC_DIR="$ROOT/src"
STATE="$ROOT/state"
ATTEST="$ROOT/attest"
ATTEST_GNUPG="$ATTEST/gnupg"
RUN="$ROOT/run"
LIB="$ROOT/lib"
DNSMASQ_CONF="$ROOT/dnsmasq.conf"
HTTP_LOG="$ROOT/http.log"
PIN_AUDIT="$STATE/pin-audit.log"

# =============================================================================
# Constants
# =============================================================================
PIN_SNAPSHOT_DATE="2026-10-08"
DEFAULT_IPXE_COMMIT="744cdb451ef28bc894df72b6b40fdf1fda04acfc"   # 2026-09-22, Michael Brown
IPXE_REPO="https://github.com/ipxe/ipxe.git"
CT_API="https://api.certspotter.com/v1/issuances"
CT_HOST="api.certspotter.com"
KEYSERVER_UBUNTU="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x"
KEYSERVER_OPENPGP="https://keys.openpgp.org/vks/v1/by-fingerprint/"
INFRA_HOSTS=(api.certspotter.com keyserver.ubuntu.com keys.openpgp.org github.com)
DEFAULT_UPSTREAM_REPO="https://github.com/SecTrollz/netboot-android.git"
UPSTREAM_PATH="netboot-android.sh"

# =============================================================================
# Settings (environment overrides)
# =============================================================================
declare -gA PRE_ENV=( [BOOT_LOADER]="${BOOT_LOADER:-}" [DISTRO]="${DISTRO:-}" [TARGET_ARCH]="${TARGET_ARCH:-}" [DHCP_MODE]="${DHCP_MODE:-}" [IFACE]="${IFACE:-}" [HTTP_PORT]="${HTTP_PORT:-}" )
CLI_SET=""
IFACE="${IFACE:-}"
HTTP_PORT="${HTTP_PORT:-8000}"
DISTRO="${DISTRO:-ubuntu}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"
DHCP_MODE="${DHCP_MODE:-auto}"            # auto | proxy | direct
DIRECT_CIDR="${DIRECT_CIDR:-10.42.0.1/24}"
VERIFIED_BOOT="${VERIFIED_BOOT:-1}"
DEEP_VERIFY="${DEEP_VERIFY:-auto}"
INCLUDE_UCODE="${INCLUDE_UCODE:-1}"
IPXE_COMMIT="${IPXE_COMMIT:-$DEFAULT_IPXE_COMMIT}"
IPXE_CROSS="${IPXE_CROSS:-}"
IPXE_CC="${IPXE_CC:-}"
FALLBACK_SERVER="${FALLBACK_SERVER:-}"
TRUST_CA="${TRUST_CA:-}"
ALLOW_UNPINNED="${ALLOW_UNPINNED:-0}"
BOOT_LOADER="${BOOT_LOADER:-ipxe}"            # ipxe (your own signed chain) | shim (Ubuntu's Secure Boot chain)
UBUNTU_ARCHIVE="${UBUNTU_ARCHIVE:-https://archive.ubuntu.com/ubuntu}"
# Ubuntu Archive Automatic Signing Keys (2018, 2012): the only keys accepted for archive metadata
UBUNTU_ARCHIVE_FPRS="${UBUNTU_ARCHIVE_FPRS:-F6ECB3762474EDA9D21B7022871920D1991BC93C 790BC7277767219C42C86F933B4FE6ACC0B21F32}"
ISO_FILE="${ISO_FILE:-}"                       # a file you already have (--iso PATH); it is verified before use
EXTRA_ISO_DIRS="${EXTRA_ISO_DIRS:-}"          # more folders to search for an earlier download, colon separated
KEY_MIN_SOURCES="${KEY_MIN_SOURCES:-2}"       # independent places that must agree on the vendor key
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"
ACCEPT_SCRIPT_CHANGE="${ACCEPT_SCRIPT_CHANGE:-0}"
CT_BOOTSTRAP="${CT_BOOTSTRAP:-0}"
UPSTREAM_REPO="${UPSTREAM_REPO:-$DEFAULT_UPSTREAM_REPO}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
XBOX_NAME="${XBOX_NAME:-debian}"          # proot-distro container used to cross-compile on a phone
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
GITHUB_RAW_BASE="${GITHUB_RAW_BASE:-https://raw.githubusercontent.com}"
# SHA-256 of .github/workflows/build-ipxe.yml as reviewed. A cloud build is accepted only if it
# ran exactly this file. Change the workflow => update this value (tests enforce it).
WORKFLOW_SHA256="8e3f75dcea2216b7d189e35255588bf6d1245d3d044b49384b352d9430df155b"
IPXE_CLOUD_OK="${IPXE_CLOUD_OK:-0}"            # 1 lets --yes run the one-time cloud approval unattended
IPXE_ALLOW_UNATTESTED="${IPXE_ALLOW_UNATTESTED:-0}"
IPXE_CURL_OPTS="${IPXE_CURL_OPTS---proto =https --tlsv1.2}"   # tests may set this empty to talk to a local server
EXPECT_CODE="${EXPECT_CODE:-}"
# Settings saved by the guided offsite-backup setup. Read as plain NAME='value' lines
# (never executed); a variable already set in the environment wins.
load_saved_settings() {
  local f="$STATE/backup.conf" line name val
  [[ -r $f ]] || return 0
  while IFS= read -r line; do
    name=${line%%=*}; val=${line#*=}
    case "$name" in
      AUTO_BACKUP|BACKUP_DIR|BACKUP_KEEP|BACKUP_DL|BACKUP_GPG_PASSFILE|TERABOX_COOKIE_FILE|TERABOX_DIR|GDRIVE_REMOTE) ;;
      *) continue ;;
    esac
    [[ $val == \'*\' ]] || continue
    val=${val:1:${#val}-2}
    [[ $val != *\'* ]] || continue
    [[ -n ${!name:-} ]] || printf -v "$name" '%s' "$val"
  done < "$f"
}
load_saved_settings

AUTO_BACKUP="${AUTO_BACKUP:-0}"           # 0 (default): never back up unless asked. 1: back up before serve and clean (only if something changed)
BACKUP_DIR="${BACKUP_DIR:-$HOME/netboot-backups}"
BACKUP_KEEP="${BACKUP_KEEP:-5}"           # newest archives kept after each backup
BACKUP_DL="${BACKUP_DL:-0}"               # 1: include downloads/ (ISOs, large)
BACKUP_UPLOAD_CMD="${BACKUP_UPLOAD_CMD:-}" # offsite hook, run as: CMD FILE.gpg (for example a Terabox uploader)
BACKUP_GPG_PASSFILE="${BACKUP_GPG_PASSFILE:-}" # passphrase file; required to encrypt before upload
TERABOX_COOKIE_FILE="${TERABOX_COOKIE_FILE:-}" # file holding the Terabox ndus cookie (or set TERABOX_COOKIE)
TERABOX_DIR="${TERABOX_DIR:-/netboot-backups}" # remote folder on Terabox
TBC_REPO="${TBC_REPO:-https://github.com/fcr--/tbc.git}"   # unofficial Terabox CLI (MIT, Go)
TBC_COMMIT="${TBC_COMMIT:-4f1fb75d0defd5edfda9ae819873503af565055c}"
TBC_BIN="${TBC_BIN:-}"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-}"        # rclone Drive remote and folder for Google One storage, e.g. gdrive:netboot-backups

# User overrides, captured before presets so they always win
U_ISO_URL="${ISO_URL:-}"
U_SUMS_URL="${SUMS_URL:-}"
U_SUMS_SIG_URL="${SUMS_SIG_URL:-}"
U_ISO_SIG_URL="${ISO_SIG_URL:-}"
U_KEY_FPR="${KEY_FPR:-}"
U_BOOT_ARGS="${BOOT_ARGS:-}"
U_MIN_FREE_MB="${MIN_FREE_MB:-}"

# Runtime state
SERVE_HTTP_PID=""
TAIL_PID=""
DNS_LOG=""
DIRECT_ADDED=0
JID_DIRECT=""
JID_POWER=""
POWER_TWEAKED=0
COMMAND=""
DRY_RUN=0
ASSUME_YES=0
GUIDE_REDO=0
GUIDE_SKIPPED=0
POSITIONAL=()
SIG_SIGNER=""
GIT_PIN_OPTS=()

# =============================================================================
# Output
# =============================================================================
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'; C_BLUE=$'\033[1;34m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""; C_DIM=""; C_BLUE=""
fi

info() { printf '%s[*]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; log_event WARN "$*"; }
err()  { printf '%s[-]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log_event ERROR "$*"; }
# Exit-code classes. Plain `die "msg"` still works (code 1).
E_USAGE=2; E_ENV=10; E_NET=20; E_INTEGRITY=30; E_DISK=40; E_BUSY=50
LOG_FILE="$STATE/netboot.log"
BIG_BYTES=536870912   # files at or above this are "big" (rootfs, ISO)

log_event() {   # LEVEL message...  (never fails, never creates the state dir)
  [[ -d $STATE && ${LOG_QUIET:-0} != 1 ]] || return 0
  local lvl=$1; shift
  printf '%s %-5s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$lvl" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

log_rotate() {  # keep 3 files of up to 1 MB
  [[ -f $LOG_FILE ]] || return 0
  local sz; sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  (( sz > 1048576 )) || return 0
  mv -f "$LOG_FILE.2" "$LOG_FILE.3" 2>/dev/null || true
  mv -f "$LOG_FILE.1" "$LOG_FILE.2" 2>/dev/null || true
  mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
}

next_step() { printf '%s    Next step: %s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }

die() {
  local code=1
  if [[ ${1:-} =~ ^[0-9]+$ ]]; then code=$1; shift; fi
  err "$*"
  log_event ERROR "exit code=$code"
  case $code in
    "$E_ENV")       next_step "run '$0 doctor' to see what this device is missing." ;;
    "$E_NET")       next_step "check Wi-Fi/internet and run the same command again (downloads resume)." ;;
    "$E_INTEGRITY") next_step "do NOT serve. Run '$0 heal' to re-check and rebuild what is bad." ;;
    "$E_DISK")      next_step "free space (see '$0 status') or point NETBOOT_HOME at a larger internal drive." ;;
    "$E_BUSY")      next_step "wait for the other run to finish, or run '$0 status'." ;;
  esac
  exit "$code"
}

on_err() {   # ERR trap: only fires where set -e would exit, so it adds the "where"
  local rc=$1 line=$2 cmd=$3
  log_event ERROR "unexpected rc=$rc fn=${FUNCNAME[1]:-main} line=$line cmd=$cmd"
  err "Unexpected failure (exit $rc) in ${FUNCNAME[1]:-main}, line $line: $cmd"
  err "Details: $LOG_FILE   |   Try: $0 doctor"
}
set -E
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

# ---- lock: one mutating command at a time; stale locks (dead owner) clear themselves
LOCK_DIR="$STATE/lock.d"
proc_start() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
lock_owner_alive() {
  local pid st
  read -r pid st < "$LOCK_DIR/owner" 2>/dev/null || return 1
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && [[ $(proc_start "$pid") == "$st" ]]
}
# Ownership is the whole process tree ($$ is the same in every subshell). Only the shell
# that took the lock (LOCK_AT) removes it, so a subshell finishing never frees its parent's lock.
LOCK_TREE=""
LOCK_AT=""
acquire_lock() {
  [[ $LOCK_TREE == "$$" ]] && return 0
  mkdir -p "$STATE"
  local tries=0 age me=$BASHPID
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -f $LOCK_DIR/owner ]]; then
      if ! lock_owner_alive; then warn "Clearing a stale lock left by a run that died."; rm -rf "$LOCK_DIR"; continue; fi
    else
      age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || date +%s) ))
      if (( age > 10 )); then rm -rf "$LOCK_DIR"; continue; fi
    fi
    if (( ++tries > 3 )); then
      die "$E_BUSY" "Another netboot-android command is running (pid $(cut -d' ' -f1 "$LOCK_DIR/owner" 2>/dev/null || echo '?'))."
    fi
    sleep 1
  done
  printf '%s %s\n' "$$" "$(proc_start "$$")" > "$LOCK_DIR/owner"
  LOCK_TREE=$$; LOCK_AT=$me
  trap release_lock EXIT
}
release_lock() {
  if [[ $LOCK_TREE == "$$" && $LOCK_AT == "$BASHPID" ]]; then rm -rf "$LOCK_DIR"; LOCK_TREE=""; LOCK_AT=""; fi
}
with_lock() {
  local mine=1 rc=0
  [[ $LOCK_TREE == "$$" ]] && mine=0
  acquire_lock
  "$@" || rc=$?
  (( mine )) && release_lock
  return "$rc"
}

# ---- refuse to operate on dangerous locations (we rm -rf and chown -R under ROOT)
guard_root() {
  local r=${ROOT%/}
  [[ $r == /* && ${#r} -ge 6 ]] || die "$E_USAGE" "Refusing NETBOOT_HOME='$ROOT' (must be an absolute path, not near /)."
  case "$r" in
    "$HOME"|/home|/root|/usr|/etc|/bin|/sbin|/var|/data|/system|/sdcard|/storage|/storage/emulated/0)
      die "$E_USAGE" "Refusing NETBOOT_HOME='$ROOT': that is a system or home folder. Use a dedicated folder such as $HOME/netboot." ;;
  esac
  if [[ -e $r && ! -O $r && $(id -u) -ne 0 ]]; then
    die "$E_ENV" "$ROOT is owned by another user. Fix with: sudo chown -R $(id -u) '$ROOT'"
  fi
}

# ---- atomic writes: readers see the old file or the new one, never half of it
sync_file() { sync "$1" 2>/dev/null || true; }
atomic_write() {   # atomic_write FILE   (content on stdin)
  local f=$1 tmp
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if cat > "$tmp"; then
    chmod 644 "$tmp"; sync_file "$tmp"; mv -f "$tmp" "$f"
  else
    rm -f "$tmp"; return 1
  fi
}
atomic_dir_swap() {   # atomic_dir_swap NEW TARGET: TARGET is replaced by NEW; old copy removed last
  local new=$1 target=$2 old="$2.old.$$"
  if [[ -e $target ]]; then
    mv -T "$target" "$old" && mv -T "$new" "$target" || { [[ -e $target ]] || mv -T "$old" "$target"; return 1; }
    rm -rf "$old"
  else
    mv -T "$new" "$target"
  fi
}

# ---- undo journal: every change outside ROOT is recorded first, so a crash can be undone
JOURNAL="$STATE/undo.d"
journal_push() {   # journal_push "root command that undoes the change" -> prints entry id
  mkdir -p "$JOURNAL"
  local id; id="$(date +%s%N)-$$-$RANDOM"
  printf '%s\n' "$1" > "$JOURNAL/$id"
  printf '%s' "$id"
}
journal_drop() { rm -f "$JOURNAL/$1" 2>/dev/null || true; }
journal_count() { local f n=0; for f in "$JOURNAL"/*; do [[ -e $f ]] && n=$((n+1)); done; echo "$n"; }
journal_replay() {   # newest first; entries that succeed are removed
  local f cmd n=0
  [[ -d $JOURNAL ]] || return 0
  while IFS= read -r f; do
    cmd=$(cat "$f" 2>/dev/null) || continue
    if run_root "$cmd" >/dev/null 2>&1; then rm -f "$f"; n=$((n+1)); else warn "Could not undo: $cmd"; fi
  done <<<"$(ls -1r "$JOURNAL"/* 2>/dev/null || true)"
  (( n == 0 )) || { ok "Undid $n leftover system change(s) from an earlier run"; log_event INFO "journal replayed $n"; }
  return 0
}


banner() {
  printf '%s  netboot-android %s  -  verified PXE live boot%s\n\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
}

box() {
  local width=64 line dashes
  printf -v dashes '%*s' "$width" ''
  dashes=${dashes// /-}
  printf '+%s+\n' "$dashes"
  for line in "$@"; do printf '| %-62.62s |\n' "$line"; done
  printf '+%s+\n' "$dashes"
}

# =============================================================================
# Small helpers
# =============================================================================
need()       { command -v "$1" >/dev/null 2>&1 || die "$E_ENV" "Missing '$1'. Run: $0 deps"; }
today()      { date -u +%F; }
now_iso()    { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
sha256_of()  {
  if [[ -n ${PYTHON:-} && -f ${LIB:-/nonexistent}/hashfile.py ]] && (( $(file_size "$1") >= 67108864 )); then
    "$PYTHON" "$LIB/hashfile.py" "$1" sha256 | awk '{print $2}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
sha512_of()  { sha512sum "$1" | awk '{print $1}'; }
file_size()  { stat -c %s "$1" 2>/dev/null || wc -c <"$1" | tr -d ' '; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
# Free space in MB for a path. Android's built-in df has no -m, so use KB and fall back to stat -f.
free_mb() {
  local p=$1 kb a b
  while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
  kb=$(df -Pk "$p" 2>/dev/null | awk 'NR==2{print $4}')
  [[ $kb =~ ^[0-9]+$ ]] || kb=$(df -k "$p" 2>/dev/null | awk 'END{print $4}')
  if ! [[ $kb =~ ^[0-9]+$ ]]; then
    read -r a b <<<"$(stat -f -c '%a %S' "$p" 2>/dev/null || true)"
    [[ ${a:-} =~ ^[0-9]+$ && ${b:-} =~ ^[0-9]+$ ]] && kb=$(( a * b / 1024 )) || kb=0
  fi
  echo $(( kb / 1024 ))
}
url_host()   { local u=${1#*://}; u=${u%%/*}; printf '%s' "${u%%:*}"; }
norm_fpr()   { printf '%s' "$1" | tr -d ' ' | tr 'a-f' 'A-F'; }
nproc_n()    { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; }
with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

# Runs a command string as root: su on Android, sudo on Linux, direct if root
run_root() {
  local cmd=$1
  if [[ $(id -u) -eq 0 ]]; then
    bash -c "$cmd"
  elif (( IS_ANDROID )); then
    su -c "$cmd"
  elif command -v sudo >/dev/null 2>&1; then
    sudo bash -c "$cmd"
  else
    die "$E_ENV" "Root is required for: $cmd"
  fi
}

# ip, falling back to root when SELinux blocks netlink for apps
ip_q() {
  ip "$@" 2>/dev/null && return 0
  run_root "ip $*" 2>/dev/null || true
}

int_to_ip() {
  local n=$1
  printf '%d.%d.%d.%d' $(( (n>>24)&255 )) $(( (n>>16)&255 )) $(( (n>>8)&255 )) $(( n&255 ))
}

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (a<<24) | (b<<16) | (c<<8) | d ))
}

prefix_to_mask_int() {
  local p=$1
  if (( p == 0 )); then echo 0; else echo $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); fi
}

# =============================================================================
# Embedded trust data
# =============================================================================
# Vendor signing key fingerprints (primary keys). Each was confirmed on
# 2026-10-08 by verifying a real vendor signature and by matching copies on
# keyserver.ubuntu.com and keys.openpgp.org.
vendor_fpr() {
  case $1 in
    ubuntu|ubuntu24) echo 843938DF228D22F7B3742BC0D94AA3F0EFE21092 ;;   # Ubuntu CD Image Automatic Signing Key (2012)
    debian)          echo DF9B9C49EAA9298432589D76DA87E80D6294BE9B ;;   # Debian CD signing key
    fedora)          echo 36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6 ;;   # Fedora (44)
    arch)            echo 3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C ;;   # Pierre Schmitz (Arch release engineering)
    systemrescue)    echo 0FF11AF081E98345594812037091115F8320B897 ;;   # signs with subkey 62989046EB5C7E985ECDF5DD3B0FEA9BE13CA3C9
    parrot)          echo B711822346552E4D92DA02DF7A8286AF0E81EE4A ;;   # Parrot Project (2024-2026)
    *) echo "" ;;
  esac
}

# TLS public-key pins (base64 SHA-256 of SPKI) from Certificate Transparency
# logs via Cert Spotter, 2026-10-08. Format: host|pin|valid-until.
# Leaf keys rotate, so expired entries are ignored automatically. Refresh
# with: ./netboot-android.sh pins refresh
pin_snapshot() {
  cat <<'PINS'
releases.ubuntu.com|YLQUSc2QLZp3YQFLcDl36sdYjZ9jhvE6OE3zRkrr3sw=|2026-11-24
cdimage.ubuntu.com|DtUUV3l5AsH815Ht0yUZ5ODCJuUzlxIEsRhPQq/pqCc=|2026-11-08
cdimage.debian.org|DI4tK0lQa8x393Bd7mn+ojCTVV6IomhMeYuM4YQrMm8=|2026-12-05
cdimage.debian.org|co1lCsTjz5s2WA96A/CTyr+bJ31Cq2YYYo+dtFLzNy4=|2026-11-13
download.fedoraproject.org|veHzOxBua8XiDU/Qq4qusnUYsntqrogXXFztkagcjSk=|2027-04-15
download.fedoraproject.org|dHP7QgL4HM4lXU69xqk6hLgjTQO8BPGpoMVJXdoqIqY=|2026-10-26
fedoraproject.org|veHzOxBua8XiDU/Qq4qusnUYsntqrogXXFztkagcjSk=|2027-04-15
fedoraproject.org|dHP7QgL4HM4lXU69xqk6hLgjTQO8BPGpoMVJXdoqIqY=|2026-10-26
geo.mirror.pkgbuild.com|b1LlXN3/roYiQ/TL1XPlNuyZgusNBepFsf+ncNZNgoE=|2026-12-19
geo.mirror.pkgbuild.com|3F5TKzFDHABjfAu2MLtvI/WS/aQR0f5jWkffj8fvaO8=|2026-12-06
geo.mirror.pkgbuild.com|12GUo1dh92vOFHEWHjVF1wJ8WxqUnt+jDOyBFG/n5zo=|2026-11-17
geo.mirror.pkgbuild.com|mWS8GzYw2Okm9NDd4fREGPD32DvgCY7x8H11BnBgCLc=|2026-11-16
geo.mirror.pkgbuild.com|T2vBp6mNQUYuJBbYF1opiyagLmTmV+kHDWC4WjGt5Bg=|2026-11-16
geo.mirror.pkgbuild.com|qqKZtuVMrIiDmnvQrxOt8eeokJimM0vc8hCPoXvYMtw=|2026-11-16
geo.mirror.pkgbuild.com|IwDO3+VXdCKHyAslz6AToKLa2kV/l+QVzN6bL2uEuiw=|2026-11-15
geo.mirror.pkgbuild.com|H15YnFFMKs5cJitZvcgz65EoAtP8nRHQZEMs8U46oWk=|2026-11-08
geo.mirror.pkgbuild.com|WtWsljT8Aa/QNKTeOCs8/TuWSyBXTiFPx7O3CJuBcQA=|2026-10-19
www.system-rescue.org|EhQCoPas5wgX8FXsoGsDm2v9tNadR69jVlR5KdDSgYw=|2026-12-08
www.system-rescue.org|LRqF+0dszMvmE0UR6BPPCIjILY+D5o9t2VlzdQS87/U=|2026-11-28
www.system-rescue.org|R9/lwT19znY1SYClTGc6QxGhaAuBzX5pIggALiBwt8E=|2026-11-15
deb.parrot.sh|2nTjNpZGkfdLb6CzR+PbyGP+5U9tCXcv/HOyOgcazyY=|2027-01-06
deb.parrot.sh|NAQ36hXTqv4wTWgCM6EtD+4ciLBhpoy3nCz9e4tpkys=|2026-12-31
deb.parrot.sh|VSTt0Y0F4Yr2PhE7XBz4jg1Ek4J3AyWIAW2M3N7E3Yg=|2026-12-26
deb.parrot.sh|C07FpB/7WWAD6nJs0MIkuSj7ZR6sgrLJwRqIGehsvFM=|2026-12-22
deb.parrot.sh|gq8rXgfn5fanWpBy5g1ihttZFkmUC5tsn3wpwKKiCrs=|2026-12-15
deb.parrot.sh|VwHad8+rPElZZDpH0mQJvko5MdQKX3kj3/wUDhvBQm8=|2026-12-07
deb.parrot.sh|k800pBiHhWxdEsTg348t/KS3e20kcPj5vG8OWwEvyN0=|2026-11-22
deb.parrot.sh|OgLHPiOcKCorp00hLaF9km7U6J3+16vpAbyHD2y6V6A=|2026-11-07
deb.parrot.sh|c73S9UeuHedl4yl+rdYHV7Jomx8Yh4wA4yY4OysDoBA=|2026-11-02
deb.parrot.sh|WAFZ4HUg+qAn//9P2Ve5wA0pClX4ZWdHLDYR/0rfQoI=|2026-11-02
deb.parrot.sh|hp7hlcOuvkjlHJ6Y8vh6x1hNMDHOhBml193G9QUm+fI=|2026-10-23
deb.parrot.sh|sRgmR8lKcuRE+bkQ3ciOC0x8pT0VRlEu6owT9ub/TGM=|2026-10-14
github.com|meCETS3rylPtpkuzw2XYUx4hWacPdhIAnnLKkse1Qy0=|2027-01-05
github.com|pfFOAV7A9aGG1JPoaj7ojL5PxeBjzFQyeqXo/yzYgVk=|2026-12-30
github.com|lNuax9RNol8Xx1GETur9frjXt+himsZHCLKOginvFyw=|2026-12-29
github.com|/wiL5vgOLgwED41WS0DNF8QiTBVR/P41Kd163tmFxK0=|2026-11-29
github.com|H9uod6WRojkMImDBHOwaYXN5vIq5IflYps+LWNEcasw=|2026-11-28
github.com|S2LUIbq4yUg5w+MYbj5LZOWAZAzaeNGJ9rTTc4GjvBQ=|2026-11-27
github.com|CK8m/7jgxetIjGRQHDEZcSPRwrP0bo9sTv/9rjSIMEY=|2026-11-13
github.com|n/xOtrq7ePTfDAqo2Z2J9dGMYNI5cCT3WjxKmTqi+vo=|2026-11-07
github.com|XAC60embheF1DJl42bJrHCTBRN0pAVx4REVcw/nwvWI=|2026-11-01
github.com|p4MbBTfU3MTzqPxM2Cjv0q3WON8L6FqSzam65NVEkcM=|2026-10-31
api.certspotter.com|Pv8AWvn3imPfPKOpERpxmBG0oxLWh9TDYq6s9jBuJgk=|2027-03-26
api.certspotter.com|hIR+D5jX6YpL8Ay6J53koQoZvECrspduxe4rirSZG+A=|2026-12-11
keyserver.ubuntu.com|I3Stb+KYVv/KB6EHtwOkuXBy5/h52/tcjwTd7hQkL4Q=|2026-12-13
keys.openpgp.org|YcNMBEsmXJLmI+QTvt96sXJYKRyKly7E1CpdHrWd4gQ=|2026-12-06
downloads.sourceforge.net|plIiByEC6/GfELBaKaoQbX1RJT+Qv/p4z4/XCwSdmt0=|2026-12-28
downloads.sourceforge.net|xukqmiFhsRYQXHSKhpiYb/g7DWLABvgG5QytZYJxEmg=|2026-12-07
downloads.sourceforge.net|76RvucAALTT2CpRI2h5/BXJr84b/45iBZL0XmmXeV48=|2026-12-07
downloads.sourceforge.net|LaiUy+35/oWlajGxd9YGkpK3gRJZ5v1lXyChIAnjpxY=|2026-11-11
downloads.sourceforge.net|qthElIbSyCMAUNBxF2FTITrtVSX+z+Ejfw/uQIYAdQ4=|2026-11-10
downloads.sourceforge.net|qWJ55RIO3a4OuKfAsUyM6kOVf2Sh/0MYXz4i687pNgw=|2026-11-10
downloads.sourceforge.net|Cytv3Mgnthuc1CSoUTJoaamdJ+7wXRyWKXE9ycyz4ek=|2026-11-10
downloads.sourceforge.net|M/b3f2/pAZx0+ovysltIifKhyJ1jZCNALm+OYRmsJ/0=|2026-11-10
downloads.sourceforge.net|hnF4acnsOv/FVoZpqcBD0tUpwlYzAxvlvdcugMULjfY=|2026-11-10
PINS
}

# =============================================================================
# Distro and architecture presets
# =============================================================================
# File layouts and boot parameters were read from the vendors' own ISOs and
# GRUB configs on 2026-10-08. If a vendor changes its layout, extract falls
# back to discovering the files.
only_x86() {
  [[ $TARGET_ARCH == x86_64 ]] || die "$DISTRO: the vendor publishes no $TARGET_ARCH live image. Use --arch x86_64."
}

set_distro() {
  case "$TARGET_ARCH" in
    x86_64|amd64)  TARGET_ARCH=x86_64; DEB_ARCH=amd64 ;;
    arm64|aarch64) TARGET_ARCH=arm64;  DEB_ARCH=arm64 ;;
    *) die "Unknown TARGET_ARCH '$TARGET_ARCH'. Use: x86_64, arm64" ;;
  esac

  P_FAMILY=""; P_ISO_URL=""; P_SUMS_URL=""; P_SUMS_SIG_URL=""; P_SUMS_CLEARSIGNED=0
  P_SUMS_ALGO=sha256; P_ISO_SIG_URL=""; P_KEY_EXTRA_URL=""
  P_KERNEL=""; P_INITRD=""; P_ROOTFS=""; P_EXTRA_ARGS=""
  P_MIN_MB=4096; P_RAM_GB=4; P_ISO_MB=0; P_LABEL=""

  local base
  case "$DISTRO" in
    ubuntu)
      P_FAMILY=casper; P_KERNEL=casper/vmlinuz; P_INITRD=casper/initrd
      if [[ $TARGET_ARCH == x86_64 ]]; then
        base=https://releases.ubuntu.com/26.04.1
        P_ISO_URL="$base/ubuntu-26.04.1-desktop-amd64.iso"
        P_ISO_MB=6182; P_RAM_GB=10; P_MIN_MB=7000
      else
        base=https://cdimage.ubuntu.com/releases/26.04.1/release
        P_ISO_URL="$base/ubuntu-26.04.1-desktop-arm64.iso"
        P_ISO_MB=3962; P_RAM_GB=7; P_MIN_MB=4800
      fi
      P_SUMS_URL="$base/SHA256SUMS"; P_SUMS_SIG_URL="$base/SHA256SUMS.gpg"
      P_LABEL="Ubuntu 26.04.1 LTS desktop"
      ;;
    ubuntu24)
      only_x86
      P_FAMILY=casper; P_KERNEL=casper/vmlinuz; P_INITRD=casper/initrd
      base=https://releases.ubuntu.com/noble
      P_ISO_URL="$base/ubuntu-24.04.5.1-desktop-amd64.iso"
      P_SUMS_URL="$base/SHA256SUMS"; P_SUMS_SIG_URL="$base/SHA256SUMS.gpg"
      P_ISO_MB=5960; P_RAM_GB=10; P_MIN_MB=6800
      P_LABEL="Ubuntu 24.04.5.1 LTS desktop"
      ;;
    debian)
      only_x86
      P_FAMILY=live; P_KERNEL=live/vmlinuz; P_INITRD=live/initrd.img; P_ROOTFS=live/filesystem.squashfs
      base=https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid
      P_ISO_URL="$base/debian-live-13.7.0-amd64-standard.iso"
      P_SUMS_URL="$base/SHA256SUMS"; P_SUMS_SIG_URL="$base/SHA256SUMS.sign"
      P_ISO_MB=1926; P_RAM_GB=4; P_MIN_MB=3600
      P_LABEL="Debian 13.7.0 live (standard)"
      ;;
    fedora)
      only_x86
      P_FAMILY=dracut
      P_KERNEL=boot/x86_64/loader/linux; P_INITRD=boot/x86_64/loader/initrd; P_ROOTFS=LiveOS/squashfs.img
      base=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso
      P_ISO_URL="$base/Fedora-Workstation-Live-44-1.7.x86_64.iso"
      P_SUMS_URL="$base/Fedora-Workstation-44-1.7-x86_64-CHECKSUM"; P_SUMS_CLEARSIGNED=1
      P_KEY_EXTRA_URL="https://fedoraproject.org/fedora.gpg"
      P_ISO_MB=2719; P_RAM_GB=6; P_MIN_MB=6000
      P_LABEL="Fedora Workstation 44 live"
      ;;
    arch)
      only_x86
      P_FAMILY=archiso
      P_KERNEL=arch/boot/x86_64/vmlinuz-linux; P_INITRD=arch/boot/x86_64/initramfs-linux.img
      P_ROOTFS=arch/x86_64/airootfs.sfs
      base=https://geo.mirror.pkgbuild.com/iso/latest
      P_ISO_URL="$base/archlinux-x86_64.iso"
      P_ISO_SIG_URL="$base/archlinux-x86_64.iso.sig"
      P_SUMS_URL="$base/sha256sums.txt"      # unsigned; secondary check behind the ISO signature
      P_ISO_MB=1564; P_RAM_GB=4; P_MIN_MB=3200
      P_LABEL="Arch Linux (latest monthly ISO)"
      ;;
    systemrescue)
      only_x86
      P_FAMILY=archiso
      P_KERNEL=sysresccd/boot/x86_64/vmlinuz; P_INITRD=sysresccd/boot/x86_64/sysresccd.img
      P_ROOTFS=sysresccd/x86_64/airootfs.sfs; P_EXTRA_ARGS="iomem=relaxed"
      P_ISO_URL="https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/13.02/systemrescue-13.02-amd64.iso"
      P_ISO_SIG_URL="https://www.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso.asc"
      P_SUMS_URL="https://www.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso.sha512"
      P_SUMS_ALGO=sha512
      P_ISO_MB=1350; P_RAM_GB=4; P_MIN_MB=3000
      P_LABEL="SystemRescue 13.02"
      ;;
    parrot)
      P_FAMILY=live; P_KERNEL=live/vmlinuz; P_INITRD=live/initrd.img; P_ROOTFS=live/filesystem.squashfs
      P_ISO_URL="https://deb.parrot.sh/parrot/iso/7.4/Parrot-security-7.4_${DEB_ARCH}.iso"
      P_SUMS_URL="https://deb.parrot.sh/parrot/iso/7.4/signed-hashes.txt"; P_SUMS_CLEARSIGNED=1
      P_SUMS_ALGO=sha512
      if [[ $TARGET_ARCH == x86_64 ]]; then P_ISO_MB=8279; else P_ISO_MB=7982; fi
      P_RAM_GB=12; P_MIN_MB=17000
      P_LABEL="Parrot Security 7.4"
      ;;
    *)
      die "Unknown DISTRO '$DISTRO'. Use: ubuntu, ubuntu24, debian, fedora, arch, systemrescue, parrot"
      ;;
  esac

  FAMILY=$P_FAMILY
  ISO_URL=${U_ISO_URL:-$P_ISO_URL}
  if [[ -n $U_ISO_URL && -z $U_SUMS_URL && -z $U_ISO_SIG_URL ]]; then
    warn "ISO_URL overridden. The preset checksum and signature URLs still apply, so the new file must be listed there."
  fi
  SUMS_URL=${U_SUMS_URL:-$P_SUMS_URL}
  SUMS_SIG_URL=${U_SUMS_SIG_URL:-$P_SUMS_SIG_URL}
  SUMS_CLEARSIGNED=$P_SUMS_CLEARSIGNED
  [[ -n $U_SUMS_SIG_URL ]] && SUMS_CLEARSIGNED=0
  SUMS_ALGO=$P_SUMS_ALGO
  ISO_SIG_URL=${U_ISO_SIG_URL:-$P_ISO_SIG_URL}
  KEY_EXTRA_URL=$P_KEY_EXTRA_URL
  case "$DISTRO" in
    ubuntu|ubuntu24)   # keys.openpgp.org does not carry Ubuntu's CD key; Ubuntu's own archive does
      [[ -n $KEY_EXTRA_URL ]] || KEY_EXTRA_URL="deb:https://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/|ubuntu-keyring|usr/share/keyrings/ubuntu-cdimage-keyring.gpg" ;;
  esac
  KEY_FPR=$(norm_fpr "${U_KEY_FPR:-$(vendor_fpr "$DISTRO")}")
  MIN_FREE_MB=${U_MIN_FREE_MB:-$P_MIN_MB}
  CLIENT_RAM_GB=$P_RAM_GB

  ISO_NAME=$(basename "${ISO_URL%%\?*}")
  ISO="$ROOT/$DISTRO-$TARGET_ARCH.iso"
  ISO_VERIFIED="$ISO.verified"
  SUMS_FILE="$DL/$DISTRO-$TARGET_ARCH.sums"
  ISO_SIG_FILE="$DL/$DISTRO-$TARGET_ARCH.iso.sig"
  VERIFY_REC="$STATE/$DISTRO-$TARGET_ARCH.verify"
  LAYOUT="$STATE/$DISTRO-$TARGET_ARCH.layout"
  MANIFEST="$STATE/$DISTRO-$TARGET_ARCH.manifest"
  GNUPG_HOME="$ROOT/gnupg/$DISTRO"
  IPXE_BUILT="$STATE/ipxe-$TARGET_ARCH.built-from"
}

# iPXE binaries served for the current target architecture
# Files the PC downloads first. In shim mode these are Ubuntu's signed shim and grub.
boot_files() {
  if [[ $BOOT_LOADER == shim ]]; then echo shimx64.efi; echo grubx64.efi; echo mmx64.efi; else ipxe_files_for_arch; fi
}
shim_supported() { [[ $TARGET_ARCH == x86_64 && ( $DISTRO == ubuntu || $DISTRO == ubuntu24 ) ]]; }

ipxe_files_for_arch() {
  if [[ $TARGET_ARCH == x86_64 ]]; then
    echo ipxe.efi; echo undionly.kpxe
  else
    echo ipxe-arm64.efi
  fi
}

# =============================================================================
# Helper programs (written at runtime)
# =============================================================================
write_libs() {
  mkdir -p "$LIB"

  cat > "$LIB/ct_parse.py" <<'PYEOF'
import base64, datetime, json, sys

def parse_time(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))

def covers(name, host):
    if name == host:
        return True
    return name.startswith("*.") and "." in host and host.split(".", 1)[1] == name[2:]

mode = sys.argv[1]
if mode == "page":
    data = json.load(open(sys.argv[2]))
    print(len(data), data[-1]["id"] if data else "")
    sys.exit(0)

host = sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
pins = {}
for path in sys.argv[3:]:
    for c in json.load(open(path)):
        try:
            if parse_time(c["not_after"]) < now or parse_time(c["not_before"]) > now:
                continue
        except Exception:
            continue
        rev = c.get("revocation") or {}
        if rev.get("revoked") or c.get("revoked"):
            continue
        if not any(covers(n, host) for n in c.get("dns_names", [])):
            continue
        key = base64.b64encode(bytes.fromhex(c["pubkey_sha256"])).decode()
        until = c["not_after"][:10]
        issuer = ((c.get("issuer") or {}).get("friendly_name") or "unknown").replace(" ", "_")
        if key not in pins or pins[key][0] < until:
            pins[key] = (until, issuer)
for key, (until, issuer) in sorted(pins.items(), key=lambda kv: kv[1][0], reverse=True):
    print(key, until, issuer)
PYEOF

  cat > "$LIB/httpd.py" <<'PYEOF'
import logging
import logging.handlers
import mimetypes
import os
import re
import signal
import socket
import stat
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

bind, port, root = sys.argv[1], int(sys.argv[2]), os.path.realpath(sys.argv[3])
allow = {os.path.realpath(p) for p in os.environ.get("HTTPD_ALLOW", "").split(os.pathsep) if p}
max_conn = int(os.environ.get("HTTPD_MAX_CONN", "16"))
log_path = os.environ.get("HTTPD_LOG")

log = logging.getLogger("httpd")
log.setLevel(logging.INFO)
handler = (logging.handlers.RotatingFileHandler(log_path, maxBytes=1 << 20, backupCount=3)
           if log_path else logging.StreamHandler(sys.stderr))
handler.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%dT%H:%M:%S"))
log.addHandler(handler)

slots = threading.BoundedSemaphore(max_conn)
stats_lock = threading.Lock()
stats = {"requests": 0, "bytes": 0}
RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "netboot-android"
    timeout = 60

    def log_message(self, fmt, *args):
        pass

    def _finish(self, status, sent, started):
        log.info("%s %s %s %d %d %.2fs", self.client_address[0], self.command,
                 self.path, status, sent, time.time() - started)
        with stats_lock:
            stats["requests"] += 1
            stats["bytes"] += sent

    def _simple(self, code, text, extra=None):
        body = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True
        return code

    def _resolve(self):
        path = unquote(urlsplit(self.path).path)
        if "\x00" in path:
            return None
        fs = os.path.realpath(os.path.join(root, path.lstrip("/")))
        if fs == root or fs.startswith(root + os.sep) or fs in allow:
            return fs
        return None

    def _serve(self):
        started = time.time()
        if urlsplit(self.path).path == "/healthz":
            with stats_lock:
                text = "ok requests=%d bytes=%d" % (stats["requests"], stats["bytes"])
            self._simple(200, text)
            return
        if not slots.acquire(blocking=False):
            self._finish(self._simple(503, "busy, retry shortly", {"Retry-After": "2"}), 0, started)
            return
        try:
            fs = self._resolve()
            if fs is None:
                self._finish(self._simple(403, "forbidden"), 0, started)
                return
            try:
                f = open(fs, "rb")
                st = os.fstat(f.fileno())
            except OSError:
                self._finish(self._simple(404, "not found"), 0, started)
                return
            with f:
                if not stat.S_ISREG(st.st_mode):
                    self._finish(self._simple(404, "not found"), 0, started)
                    return
                size = st.st_size
                start, end, status = 0, size - 1, 200
                match = RANGE_RE.match(self.headers.get("Range", "").strip())
                if match and (match.group(1) or match.group(2)):
                    first, last = match.groups()
                    if first == "":
                        count = int(last)
                        start = max(size - count, 0)
                        end = size - 1
                        bad = count == 0
                    else:
                        start = int(first)
                        end = min(int(last), size - 1) if last else size - 1
                        bad = start >= size or start > end
                    if bad:
                        self._finish(self._simple(416, "range not satisfiable",
                                                  {"Content-Range": "bytes */%d" % size}), 0, started)
                        return
                    status = 206
                length = max(end - start + 1, 0)
                ctype = "text/plain" if fs.endswith(".ipxe") else (
                    mimetypes.guess_type(fs)[0] or "application/octet-stream")
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(length))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Last-Modified", self.date_time_string(st.st_mtime))
                if status == 206:
                    self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
                self.send_header("Connection", "close")
                self.end_headers()
                sent = 0
                if self.command != "HEAD" and length > 0:
                    try:
                        sent = self.connection.sendfile(f, start, length)
                    except (OSError, socket.timeout):
                        sent = 0
                self.close_connection = True
                self._finish(status, sent, started)
        finally:
            slots.release()

    do_GET = _serve
    do_HEAD = _serve


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, socket.timeout)):
            return
        log.exception("error handling %s", client_address)


server = Server((bind, port), Handler)


def stop(*_):
    threading.Thread(target=server.shutdown, daemon=True).start()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
log.info("listening on %s:%d root=%s max_conn=%d", bind, port, root, max_conn)
server.serve_forever()
PYEOF

  cat > "$LIB/findbytes.py" <<'PYEOF'
import mmap, sys
needle = bytes.fromhex(sys.argv[2])
with open(sys.argv[1], "rb") as f:
    try:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            sys.exit(0 if m.find(needle) >= 0 else 1)
    except ValueError:      # empty file
        sys.exit(1)
PYEOF

  # One pass over a big file: several digests at once, without evicting the page cache.
  cat > "$LIB/hashfile.py" <<'PYEOF'
import hashlib, os, sys

path = sys.argv[1]
names = sys.argv[2].split(",") if len(sys.argv) > 2 else ["sha256"]
digests = [hashlib.new(n) for n in names]
CHUNK = 4 << 20
DROP_EVERY = 256 << 20
buf = bytearray(CHUNK)
view = memoryview(buf)
fd = os.open(path, os.O_RDONLY)
try:
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_SEQUENTIAL)
    except (AttributeError, OSError):
        pass
    done = dropped = 0
    while True:
        n = os.readv(fd, [view])
        if n == 0:
            break
        part = view[:n]
        for d in digests:
            d.update(part)
        done += n
        if done - dropped >= DROP_EVERY:
            try:
                os.posix_fadvise(fd, dropped, done - dropped, os.POSIX_FADV_DONTNEED)
            except (AttributeError, OSError):
                pass
            dropped = done
finally:
    os.close(fd)
for name, d in zip(names, digests):
    print(name, d.hexdigest())
PYEOF
}

# =============================================================================
# Network detection
# =============================================================================
iface_cidr() {
  ip_q -4 -o addr show dev "$1" | awk '{print $4}' | grep -v '^127\.' | head -n1 || true
}

auto_iface() {
  local name cidr score best="" bestscore=0
  while read -r name cidr; do
    [[ -z ${name:-} ]] && continue
    case $name in
      lo|rmnet*|ccmni*|dummy*|tun*|wg*|v4-*|clat*|docker*|veth*|br-*|virbr*|ip6tnl*|sit*|p2p*) continue ;;
    esac
    case $cidr in 127.*|169.254.*) continue ;; esac
    case $name in
      wlan0)            score=60 ;;
      eth*|en*)         score=55 ;;
      wlan*|wl*)        score=50 ;;
      ap*|swlan*|softap*) score=30 ;;
      usb*|rndis*|ncm*) score=25 ;;
      *)                score=10 ;;
    esac
    if (( score > bestscore )); then best=$name; bestscore=$score; fi
  done <<<"$(ip_q -4 -o addr show | awk '{print $2, $4}')"

  if [[ -z $best && $DHCP_MODE == direct ]]; then
    best=$(ip_q -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' \
           | grep -E '^(eth|usb|rndis|ncm|en)' | head -n1 || true)
  fi
  printf '%s' "$best"
}

# Sets IFACE, MODE, PHONE_IP, PREFIX_LEN, NET, MASK, BASE_URL, IS_HOTSPOT
resolve_network() {
  [[ -n $IFACE ]] || IFACE=$(auto_iface)
  [[ -n $IFACE ]] || die "No usable network interface. Connect to Wi-Fi or Ethernet, or set IFACE=..."

  local cidr
  cidr=$(iface_cidr "$IFACE")

  MODE=$DHCP_MODE
  if [[ $MODE == auto ]]; then
    if [[ -z $cidr && $IFACE =~ ^(eth|usb|rndis|ncm|en) ]]; then MODE=direct; else MODE=proxy; fi
  fi
  case $MODE in proxy|direct) ;; *) die "DHCP_MODE must be auto, proxy, or direct" ;; esac

  if [[ $MODE == direct && -z $cidr ]]; then cidr=$DIRECT_CIDR; fi
  [[ -n $cidr ]] || die "$IFACE has no IPv4 address. Connect it, or use --mode direct for a cable to the PC."

  local prefix ipint maskint
  PHONE_IP=${cidr%/*}
  prefix=${cidr#*/}
  [[ $prefix =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 32 )) || die "Unexpected prefix in $cidr"
  (( prefix <= 30 )) || die "Subnet /$prefix on $IFACE is too small for PXE clients"

  ipint=$(ip_to_int "$PHONE_IP")
  maskint=$(prefix_to_mask_int "$prefix")
  NET="${NET:-$(int_to_ip $(( ipint & maskint )))}"
  MASK=$(int_to_ip "$maskint")
  PREFIX_LEN=$prefix
  BASE_URL="http://${PHONE_IP}:${HTTP_PORT}"

  IS_HOTSPOT=0
  [[ $IFACE =~ ^(ap|swlan|softap) ]] && IS_HOTSPOT=1
  return 0
}

# DHCP pool for direct mode, kept clear of the phone's own address
direct_pool() {
  local netint size start end phone
  netint=$(ip_to_int "$NET")
  size=$(( 1 << (32 - PREFIX_LEN) ))
  phone=$(ip_to_int "$PHONE_IP")
  start=$(( netint + size / 4 ))
  end=$(( netint + size - 2 ))
  (( end - start > 100 )) && end=$(( start + 100 ))
  if (( phone >= start && phone <= end )); then start=$(( phone + 1 )); fi
  (( start <= end )) || die "Cannot fit a DHCP pool in $NET/$PREFIX_LEN"
  POOL_START=$(int_to_ip "$start")
  POOL_END=$(int_to_ip "$end")
}

# =============================================================================
# Ports
# =============================================================================
# port_in_use PROTO PORT   (PROTO: tcp | udp)
port_in_use() {
  local proto=$1 port=$2 out hex
  if ss -H -ln >/dev/null 2>&1; then
    if [[ $proto == udp ]]; then
      out=$(ss -H -lun "sport = :$port" 2>/dev/null || true)
    else
      out=$(ss -H -ltn "sport = :$port" 2>/dev/null || true)
    fi
    [[ -n $out ]]
    return
  fi
  hex=$(printf '%04X' "$port")
  out=$( { cat "/proc/net/$proto" "/proc/net/${proto}6" 2>/dev/null \
          || run_root "cat /proc/net/$proto /proc/net/${proto}6" 2>/dev/null; } || true)
  if [[ $proto == tcp ]]; then
    awk -v p=":$hex" '$2 ~ p"$" && $4=="0A"' <<<"$out" | grep -q .
  else
    awk -v p=":$hex" '$2 ~ p"$"' <<<"$out" | grep -q .
  fi
}

# =============================================================================
# TLS pinning and Certificate Transparency validation
# =============================================================================
audit() { mkdir -p "$STATE"; printf '%s %s\n' "$(now_iso)" "$*" >> "$PIN_AUDIT"; }

# Active pins for a host: refreshed file first, then the embedded snapshot.
# Expired entries are dropped.
active_pins() {
  local host=$1 t
  t=$(today)
  if [[ -s $PIN_DIR/$host ]]; then
    awk -v t="$t" '$2 >= t {print $1}' "$PIN_DIR/$host"
  else
    pin_snapshot | awk -F'|' -v h="$host" -v t="$t" '$1==h && $3 >= t {print $2}'
  fi
}

pins_curl_arg() {
  active_pins "$1" | awk 'NF{printf "%ssha256//%s", (n++ ? ";" : ""), $1}'
}

served_spki() {
  local host=$1 pem
  pem=$(with_timeout 20 openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
        | openssl x509 2>/dev/null) || true
  [[ -n $pem ]] || return 1
  printf '%s\n' "$pem" | openssl x509 -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary | openssl base64 -A
}

# vfetch URL DEST [protected|strict]
#   protected: the content is checked afterwards (signature or fingerprint), so a
#              redirect to an unpinned mirror is allowed over CA-validated TLS.
#   strict:    the content is trusted on transport alone, so a pin is required.
# A pin MISMATCH is always fatal: it is evidence of interception.
vfetch() {
  local url=$1 dest=$2 mode=${3:-protected} hop=0 host pins out rc code next
  mkdir -p "$(dirname "$dest")"
  while (( hop < 6 )); do
    host=$(url_host "$url")
    pins=$(pins_curl_arg "$host")
    local -a popt=()
    if [[ -n $pins ]]; then
      popt=(--pinnedpubkey "$pins")
    elif [[ $mode == protected ]]; then
      info "No pin for $host; using CA-validated TLS (content is verified afterwards)"
    elif [[ $ALLOW_UNPINNED == 1 ]]; then
      warn "No pin for $host. Fetching unpinned because ALLOW_UNPINNED=1"
    else
      die "No certificate pin for $host. Run: $0 pins refresh $host"
    fi

    rc=0
    out=$(curl -sS --proto '=https' --tlsv1.2 --max-redirs 0 --connect-timeout 20 --max-time 900 \
            "${popt[@]+"${popt[@]}"}" -o "$dest.tmp" -w '%{http_code} %{redirect_url}' "$url") || rc=$?
    case $rc in
      0) ;;
      90) rm -f "$dest.tmp"; audit "$host PIN-MISMATCH url=$url"
          die "PIN MISMATCH for $host. The key it presented is not a pinned key. This is what TLS interception looks like. If the site rotated its certificate, run: $0 pins refresh $host" ;;
      35|51|58|59|60|83)
          rm -f "$dest.tmp"; die "TLS verification failed for $host (curl error $rc)" ;;
      *)  rm -f "$dest.tmp"; die "Fetch failed for $url (curl error $rc)" ;;
    esac

    code=${out%% *}
    next=${out#* }
    if [[ $code == 2?? ]]; then
      mv -f "$dest.tmp" "$dest"
      return 0
    elif [[ $code == 3?? && -n $next ]]; then
      rm -f "$dest.tmp"
      url=$next
      hop=$((hop+1))
      continue
    else
      rm -f "$dest.tmp"
      die "HTTP $code for $url"
    fi
  done
  die "Too many redirects for $1"
}

# GET against the CT API, pinned
ct_get() {
  local url=$1 dest=$2 pins rc=0
  pins=$(pins_curl_arg "$CT_HOST")
  if [[ -n $pins ]]; then
    curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 \
         --pinnedpubkey "$pins" -o "$dest" "$url" || rc=$?
  elif [[ $CT_BOOTSTRAP == 1 ]]; then
    warn "No valid pin for $CT_HOST. Bootstrapping over CA-validated TLS (CT_BOOTSTRAP=1)."
    curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 -o "$dest" "$url" || rc=$?
  else
    die "No valid pin for $CT_HOST (embedded pins expired). Run once with CT_BOOTSTRAP=1 on a network you trust."
  fi
  case $rc in
    0)  return 0 ;;
    90) audit "$CT_HOST PIN-MISMATCH"; die "PIN MISMATCH for $CT_HOST. Possible TLS interception." ;;
    22) err "CT API refused the request (rate limit or HTTP error). Wait a few minutes and retry."; return 1 ;;
    *)  err "CT API request failed (curl error $rc)"; return 1 ;;
  esac
}

# Prints "spki until issuer" lines for all current, unrevoked certs covering HOST
ct_current() {
  local host=$1 tmp=$2 dom after page pinfo n last f
  local -a files=() doms=("$host")
  local parent=${host#*.}
  [[ $parent == *.* ]] && doms+=("$parent")
  for dom in "${doms[@]}"; do
    after=""; page=0
    while (( page < 40 )); do
      f="$tmp/ct.$dom.$page.json"
      ct_get "$CT_API?domain=$dom&expand=dns_names&expand=issuer&expand=revocation${after:+&after=$after}" "$f" || return 1
      pinfo=$("$PYTHON" "$LIB/ct_parse.py" page "$f") || return 1
      read -r n last <<<"$pinfo"
      if (( n == 0 )); then rm -f "$f"; break; fi
      files+=("$f")
      after=$last
      page=$((page+1))
      sleep 1
    done
  done
  (( ${#files[@]} )) || return 0
  "$PYTHON" "$LIB/ct_parse.py" pins "$host" "${files[@]}"
}

pin_hosts_for_target() {
  local u h
  {
    echo "$CT_HOST"
    for u in "$SUMS_URL" "$SUMS_SIG_URL" "$ISO_SIG_URL" "$KEY_EXTRA_URL"; do
      [[ -n $u ]] && url_host "$u" && echo
    done
    for h in "${INFRA_HOSTS[@]}"; do echo "$h"; done
  } | awk 'NF && !seen[$0]++'
}

# External validation: the key each server presents must be in the CT log set
pins_refresh() {
  need openssl; need curl
  [[ -n $PYTHON ]] || die "python3 is required. Run: $0 deps"
  write_libs
  mkdir -p "$PIN_DIR" "$STATE"

  local -a hosts=("$@")
  if (( ${#hosts[@]} == 0 )); then mapfile -t hosts <<<"$(pin_hosts_for_target)"; fi

  local tmp h served fails=0 n
  tmp=$(mktemp -d)
  for h in "${hosts[@]}"; do
    info "Checking $h against Certificate Transparency"
    if ! ct_current "$h" "$tmp" > "$tmp/$h.pins"; then
      err "$h: CT lookup failed"; audit "$h CT-LOOKUP-FAILED"; fails=$((fails+1)); continue
    fi
    n=$(grep -c . "$tmp/$h.pins" || true)
    if (( n == 0 )); then
      err "$h: CT shows no currently valid certificate"; audit "$h CT-EMPTY"; fails=$((fails+1)); continue
    fi

    served=$(served_spki "$h" || true)
    if [[ -z $served ]]; then
      err "$h: could not read the served certificate"; audit "$h SERVED-UNREADABLE"; fails=$((fails+1)); continue
    fi

    if awk '{print $1}' "$tmp/$h.pins" | grep -qxF "$served"; then
      awk -v src="ct:$(today)" '{print $1, $2, src}' "$tmp/$h.pins" > "$PIN_DIR/$h"
      ok "$h: served key is in CT ($n current keys pinned)"
      audit "$h OK served=$served ct_keys=$n"
    else
      err "$h: INTERCEPTION SUSPECTED. Served key sha256//$served is not in the CT log set."
      err "    Pins for $h were NOT updated. Do not download over this network."
      audit "$h INTERCEPTION served=$served"
      fails=$((fails+1))
    fi
  done
  rm -rf "$tmp"
  if (( fails )); then
    err "$fails host(s) failed CT validation. Details: $PIN_AUDIT"
    return 1
  fi
  ok "All hosts validated against CT"
}

pins_show() {
  local h t src
  t=$(today)
  info "Pins in use (expired entries hidden). Snapshot date: $PIN_SNAPSHOT_DATE"
  for h in $( { pin_snapshot | cut -d'|' -f1; ls "$PIN_DIR" 2>/dev/null || true; } | sort -u ); do
    if [[ -s $PIN_DIR/$h ]]; then src="refreshed"; else src="snapshot"; fi
    printf '  %-28s %-9s %s valid pin(s)\n' "$h" "$src" "$(active_pins "$h" | grep -c . || true)"
  done
}

# =============================================================================
# OpenPGP: multi-source keys and strict signature checks
# =============================================================================
key_fprs_of() {
  local scratch=$1 file=$2
  gpg --homedir "$scratch" --batch --no-tty --with-colons --show-keys "$file" 2>/dev/null \
    | awk -F: '$1=="fpr"{print $10}'
}

# Newest NAME_*_all.deb listed in an HTML directory index (stdin)
latest_deb_name() {   # latest_deb_name PKG < index.html
  grep -o "$1_[0-9][0-9A-Za-z.+~:-]*_all\.deb" | sort -uV | tail -n1
}

# Pulls one file out of a .deb (an ar archive holding data.tar.*)
deb_extract_member() {   # deb_extract_member DEB MEMBER_PATH DEST
  local deb=$1 member=$2 dest=$3
  need bsdtar
  bsdtar -xOf "$deb" 'data.tar*' 2>/dev/null | bsdtar -xOf - "./$member" > "$dest.tmp" 2>/dev/null \
    && [[ -s $dest.tmp ]] && mv -f "$dest.tmp" "$dest" || { rm -f "$dest.tmp"; return 1; }
}

# A key source is either an https URL, or  deb:BASEURL|PACKAGE|PATH-INSIDE-PACKAGE
fetch_key_source() {   # fetch_key_source SRC DEST
  local src=$1 dest=$2
  if [[ $src == deb:* ]]; then
    local spec=${src#deb:} base pkg member idx name
    base=${spec%%|*}; spec=${spec#*|}; pkg=${spec%%|*}; member=${spec#*|}
    idx=$(mktemp)
    vfetch "$base" "$idx" protected || { rm -f "$idx"; return 1; }
    name=$(latest_deb_name "$pkg" < "$idx"); rm -f "$idx"
    [[ -n $name ]] || return 1
    vfetch "$base$name" "$dest.deb" protected || return 1
    deb_extract_member "$dest.deb" "$member" "$dest"; local rc=$?
    rm -f "$dest.deb"
    return $rc
  fi
  vfetch "$src" "$dest" protected
}

prepare_keyring() {
  need gpg
  [[ -n $KEY_FPR ]] || die "No signing key fingerprint for $DISTRO. Set KEY_FPR."
  mkdir -p "$GNUPG_HOME" "$KEYS_DIR/$DISTRO"
  chmod 700 "$GNUPG_HOME"
  [[ -f $GNUPG_HOME/.ready-$KEY_FPR ]] && return 0

  info "Fetching signing key $KEY_FPR from independent sources"
  local scratch src f fprs i=0 agree=0
  scratch=$(mktemp -d); chmod 700 "$scratch"
  : > "$GNUPG_HOME/source-fprs"

  local -a srcs=("${KEYSERVER_UBUNTU}${KEY_FPR}" "${KEYSERVER_OPENPGP}${KEY_FPR}")
  [[ -n $KEY_EXTRA_URL ]] && srcs+=("$KEY_EXTRA_URL")

  for src in "${srcs[@]}"; do
    i=$((i+1))
    f="$KEYS_DIR/$DISTRO/key.$i.asc"
    if ( fetch_key_source "$src" "$f" ); then
      fprs=$(key_fprs_of "$scratch" "$f")
      if grep -qx "$KEY_FPR" <<<"$fprs"; then
        agree=$((agree+1))
        printf '%s %s\n' "$i" "$(tr '\n' ' ' <<<"$fprs")" >> "$GNUPG_HOME/source-fprs"
        gpg --homedir "$GNUPG_HOME" --batch --no-tty --quiet --import "$f" 2>/dev/null || true
        ok "Source $i ($(url_host "$src")) has key $KEY_FPR"
      else
        warn "Source $i ($(url_host "$src")) did not return key $KEY_FPR"
      fi
    else
      warn "Source $i ($(url_host "$src")) unreachable"
    fi
  done
  rm -rf "$scratch"

  if (( agree < KEY_MIN_SOURCES )); then
    die "$E_NET" "Key $KEY_FPR was confirmed by only $agree source(s); $KEY_MIN_SOURCES are required. Nothing was downloaded or deleted. Check your internet and run the same step again. (To accept one source, whose key matches the fingerprint built into this script, set KEY_MIN_SOURCES=1.)"
  fi
  gpg --homedir "$GNUPG_HOME" --batch --no-tty --list-keys "$KEY_FPR" >/dev/null 2>&1 \
    || die "Key $KEY_FPR could not be imported into the keyring"
  touch "$GNUPG_HOME/.ready-$KEY_FPR"
  ok "Signing key confirmed by $agree independent sources"
}

# Accepts only a good signature by KEY_FPR, made by a (sub)key present on at least 2 sources
sig_ok() {
  local st=$1 sigkey="" primary="" count=0 rest
  grep -q '^\[GNUPG:\] GOODSIG ' "$st" || return 1
  if grep -qE '^\[GNUPG:\] (BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG|ERRSIG) ' "$st"; then return 1; fi
  validsig=$(awk '$2=="VALIDSIG"{print $3, $NF}' "$st" | head -n1) || return 1
  read -r sigkey primary <<<"$validsig"
  [[ $primary == "$KEY_FPR" ]] || return 1
  while read -r _ rest; do
    if grep -qw "$sigkey" <<<"$rest"; then count=$((count+1)); fi
  done < "$GNUPG_HOME/source-fprs"
  (( count >= KEY_MIN_SOURCES )) || return 1
  SIG_SIGNER=$sigkey
}

record() { printf '%s\n' "$*" >> "$VERIFY_REC.tmp"; }

verify_detached() {
  local sig=$1 data=$2 label=$3 st
  st=$(mktemp)
  gpg --homedir "$GNUPG_HOME" --batch --no-tty --status-file "$st" --verify "$sig" "$data" >/dev/null 2>&1 || true
  if sig_ok "$st"; then
    ok "$label: signature valid (signing key $SIG_SIGNER)"
    record "SIG label=\"$label\" signer=$SIG_SIGNER primary=$KEY_FPR"
    rm -f "$st"; return 0
  fi
  rm -f "$st"
  err "$label: signature INVALID or not made by $KEY_FPR"
  return 1
}

# Writes only the signed portion of a clearsigned file to OUT
verify_clearsigned() {
  local in=$1 out=$2 label=$3 st
  st=$(mktemp)
  gpg --homedir "$GNUPG_HOME" --batch --no-tty --yes --status-file "$st" --output "$out" --decrypt "$in" >/dev/null 2>&1 || true
  if sig_ok "$st" && [[ -s $out ]]; then
    ok "$label: clearsigned content valid (signing key $SIG_SIGNER)"
    record "SIG label=\"$label\" signer=$SIG_SIGNER primary=$KEY_FPR clearsigned=1"
    rm -f "$st"; return 0
  fi
  rm -f "$st" "$out"
  err "$label: clearsigned signature INVALID or not made by $KEY_FPR"
  return 1
}

# Finds the expected hash for NAME in GNU ("hash  name", "hash *name") or
# BSD ("ALGO (name) = hash") format, keeping only hashes of the right length
sums_lookup() {
  local list=$1 name=$2 algo=$3 len
  case $algo in sha256) len=64 ;; sha512) len=128 ;; *) return 1 ;; esac
  awk -v f="$name" -v L="$len" '
    /^[A-Za-z0-9-]+ \(.*\) = [0-9a-fA-F]+[[:space:]]*$/ {
      n=$0; sub(/^[A-Za-z0-9-]+ \(/, "", n); sub(/\) = .*$/, "", n); h=$NF
      if (n == f && length(h) == L) { print tolower(h); exit }
      next
    }
    NF >= 2 && $1 ~ /^[0-9a-fA-F]+$/ {
      n=$2; sub(/^\*/, "", n)
      if (n == f && length($1) == L) { print tolower($1); exit }
    }' "$list"
}

# =============================================================================
# Local attestation identity
# =============================================================================
attest_fpr() {
  [[ -s $ATTEST/attest.fpr ]] && cat "$ATTEST/attest.fpr" || true
}

ca_fpr_hex() {
  [[ -s ${1:-$ATTEST/ca.crt} ]] || return 1
  openssl x509 -in "${1:-$ATTEST/ca.crt}" -outform DER | sha256sum | awk '{print $1}'
}

openssl_has_not_before() {
  openssl x509 -help 2>&1 | grep -q -- '-not_before'
}

attest_init() {
  need gpg; need openssl
  mkdir -p "$ATTEST" "$ATTEST_GNUPG" "$ATTEST/reports"
  chmod 700 "$ATTEST" "$ATTEST_GNUPG"

  if [[ -z $(attest_fpr) ]]; then
    info "Generating the attestation signing key (ed25519, stays on this device)"
    gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --passphrase '' \
        --quick-gen-key "netboot-android attestation <attest@$(hostname 2>/dev/null || echo device)>" ed25519 sign never \
        >/dev/null 2>&1 || die "Could not generate the attestation key"
    gpg --homedir "$ATTEST_GNUPG" --batch --with-colons --list-secret-keys 2>/dev/null \
      | awk -F: '$1=="fpr"{print $10; exit}' > "$ATTEST/attest.fpr"
    gpg --homedir "$ATTEST_GNUPG" --batch --armor --export "$(attest_fpr)" > "$ATTEST/attest-key.asc"
    ok "Attestation key: $(attest_fpr)"
  else
    ok "Attestation key exists: $(attest_fpr)"
  fi

  if [[ ! -s $ATTEST/ca.crt ]]; then
    info "Generating the boot code-signing CA (RSA 3072)"
    local -a validity=(-days 7300)
    if openssl_has_not_before; then
      # Backdated start so a client with a wrong clock still accepts it
      validity=(-not_before 20200101000000Z -not_after 20450101000000Z)
    fi
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 "${validity[@]}" \
      -subj "/CN=netboot-android attestation CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$ATTEST/ca.key" -out "$ATTEST/ca.crt" 2>/dev/null \
      || die "CA generation failed"
    openssl req -newkey rsa:3072 -nodes -sha256 -subj "/CN=netboot-android code signing" \
      -keyout "$ATTEST/codesign.key" -out "$ATTEST/codesign.csr" 2>/dev/null \
      || die "Code-signing key generation failed"
    printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' \
      > "$ATTEST/codesign.ext"
    openssl x509 -req -in "$ATTEST/codesign.csr" -CA "$ATTEST/ca.crt" -CAkey "$ATTEST/ca.key" \
      -CAcreateserial -sha256 "${validity[@]}" -extfile "$ATTEST/codesign.ext" \
      -out "$ATTEST/codesign.crt" 2>/dev/null || die "Code-signing certificate failed"
    openssl verify -CAfile "$ATTEST/ca.crt" "$ATTEST/codesign.crt" >/dev/null \
      || die "Code-signing certificate does not chain to the CA"
    chmod 600 "$ATTEST/ca.key" "$ATTEST/codesign.key"
    rm -f "$ATTEST/codesign.csr"
    ok "Boot CA SHA-256: $(ca_fpr_hex)"
  else
    ok "Boot CA exists: $(ca_fpr_hex)"
  fi

  warn "Write down the two fingerprints above on another device. They are your external reference."
}

cms_sign() {
  local f=$1
  openssl cms -sign -binary -noattr -in "$f" \
    -signer "$ATTEST/codesign.crt" -inkey "$ATTEST/codesign.key" \
    -certfile "$ATTEST/ca.crt" -outform DER -out "$f.sig" \
    || die "Signing failed for $f"
}

# =============================================================================
# Script self-integrity
# =============================================================================
self_sign() {
  [[ -n $(attest_fpr) ]] || die "Run: $0 attest-init first"
  local h
  h=$(sha256_of "$SELF")
  printf '%s  %s\n' "$h" "$SCRIPT_VERSION" > "$ATTEST/script.sha256"
  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --yes --local-user "$(attest_fpr)" \
      --armor --detach-sign --output "$ATTEST/script.sha256.asc" "$ATTEST/script.sha256" \
      || die "Self-signing failed"
  ok "Script hash signed: $h"
  info "Compare this hash with a copy of the script kept on another device."
}

self_status() {   # prints: unset | bad | changed | ok   (never dies)
  if [[ ! -s $ATTEST/script.sha256 || ! -s $ATTEST/script.sha256.asc ]]; then echo unset; return 0; fi
  local st rec cur
  st=$(mktemp)
  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --status-file "$st" \
      --verify "$ATTEST/script.sha256.asc" "$ATTEST/script.sha256" >/dev/null 2>&1 || true
  if ! awk -v f="$(attest_fpr)" '$2=="VALIDSIG" && $NF==f {found=1} END{exit !found}' "$st"; then
    rm -f "$st"; echo bad; return 0
  fi
  rm -f "$st"
  cur=$(sha256_of "$SELF"); rec=$(awk '{print $1}' "$ATTEST/script.sha256")
  if [[ $cur != "$rec" ]]; then echo changed; else echo ok; fi
}

self_check_soft() {   # for interactive entry points: a *changed* script can be re-signed on the spot
  [[ $(self_status) != unset ]] || return 0   # first run: the guide sets this up, no scary warning
  if [[ $(self_status) == changed ]] && { [[ -t 0 ]] || [[ $ASSUME_YES == 1 ]]; }; then
    warn "This script was updated since you last signed it."
    hint "If you just updated it yourself or pulled a new version, that is normal."
    if ask_yn "Trust this version and re-sign it now?" n; then self_sign; return 0; fi
  fi
  self_check
}

self_check() {
  case "$(self_status)" in
    unset)
      warn "Self-attestation is not set up. Run: $0 attest-init, then $0 self-sign" ;;
    bad)
      die "$E_INTEGRITY" "The signed script hash record failed verification. The attestation files may have been altered." ;;
    changed)
      if [[ $ACCEPT_SCRIPT_CHANGE == 1 ]]; then
        warn "Script changed since it was signed (ACCEPT_SCRIPT_CHANGE=1). Run $0 self-sign to record the new version."
      else
        err "This script changed since it was last self-signed."
        next_step "if YOU updated or edited it: run '$0 self-sign', then run your command again. If you did not, stop and compare '$0 fingerprints' with another device."
        exit "$E_INTEGRITY"
      fi ;;
  esac
}

show_fingerprints() {
  echo
  box \
    "EXTERNAL REFERENCE VALUES" \
    "Compare these with copies kept on another device." \
    "" \
    "Script SHA-256:" \
    "  $(sha256_of "$SELF")" \
    "Attestation key:" \
    "  $(attest_fpr || true)" \
    "Boot CA SHA-256:" \
    "  $(ca_fpr_hex 2>/dev/null || echo 'not created')" \
    "iPXE commit:" \
    "  $IPXE_COMMIT" \
    "Release time:" \
    "  $( [[ -n $RELEASE_TIME ]] && epoch_to_iso "$RELEASE_TIME" || echo 'not stamped')" \
    "Release code:" \
    "  $( [[ -n $RELEASE_TIME ]] && release_code "$SELF" "$RELEASE_TIME" | awk '{print $2}' || echo 'not stamped')"
  echo
}

# =============================================================================
# Dependencies
# =============================================================================
deps() {
  info "Installing packages"
  if (( IS_TERMUX )); then
    pkg update -y
    pkg install -y dnsmasq python libarchive bsdtar curl iproute2 procps openssl openssl-tool gnupg git \
                   clang make perl binutils liblzma xz-utils coreutils
    termux-wake-lock 2>/dev/null || warn "termux-wake-lock unavailable (install Termux:API to keep the CPU awake)"
  elif command -v apt-get >/dev/null 2>&1; then
    run_root "apt-get update && apt-get install -y dnsmasq python3 libarchive-tools curl iproute2 openssl gnupg git build-essential perl liblzma-dev"
    if [[ $(uname -m) == aarch64 && $TARGET_ARCH == x86_64 ]]; then
      info "This is an arm64 system and the PC is x86_64: adding the x86_64 cross-compiler"
      run_root "apt-get install -y gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu" \
        || warn "Could not install the x86_64 cross-compiler here. Try: apt-get install gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu"
    fi
  elif command -v dnf >/dev/null 2>&1; then
    run_root "dnf install -y dnsmasq python3 bsdtar curl iproute openssl gnupg2 git gcc make perl xz-devel"
  elif command -v pacman >/dev/null 2>&1; then
    run_root "pacman -Sy --needed --noconfirm dnsmasq python libarchive curl iproute2 openssl gnupg git base-devel perl xz"
  elif command -v apk >/dev/null 2>&1; then
    run_root "apk add dnsmasq python3 libarchive-tools curl iproute2 openssl gnupg git build-base perl xz-dev"
  else
    die "Unknown package manager. Install manually: dnsmasq python3 bsdtar curl iproute2 openssl gnupg git gcc make perl liblzma headers"
  fi
  hash -r 2>/dev/null || true
  DNSMASQ=$(find_bin dnsmasq || true)
  PYTHON=$(find_bin python3 || find_bin python || true)
  local still; still=$(missing_tools)
  if [[ -n $still ]]; then
    if (( IS_TERMUX )); then
      die "$E_ENV" "The install finished but these programs are still missing: $still. On Termux try: pkg install openssl-tool bsdtar dnsmasq gnupg curl python"
    fi
    die "$E_ENV" "The install finished but these programs are still missing: $still. Install them with your package manager and run again."
  fi
  ok "Packages installed and every required program is present"
}

# =============================================================================
# Pinned git transport
# =============================================================================
# Sets GIT_PIN_OPTS to the git options that pin github.com's TLS key
git_pin_opts() {
  GIT_PIN_OPTS=()
  local pins
  pins=$(pins_curl_arg github.com)
  if [[ -n $pins ]]; then
    GIT_PIN_OPTS=(-c "http.pinnedPubkey=$pins")
  elif [[ $ALLOW_UNPINNED == 1 ]]; then
    warn "No pin for github.com. Using git unpinned (ALLOW_UNPINNED=1). Commit hashes still pin the content."
  else
    die "No valid pin for github.com. Run: $0 pins refresh github.com"
  fi
}

# =============================================================================
# Release stamp and upstream verification
# =============================================================================
# HMAC-SHA256 of FILE keyed by the exact upload time. Prints "fullhex shortcode".
release_code() {
  local file=$1 epoch=$2 hex
  hex=$(openssl dgst -sha256 -hmac "netboot-android-v1:$epoch" -r "$file" | awk '{print $1}')
  [[ ${#hex} -eq 64 ]] || return 1
  printf '%s %s-%s-%s-%s-%s\n' "$hex" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}"
}

epoch_to_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# The hard-coded trust data: vendor fingerprints, TLS pins, iPXE commit
trust_block() {
  local file=$1
  sed -n -e '/^DEFAULT_IPXE_COMMIT=/p' \
         -e '/^vendor_fpr() {/,/^}/p' \
         -e '/^pin_snapshot() {/,/^}/p' "$file"
}

release_stamp() {
  local when=${1:-} epoch line code
  [[ -n $when ]] || die "Usage: $0 release-stamp TIME   (UTC, for example 2026-10-09T18:00:00Z)"
  need openssl
  epoch=$(date -u -d "$when" +%s 2>/dev/null) || die "Cannot parse time '$when'. Use a form like 2026-10-09T18:00:00Z"
  [[ -w $SELF ]] || die "Cannot write $SELF"

  line=$(grep -n '^RELEASE_TIME=' "$SELF" | head -n1 | cut -d: -f1)
  [[ -n $line ]] || die "No RELEASE_TIME line found in $SELF"
  sed -i "${line}s/^RELEASE_TIME=\"[0-9]*\"/RELEASE_TIME=\"$epoch\"/" "$SELF"
  grep -q "^RELEASE_TIME=\"$epoch\"" "$SELF" || die "Could not write RELEASE_TIME into $SELF"
  RELEASE_TIME=$epoch

  rc_out=$(release_code "$SELF" "$epoch") || die "Could not compute the release code"
  read -r _ code <<<"$rc_out"
  ok "RELEASE_TIME set to $epoch ($(epoch_to_iso "$epoch"))"
  [[ -n $(attest_fpr) ]] && self_sign

  local iso
  iso=$(epoch_to_iso "$epoch")
  echo
  box \
    "RELEASE CODE: $code" \
    "" \
    "Write this code down somewhere other than this device." \
    "Upload time: $iso"
  echo
  info "Commit and push with exactly this time:"
  printf '  GIT_AUTHOR_DATE=%s GIT_COMMITTER_DATE=%s git commit -am "Release %s"\n' "$iso" "$iso" "$iso"
  printf '  git push origin %s\n\n' "$UPSTREAM_BRANCH"
  info "Then, on any device: $0 verify-upstream   (optionally EXPECT_CODE=$code)"
}

verify_upstream() {
  need git; need openssl
  [[ -n $RELEASE_TIME ]] || die "This script has no RELEASE_TIME. Run: $0 release-stamp TIME"

  local -a gopt=()
  case $UPSTREAM_REPO in
    https://github.com/*) git_pin_opts; gopt=("${GIT_PIN_OPTS[@]+"${GIT_PIN_OPTS[@]}"}") ;;
    *) [[ $ALLOW_UNPINNED == 1 ]] || die "UPSTREAM_REPO is not on github.com. Set ALLOW_UNPINNED=1 to use $UPSTREAM_REPO"
       warn "Using non-GitHub upstream $UPSTREAM_REPO (ALLOW_UNPINNED=1)" ;;
  esac

  local repo="$SRC_DIR/self.git"
  mkdir -p "$SRC_DIR"
  if [[ ! -d $repo ]]; then
    info "Cloning $UPSTREAM_REPO (pinned TLS)"
    git "${gopt[@]+"${gopt[@]}"}" clone --quiet --bare "$UPSTREAM_REPO" "$repo" || die "Clone failed (pin mismatch or network error)"
  fi
  git "${gopt[@]+"${gopt[@]}"}" -C "$repo" fetch --quiet --force "$UPSTREAM_REPO" \
    "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/upstream/$UPSTREAM_BRANCH" \
    || die "Fetch of branch $UPSTREAM_BRANCH failed"

  local commit ctime up
  gl_out=$(git -C "$repo" log -1 --format='%H %ct' "upstream/$UPSTREAM_BRANCH" -- "$UPSTREAM_PATH") \
    || die "No commit touching $UPSTREAM_PATH on $UPSTREAM_BRANCH"
  read -r commit ctime <<<"$gl_out"
  up=$(mktemp)
  git -C "$repo" show "$commit:$UPSTREAM_PATH" > "$up" || { rm -f "$up"; die "Cannot read $UPSTREAM_PATH at $commit"; }
  info "Upstream: $UPSTREAM_BRANCH @ $commit, committed $(epoch_to_iso "$ctime")"

  if [[ $ctime != "$RELEASE_TIME" ]]; then
    rm -f "$up"
    audit "UPSTREAM TIME-MISMATCH commit=$commit upstream=$ctime local=$RELEASE_TIME"
    die "TIME MISMATCH. Upstream commit time $(epoch_to_iso "$ctime") is not this script's RELEASE_TIME $(epoch_to_iso "$RELEASE_TIME")."
  fi

  local lhex lcode uhex ucode
  rc_l=$(release_code "$SELF" "$RELEASE_TIME") || die "Could not hash $SELF"
  read -r lhex lcode <<<"$rc_l"
  rc_u=$(release_code "$up" "$ctime") || die "Could not hash the upstream copy"
  read -r uhex ucode <<<"$rc_u"

  local bad=0
  [[ $lhex == "$uhex" ]] || bad=1
  if [[ -n $EXPECT_CODE ]]; then
    local want=${EXPECT_CODE,,}
    [[ $want == "$ucode" || $want == "$uhex" ]] || { err "EXPECT_CODE $EXPECT_CODE does not match the upstream code $ucode"; bad=1; }
  fi

  if (( bad )); then
    err "This script is NOT the copy uploaded at $(epoch_to_iso "$ctime")"
    err "  local code    $lcode"
    err "  upstream code $ucode"
    local tb_up tb_self
    tb_up=$(mktemp); tb_self=$(mktemp)
    if [[ $lhex == "$uhex" ]]; then
      err "The local file matches upstream, but upstream is not the release you recorded."
    elif ! { trust_block "$up" > "$tb_up"; trust_block "$SELF" > "$tb_self"; diff "$tb_up" "$tb_self" >/dev/null; }; then
      err "Hard-coded trust data differs (upstream '<', local '>'):"
      diff "$tb_up" "$tb_self" >&2 || true
    else
      err "Trust data is identical; other lines differ."
    fi
    rm -f "$up" "$tb_up" "$tb_self"
    audit "UPSTREAM MISMATCH commit=$commit local=$lcode upstream=$ucode"
    die "Upstream verification FAILED"
  fi
  rm -f "$up"
  audit "UPSTREAM MATCH commit=$commit time=$ctime code=$ucode"
  echo
  box \
    "UPSTREAM MATCH" \
    "commit   $commit" \
    "uploaded $(epoch_to_iso "$ctime")" \
    "code     $ucode"
  echo
}

# =============================================================================
# iPXE: build from source with the trust anchor embedded
# =============================================================================
write_embed_script() {
  local out=$1 fb=$2
  cat > "$out" <<'EOF'
#!ipxe
echo netboot-android: verified boot chain
set tries:int32 0
:retry_dhcp
dhcp && goto got_net || echo DHCP attempt failed
inc tries
iseq ${tries} 4 && goto fail || echo Retrying DHCP
sleep 2
goto retry_dhcp
:got_net
imgtrust --permanent
set srv ${proxydhcp/next-server}
isset ${srv} || set srv ${next-server}
iseq ${srv} 0.0.0.0 && clear srv || echo
EOF
  if [[ -n $fb ]]; then
    printf 'isset ${srv} || set srv %s\n' "$fb" >> "$out"
  fi
  cat >> "$out" <<'EOF'
isset ${srv} || goto fail
echo Boot server: ${srv}
imgfetch --name stage2 tftp://${srv}/boot.ipxe || goto fail
imgverify stage2 tftp://${srv}/boot.ipxe.sig || goto fail
imgexec stage2 || goto fail
:fail
echo Verified boot FAILED. Refusing to run anything unsigned.
shell
EOF
}

# Self-validation: the CA's SHA-256 fingerprint should appear inside the EFI binary
check_ca_embedded() {
  local bin=$1 ca=$2 fp
  fp=$(ca_fpr_hex "$ca") || return 1
  write_libs
  if "$PYTHON" "$LIB/findbytes.py" "$bin" "$fp"; then
    ok "Trust anchor found inside $(basename "$bin")"
  elif [[ ${3:-} == strict ]]; then
    err "$(basename "$bin") does not contain your certificate."
    return 1
  else
    warn "Could not confirm the trust anchor inside $(basename "$bin"). If it is missing, every boot will fail closed at imgverify."
  fi
}

# =============================================================================
# On-phone cross-compiler: a small Debian environment (proot-distro) holds an
# x86_64 compiler that runs on the phone's arm64 CPU. Everything stays on this
# device. The guest can only see the iPXE source folder, never your keys.
# =============================================================================
xbox_exec() {   # xbox_exec BINDDIR command args...
  local bind=$1; shift
  proot-distro login "$XBOX_NAME" --shared-tmp --bind "$bind:$bind" -- "$@"
}

xbox_ready() {
  command -v proot-distro >/dev/null 2>&1 || return 1
  mkdir -p "$SRC_DIR"
  xbox_exec "$SRC_DIR" x86_64-linux-gnu-gcc -dumpmachine 2>/dev/null | grep -q '^x86_64-linux-gnu'
}

xbox_setup() {
  (( IS_TERMUX )) || die "$E_ENV" "This helper is for Termux on a phone. On a normal Linux computer just run: $0 build-ipxe"
  [[ $TARGET_ARCH == x86_64 ]] || die "$E_USAGE" "The on-phone compiler is for x86_64 PCs. An arm64 PC can be built natively on this phone."
  info "Setting up a small Debian environment with an x86_64 compiler (about 600 MB, 5-15 minutes)"
  command -v proot-distro >/dev/null 2>&1 || pkg install -y proot-distro || die "$E_ENV" "Could not install proot-distro. Try: pkg install proot-distro"
  if ! proot-distro login "$XBOX_NAME" -- true >/dev/null 2>&1; then
    proot-distro install "$XBOX_NAME" || die "$E_NET" "Could not download the Debian environment. Check your internet and run this again; it resumes."
  fi
  mkdir -p "$SRC_DIR"
  xbox_exec "$SRC_DIR" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update &&
    apt-get install -y --no-install-recommends build-essential make perl git liblzma-dev binutils-x86-64-linux-gnu &&
    { apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu ||
      { v=$(apt-cache search --names-only "^gcc-[0-9]+-x86-64-linux-gnu$" | sort -V | tail -n1 | cut -d" " -f1) &&
        [ -n "$v" ] && apt-get install -y --no-install-recommends "$v" &&
        ln -sf "x86_64-linux-gnu-gcc-${v#gcc-}" /usr/local/bin/x86_64-linux-gnu-gcc; }; }
  ' || die "$E_ENV" "Installing the compiler inside the Debian environment failed. Run the same command again."
  xbox_ready || die "$E_ENV" "The Debian environment is installed but the x86_64 compiler does not answer. Run: $0 ipxe-phone"
  ok "The on-phone x86_64 compiler is ready"
}

build_ipxe() {
  need git; need make; need perl
  [[ -n $PYTHON ]] || die "python3 is required. Run: $0 deps"
  [[ ${#IPXE_COMMIT} -eq 40 ]] || die "IPXE_COMMIT must be a full 40-character commit hash"

  local ca=${TRUST_CA:-$ATTEST/ca.crt}
  if [[ $VERIFIED_BOOT == 1 ]]; then
    [[ -s $ca ]] || die "No CA at $ca. Run: $0 attest-init (or set TRUST_CA when building on another machine)"
  fi

  # Native builds only, unless a cross compiler prefix is given
  local native=0
  case "$HOST_ARCH:$TARGET_ARCH" in
    x86_64:x86_64|aarch64:arm64|arm64:arm64) native=1 ;;
  esac
  local xin="" ca_use="" embed_use=""
  local -a runner=()
  if (( ! native )) && [[ -z $IPXE_CROSS ]]; then
    if [[ $TARGET_ARCH == x86_64 ]] && have_cross_gcc; then
      IPXE_CROSS=x86_64-linux-gnu-
      info "Using the x86_64 cross-compiler found on this system"
    elif (( IS_TERMUX )) && [[ $TARGET_ARCH == x86_64 ]] && xbox_ready; then
      IPXE_CROSS=x86_64-linux-gnu-
      xin="$SRC_DIR/xin"
      runner=(xbox_exec "$SRC_DIR")
      info "Cross-compiling for $TARGET_ARCH inside the on-phone Debian environment (everything stays on this device)"
    elif (( IS_TERMUX )) && [[ $TARGET_ARCH == x86_64 ]]; then
      die "$E_ENV" "This phone is $HOST_ARCH and the PC is $TARGET_ARCH. Set up the on-phone compiler once with: $0 ipxe-phone"
    else
      die "$E_ENV" "This device is $HOST_ARCH and the target is $TARGET_ARCH, so it cannot compile the loader. Build it on a $TARGET_ARCH Linux computer you control and copy it back with: $0 import-ipxe DIR (the guide shows the steps)."
    fi
  fi

  git_pin_opts
  local -a gopt=("${GIT_PIN_OPTS[@]+"${GIT_PIN_OPTS[@]}"}")

  local src="$SRC_DIR/ipxe"
  mkdir -p "$SRC_DIR"
  if [[ ! -d $src/.git ]]; then
    info "Cloning iPXE (pinned TLS)"
    git "${gopt[@]+"${gopt[@]}"}" clone --quiet "$IPXE_REPO" "$src" || die "Clone failed (pin mismatch or network error)"
  fi
  git "${gopt[@]+"${gopt[@]}"}" -C "$src" fetch --quiet origin || die "Fetch failed"
  git -C "$src" checkout --quiet --detach "$IPXE_COMMIT" || die "Commit $IPXE_COMMIT not found"
  local head
  head=$(git -C "$src" rev-parse HEAD)
  [[ $head == "$IPXE_COMMIT" ]] || die "Checkout landed on $head, not $IPXE_COMMIT"
  ok "iPXE source at $head ($(git -C "$src" log -1 --format='%cd %an: %s' --date=short))"

  mkdir -p "$src/src/config/local"
  printf '/* netboot-android */\n#define IMAGE_TRUST_CMD\n#define DOWNLOAD_PROTO_HTTP\n' > "$src/src/config/local/general.h"

  local fb=$FALLBACK_SERVER
  if [[ -z $fb ]]; then
    fb=$( (resolve_network >/dev/null 2>&1 && printf '%s' "$PHONE_IP") || true )
  fi
  local embed="$STATE/embed.ipxe"
  mkdir -p "$STATE"

  local -a mopts=()
  if [[ $VERIFIED_BOOT == 1 ]]; then
    write_embed_script "$embed" "$fb"
    ca_use=$ca; embed_use=$embed
    if [[ -n $xin ]]; then   # the guest sees only $SRC_DIR, so stage the two public inputs there
      mkdir -p "$xin"; cp -f "$ca" "$xin/ca.crt"; cp -f "$embed" "$xin/embed.ipxe"
      ca_use="$xin/ca.crt"; embed_use="$xin/embed.ipxe"
    fi
    mopts=(TRUST="$ca_use" EMBED="$embed_use")
    info "Embedded script fallback server: ${fb:-none (uses DHCP next-server)}"
  fi
  [[ -n $IPXE_CROSS ]] && mopts+=(CROSS="$IPXE_CROSS")
  local cc=$IPXE_CC
  if [[ -z $cc ]]; then
    if command -v gcc >/dev/null 2>&1; then cc=gcc; else cc=clang; fi
  fi
  [[ -z $IPXE_CROSS ]] && mopts+=(CC="$cc")

  local -a targets
  if [[ $TARGET_ARCH == x86_64 ]]; then
    targets=(bin-x86_64-efi/ipxe.efi bin/undionly.kpxe)
  else
    targets=(bin-arm64-efi/ipxe.efi)
  fi

  info "Building ${targets[*]} (several minutes)"
  "${runner[@]+"${runner[@]}"}" make -C "$src/src" clean >/dev/null 2>&1 || true
  "${runner[@]+"${runner[@]}"}" make -C "$src/src" -j"$(nproc_n)" "${mopts[@]}" "${targets[@]}" \
    || die "iPXE build failed. See the messages above. If you are on a phone, run: $0 ipxe-phone to repair the compiler setup, or import a loader built on a computer you control."

  mkdir -p "$TFTP"
  if [[ $TARGET_ARCH == x86_64 ]]; then
    cp "$src/src/bin-x86_64-efi/ipxe.efi" "$TFTP/ipxe.efi"
    cp "$src/src/bin/undionly.kpxe" "$TFTP/undionly.kpxe"
  else
    cp "$src/src/bin-arm64-efi/ipxe.efi" "$TFTP/ipxe-arm64.efi"
  fi

  local efi
  efi="$TFTP/$(ipxe_files_for_arch | head -n1)"
  [[ $VERIFIED_BOOT == 1 ]] && check_ca_embedded "$efi" "$ca"

  {
    echo "commit=$head"
    echo "built=$(now_iso)"
    echo "host=$(uname -srm)"
    echo "verified_boot=$VERIFIED_BOOT"
    [[ $VERIFIED_BOOT == 1 ]] && echo "ca_sha256=$(ca_fpr_hex "$ca")"
    echo "fallback_server=${fb:-none}"
    local f
    for f in $(ipxe_files_for_arch); do echo "file=$f sha256=$(sha256_of "$TFTP/$f")"; done
  } > "$IPXE_BUILT"
  ok "iPXE installed to $TFTP (record: $IPXE_BUILT)"
}

# =============================================================================
# iPXE built in the cloud (for a phone whose CPU differs from the PC's)
# =============================================================================
upstream_slug() {   # https://github.com/Owner/Repo.git -> Owner/Repo
  local u=${UPSTREAM_REPO%.git}
  printf '%s' "${u#*github.com/}"
}

loader_pin_path() { printf '%s/loader-%s.pin' "$STATE" "$TARGET_ARCH"; }
pin_get() { sed -n "s/^$1=//p" "$(loader_pin_path)" 2>/dev/null | head -n1; }
curl_api() { # curl_api URL  (JSON from GitHub; honours IPXE_CURL_OPTS so tests can use a local server)
  # shellcheck disable=SC2086
  curl -fsS $IPXE_CURL_OPTS --connect-timeout 20 --max-time 60 -H 'Accept: application/vnd.github+json' "$1"
}
json_get() { "$PYTHON" -I -c '
import json, sys
d = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    d = d[int(part)] if isinstance(d, list) else d.get(part, "")
print(d if d is not None else "")
' "$1"; }

ipxe_request() {
  [[ -s $ATTEST/ca.crt ]] || die "$E_ENV" "Your boot certificate does not exist yet. Run the guide first (it creates your keys)."
  local b64 slug fp url
  b64=$(base64 < "$ATTEST/ca.crt" | tr -d '\n')
  slug=$(upstream_slug)
  fp=$(openssl x509 -in "$ATTEST/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)
  url="https://github.com/$slug/actions/workflows/build-ipxe.yml"
  printf '%s\n' "$b64" | atomic_write "$HOME/ipxe-request.txt"
  local copied=0
  if command -v termux-clipboard-set >/dev/null 2>&1 && printf '%s' "$b64" | termux-clipboard-set 2>/dev/null; then copied=1; fi
  echo
  box \
    "ONE-TIME LOADER BUILD ON GITHUB (about 5 minutes)" \
    "" \
    "1. Open the page below and sign in to GitHub." \
    "2. Tap 'Run workflow'." \
    "3. In the first box, paste the certificate text" \
    "   $( ((copied)) && echo "(already copied for you)" || echo "(saved in ~/ipxe-request.txt)" )" \
    "4. Choose the PC's CPU (x86_64 for most PCs) and tap 'Run workflow'." \
    "5. When the run turns green, come back here."
  echo
  say "${C_BOLD}The page:${C_RESET}"
  say "$url"
  echo
  hint "No 'Run workflow' button? GitHub only shows it for workflows on your default branch: merge this branch to main first."
  hint "The text is only your PUBLIC certificate. Your private key never leaves this device."
  hint "Certificate fingerprint: ${fp:0:47}..."
  if (( ! copied )); then
    echo
    say "The certificate text (long line):"
    printf '%s\n' "$b64"
  fi
}

# Does GitHub's signed provenance say these files came from this repo's build workflow?
# Result in LOADER_ATTEST: yes | no (verification ran and FAILED) | skipped (gh missing or not logged in)
LOADER_ATTEST="skipped"
loader_attest() {   # loader_attest DIR
  local dir=$1 slug f
  LOADER_ATTEST="skipped"
  command -v gh >/dev/null 2>&1 || return 0
  gh auth status >/dev/null 2>&1 || return 0
  slug=$(upstream_slug)
  for f in "$dir"/*.efi "$dir"/*.kpxe; do
    [[ -f $f ]] || continue
    if ! gh attestation verify "$f" --repo "$slug" --signer-workflow "$slug/.github/workflows/build-ipxe.yml" >/dev/null 2>&1; then
      LOADER_ATTEST="no"; return 0
    fi
  done
  LOADER_ATTEST="yes"
}

loader_pin_matches() {   # the files in TFTP are exactly the ones you approved
  local pin line name want
  pin=$(loader_pin_path)
  [[ -s $pin ]] || return 1
  gpg_verify_file "$pin" || return 1
  while IFS= read -r line; do
    [[ $line == file=* ]] || continue
    name=${line#file=}; name=${name%% *}; want=${line##*sha256=}
    [[ -s $TFTP/$name && $(sha256_of "$TFTP/$name") == "$want" ]] || return 1
  done < "$pin"
  return 0
}

ipxe_fetch() {
  need curl
  [[ -n $PYTHON ]] || die "$E_ENV" "python3 is required. Run: $0 deps"
  local mode=${1:-} slug tag lines name url dir f json pinned=0 relurl commit wfhash body fp
  slug=$(upstream_slug)
  mkdir -p "$STATE" "$DL"

  if [[ -s $(loader_pin_path) && $mode != new ]]; then
    gpg_verify_file "$(loader_pin_path)" || die "$E_INTEGRITY" "The saved loader approval failed its signature check. Not trusting it."
    pinned=1; tag=$(pin_get tag)
    info "Restoring the exact loader you approved ($tag)"
    relurl="$GITHUB_API_BASE/repos/$slug/releases/tags/$tag"
    json=$(curl_api "$relurl") || die "$E_NET" "Could not reach GitHub, or that build no longer exists. Check your internet."
  else
    if [[ $mode == new && -s $(loader_pin_path) ]]; then
      ask_yn "Replace the loader you approved earlier with a newer build?" n || { info "Kept the approved loader."; return 0; }
    fi
    info "Looking for a loader built for your certificate"
    json=$(curl_api "$GITHUB_API_BASE/repos/$slug/releases?per_page=30") \
      || die "$E_NET" "Could not reach GitHub. Check your internet and try again."
    fp=$(openssl x509 -in "$ATTEST/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)
    tag=$("$PYTHON" -I -c '
import json, sys
arch, want = sys.argv[1], sys.argv[2]
for rel in json.load(sys.stdin):
    t = rel.get("tag_name", "")
    if t.startswith("ipxe-" + arch + "-") and not rel.get("draft") and want in (rel.get("name") or ""):
        print(t); break
' "$TARGET_ARCH" "$fp" <<<"$json")
    if [[ -z $tag ]]; then
      err "No loader for THIS certificate and CPU ($TARGET_ARCH) has been built yet."
      next_step "run '$0 ipxe-request', follow the steps, wait for the green check, then run '$0 ipxe-fetch'."
      return 1
    fi
    json=$(curl_api "$GITHUB_API_BASE/repos/$slug/releases/tags/$tag") || die "$E_NET" "Could not read build $tag."
  fi
  ok "Using build $tag"

  lines=$("$PYTHON" -I -c '
import json, sys
for a in json.load(sys.stdin).get("assets", []):
    print(a["name"], a["browser_download_url"])
' <<<"$json")
  dir=$(mktemp -d "$DL/ipxe-cloud.XXXXXX")
  while read -r name url; do
    case "$name" in ipxe.efi|undionly.kpxe|ipxe-arm64.efi|SHA256SUMS) ;; *) continue ;; esac
    # shellcheck disable=SC2086
    curl -fsSL $IPXE_CURL_OPTS --connect-timeout 20 --max-time 600 -o "$dir/$name" "$url" \
      || { rm -rf "$dir"; die "$E_NET" "Download of $name failed. Try again."; }
  done <<<"$lines"
  [[ -s $dir/SHA256SUMS ]] || { rm -rf "$dir"; die "$E_INTEGRITY" "The build has no checksum list. Not using it."; }
  ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || { rm -rf "$dir"; die "$E_INTEGRITY" "Downloaded files do not match their checksums. Not using them."; }
  ok "Checksums match"
  f=$(ipxe_files_for_arch | head -n1)

  if (( pinned )); then
    # exactly the bytes you approved, or nothing
    while IFS= read -r line; do
      [[ $line == file=* ]] || continue
      name=${line#file=}; name=${name%% *}; want=${line##*sha256=}
      [[ -s $dir/$name && $(sha256_of "$dir/$name") == "$want" ]] \
        || { rm -rf "$dir"; die "$E_INTEGRITY" "$name is NOT the file you approved. The release was changed. Refusing to use it."; }
    done < "$(loader_pin_path)"
    ok "Matches the loader you approved"
  else
    # 1. the build must have run exactly the reviewed workflow file
    body=$(printf '%s' "$json" | json_get body)
    wfhash=$(sed -n 's/^workflow-sha256: *//p' <<<"$body" | head -n1)
    [[ $wfhash == "$WORKFLOW_SHA256" ]] \
      || { rm -rf "$dir"; die "$E_INTEGRITY" "This build did not run the reviewed workflow (hash mismatch). Not using it."; }
    commit=$(curl_api "$GITHUB_API_BASE/repos/$slug/git/ref/tags/$tag" | json_get object.sha) \
      || { rm -rf "$dir"; die "$E_NET" "Could not read which commit built $tag."; }
    # shellcheck disable=SC2086
    [[ $(curl -fsSL $IPXE_CURL_OPTS --connect-timeout 20 --max-time 60 "$GITHUB_RAW_BASE/$slug/$commit/.github/workflows/build-ipxe.yml" | sha256sum | cut -d' ' -f1) == "$WORKFLOW_SHA256" ]] \
      || { rm -rf "$dir"; die "$E_INTEGRITY" "The workflow file at commit ${commit:0:10} is not the reviewed one. Not using this build."; }
    ok "Built by the reviewed workflow (commit ${commit:0:10})"
    # 2. the loader must contain YOUR certificate
    check_ca_embedded "$dir/$f" "$ATTEST/ca.crt" strict \
      || { rm -rf "$dir"; die "$E_INTEGRITY" "The loader does not contain YOUR certificate, so it was refused. Run ipxe-request again and paste the right certificate."; }
    # 3. GitHub's signed provenance, when the GitHub CLI is set up
    loader_attest "$dir"
    case $LOADER_ATTEST in
      yes) ok "GitHub's signed build provenance verified" ;;
      no)
        if [[ $IPXE_ALLOW_UNATTESTED != 1 ]]; then
          rm -rf "$dir"; die "$E_INTEGRITY" "GitHub's signed provenance does NOT match these files. They were not built by the workflow. Refusing."
        fi
        warn "Provenance check failed but IPXE_ALLOW_UNATTESTED=1 is set." ;;
      *) warn "Build provenance was NOT checked (GitHub CLI missing or not logged in)."
         hint "Stronger: pkg install gh && gh auth login, then run ipxe-fetch again." ;;
    esac
    echo
    box \
      "APPROVE THIS LOADER (one time)" \
      "" \
      "Build : $tag" \
      "Commit: ${commit:0:40}" \
      "Cert  : yours (checked inside the file)" \
      "Proof : provenance $LOADER_ATTEST (yes = verified, skipped = not checked)" \
      "" \
      "Once approved, this exact file is pinned. From now on the script" \
      "only ever restores THIS file and refuses any different one."
    echo
    if [[ $ASSUME_YES == 1 && $IPXE_CLOUD_OK != 1 ]]; then
      rm -rf "$dir"; die "$E_USAGE" "Approval needs a human. Run it yourself, or set IPXE_CLOUD_OK=1 knowingly."
    fi
    ask_yn "Approve and pin this loader?" "$([[ $LOADER_ATTEST == yes ]] && echo y || echo n)" \
      || { rm -rf "$dir"; info "Not approved. Nothing was installed."; return 1; }
  fi

  # the files verified above are the ones installed
  ( IMPORT_KEEP_PIN=1; import_ipxe "$dir" ) || { rm -rf "$dir"; die "$E_INTEGRITY" "Import refused the files."; }
  { echo "source=cloud:$tag"; echo "fetched=$(now_iso)"; } >> "$IPXE_BUILT"
  if (( ! pinned )); then
    {
      echo "tag=$tag"; echo "arch=$TARGET_ARCH"; echo "workflow_sha256=$WORKFLOW_SHA256"
      echo "commit=$commit"; echo "attested=$LOADER_ATTEST"; echo "approved=$(now_iso)"
      for name in $(ipxe_files_for_arch); do echo "file=$name sha256=$(sha256_of "$TFTP/$name")"; done
    } | atomic_write "$(loader_pin_path)"
    rm -f "$(loader_pin_path).asc"
    gpg_sign_file "$(loader_pin_path)" || warn "Could not sign the approval record (attestation key missing?)."
    ok "Approved and pinned. This is now the only cloud loader the script will use."
  fi
  rm -rf "$dir"
  ok "Loader installed ($f)."
}

ipxe_cloud() {   # one-time GitHub build, then pinned forever
  if [[ -s $(loader_pin_path) ]]; then
    ok "You already approved a GitHub-built loader. Restoring exactly that one."
    ipxe_fetch; return
  fi
  echo
  box \
    "ONE-TIME GITHUB BUILD: WHAT IS CHECKED, WHAT IS NOT" \
    "" \
    "Checked: the build ran the exact workflow file you can read in" \
    "your repo (hash pinned in this script), the loader contains YOUR" \
    "certificate, checksums match, and (with the GitHub CLI set up)" \
    "GitHub's signed provenance matches. Then that one file is pinned." \
    "" \
    "Still trusted: GitHub's build servers for that single run." \
    "A loader built on a computer you control avoids even that."
  echo
  ask_yn "Do the one-time GitHub build?" y || { info "OK. Other routes: $0 ipxe-phone, or build on a computer you control."; return 0; }
  ipxe_request
  local a
  while :; do
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Press Enter once the run is green (or type s to skip, q to quit): " a || a=s
    case "${a,,}" in
      q) exit 0 ;;
      s) warn "Skipped. Later: $0 ipxe-fetch"; return 0 ;;
    esac
    if ( ipxe_fetch ); then return 0; fi
    warn "Not ready yet. A run takes about 5 minutes; check the Actions page, then press Enter again."
  done
}

import_ipxe() {
  local dir=${1:-}
  [[ -n $dir && -d $dir ]] || die "Usage: $0 import-ipxe DIR   (DIR holds ipxe.efi / undionly.kpxe / ipxe-arm64.efi)"
  mkdir -p "$TFTP" "$STATE"
  local f n=0
  for f in $(ipxe_files_for_arch); do
    if [[ -s $dir/$f ]]; then
      head -c 2 "$dir/$f" | grep -q 'MZ' || [[ $f == *.kpxe ]] || die "$f is not a PE/EFI binary"
      cp "$dir/$f" "$TFTP/$f"
      n=$((n+1))
      ok "Imported $f ($(sha256_of "$TFTP/$f"))"
    else
      warn "Missing $dir/$f"
    fi
  done
  (( n )) || die "No iPXE binaries found in $dir"

  if [[ $VERIFIED_BOOT == 1 ]]; then
    [[ -s $ATTEST/ca.crt ]] || die "Run: $0 attest-init first"
    check_ca_embedded "$TFTP/$(ipxe_files_for_arch | head -n1)" "$ATTEST/ca.crt"
  else
    warn "VERIFIED_BOOT=0: imported binaries are trusted as-is"
  fi
  if [[ ${IMPORT_KEEP_PIN:-0} != 1 && -s $(loader_pin_path) ]]; then
    rm -f "$(loader_pin_path)" "$(loader_pin_path).asc"
    info "Your earlier GitHub-loader approval was cleared because you imported a different loader."
  fi
  {
    echo "commit=imported"
    echo "source_dir=$dir"
    echo "imported=$(now_iso)"
    echo "verified_boot=$VERIFIED_BOOT"
    [[ $VERIFIED_BOOT == 1 ]] && echo "ca_sha256=$(ca_fpr_hex)"
    for f in $(ipxe_files_for_arch); do
      [[ -s $TFTP/$f ]] && echo "file=$f sha256=$(sha256_of "$TFTP/$f")"
    done
  } > "$IPXE_BUILT"
}

# =============================================================================
# Fetch and verify the ISO
# =============================================================================
# =============================================================================
# Ubuntu's own signed boot files (shim + grub). No compiling, works with Secure Boot on or off.
# The PC's firmware verifies shim (Microsoft-signed), shim verifies grub and the kernel (Canonical-signed).
# =============================================================================
ubuntu_suite() { case $DISTRO in ubuntu) echo resolute ;; ubuntu24) echo noble ;; *) return 1 ;; esac; }

# Verifies a clearsigned InRelease against Ubuntu's archive keys; prints the signed text to OUT
archive_release_verify() {   # archive_release_verify HOMEDIR INRELEASE OUT
  local home=$1 in=$2 out=$3 st fpr ok=0
  st=$(mktemp)
  gpg --homedir "$home" --batch --no-tty --yes --status-file "$st" --output "$out" --decrypt "$in" >/dev/null 2>&1 || true
  if ! grep -qE '^\[GNUPG:\] (BADSIG|EXPKEYSIG|REVKEYSIG|ERRSIG) ' "$st"; then
    for fpr in $UBUNTU_ARCHIVE_FPRS; do
      if awk -v f="$fpr" '$2=="VALIDSIG" && $NF==f {found=1} END{exit !found}' "$st"; then ok=1; fi
    done
  fi
  rm -f "$st"
  (( ok )) && [[ -s $out ]]
}

# hash of FILE as listed in a verified Release text (SHA256 section)
release_hash() {   # release_hash RELEASE_TEXT PATH
  awk -v want="$2" '
    /^SHA256:/ {in256=1; next}
    /^[A-Za-z0-9-]+:/ {in256=0}
    in256 && $3==want {print $1; exit}' "$1"
}

# Prints "version filename sha256" of PKG in a Packages file
packages_entry() {   # packages_entry PACKAGES_FILE PKG
  awk -v pkg="$2" 'BEGIN{RS="";FS="\n"}
    { name=""; ver=""; fn=""; sum="";
      for(i=1;i<=NF;i++){ if($i ~ /^Package: /){name=substr($i,10)} else if($i ~ /^Version: /){ver=substr($i,10)}
                          else if($i ~ /^Filename: /){fn=substr($i,11)} else if($i ~ /^SHA256: /){sum=substr($i,9)} }
      if(name==pkg) print ver, fn, sum }' "$1"
}

shim_fetch() {
  shim_supported || die "$E_USAGE" "Ubuntu's signed boot files are available for Ubuntu on x86_64 PCs only."
  need gpg; need curl; need bsdtar; need xz; need sha256sum
  local suite work home keyf pkg pocket relf relt ph pf best ver fn sum debdir
  suite=$(ubuntu_suite)
  work=$(mktemp -d); chmod 700 "$work"; home="$work/gnupg"; mkdir -p "$home"; chmod 700 "$home"
  mkdir -p "$TFTP/grub" "$STATE"

  info "Getting Ubuntu's archive signing key from the ubuntu-keyring package"
  keyf="$work/archive-keyring.gpg"
  fetch_key_source "deb:$UBUNTU_ARCHIVE/pool/main/u/ubuntu-keyring/|ubuntu-keyring|usr/share/keyrings/ubuntu-archive-keyring.gpg" "$keyf" \
    || { rm -rf "$work"; die "$E_NET" "Could not get Ubuntu's archive keyring. Check your internet and run again."; }
  gpg --homedir "$home" --batch --no-tty --quiet --import "$keyf" 2>/dev/null || true
  local have=0 fpr
  for fpr in $UBUNTU_ARCHIVE_FPRS; do gpg --homedir "$home" --batch --list-keys "$fpr" >/dev/null 2>&1 && have=1; done
  (( have )) || { rm -rf "$work"; die "$E_INTEGRITY" "The keyring does not contain Ubuntu's archive signing keys. Refusing."; }

  declare -A got_ver=() got_fn=() got_sum=()
  for pkg in shim-signed grub-efi-amd64-signed; do got_ver[$pkg]=""; done
  for pocket in "$suite" "$suite-updates" "$suite-security"; do
    relf="$work/InRelease.$pocket"; relt="$work/Release.$pocket"
    vfetch "$UBUNTU_ARCHIVE/dists/$pocket/InRelease" "$relf" protected || { warn "Could not read $pocket; skipping it"; continue; }
    archive_release_verify "$home" "$relf" "$relt" \
      || { rm -rf "$work"; die "$E_INTEGRITY" "The signature on Ubuntu's $pocket release file did not verify. Refusing."; }
    ph="$work/Packages.$pocket.xz"
    vfetch "$UBUNTU_ARCHIVE/dists/$pocket/main/binary-amd64/Packages.xz" "$ph" protected || { warn "No package list for $pocket"; continue; }
    sum=$(release_hash "$relt" main/binary-amd64/Packages.xz)
    [[ -n $sum && $(sha256sum "$ph" | cut -d' ' -f1) == "$sum" ]] \
      || { rm -rf "$work"; die "$E_INTEGRITY" "The package list for $pocket does not match Ubuntu's signed release file. Refusing."; }
    pf="$work/Packages.$pocket"; xz -dc "$ph" > "$pf" || { rm -rf "$work"; die "$E_ENV" "Could not unpack the package list (is xz installed?)"; }
    for pkg in shim-signed grub-efi-amd64-signed; do
      best=$(packages_entry "$pf" "$pkg" | head -n1)
      [[ -n $best ]] || continue
      read -r ver fn sum <<<"$best"
      if [[ -z ${got_ver[$pkg]} || $(printf '%s\n%s\n' "${got_ver[$pkg]}" "$ver" | sort -V | tail -n1) == "$ver" ]]; then
        got_ver[$pkg]=$ver; got_fn[$pkg]=$fn; got_sum[$pkg]=$sum
      fi
    done
  done
  for pkg in shim-signed grub-efi-amd64-signed; do
    [[ -n ${got_ver[$pkg]} ]] || { rm -rf "$work"; die "$E_ENV" "Ubuntu's archive has no $pkg for $suite."; }
    ok "$pkg ${got_ver[$pkg]} (listed in Ubuntu's signed package list)"
  done

  debdir="$work/debs"; mkdir -p "$debdir"
  for pkg in shim-signed grub-efi-amd64-signed; do
    vfetch "$UBUNTU_ARCHIVE/${got_fn[$pkg]}" "$debdir/$pkg.deb" protected \
      || { rm -rf "$work"; die "$E_NET" "Download of $pkg failed. Try again."; }
    [[ $(sha256sum "$debdir/$pkg.deb" | cut -d' ' -f1) == "${got_sum[$pkg]}" ]] \
      || { rm -rf "$work"; die "$E_INTEGRITY" "$pkg does not match the checksum in Ubuntu's signed package list. Refusing."; }
  done
  ok "Both packages match Ubuntu's signed package list"

  deb_extract_member "$debdir/shim-signed.deb" usr/lib/shim/shimx64.efi.signed.latest "$work/shimx64.efi" \
    && deb_extract_member "$debdir/shim-signed.deb" usr/lib/shim/mmx64.efi "$work/mmx64.efi" \
    && deb_extract_member "$debdir/grub-efi-amd64-signed.deb" usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "$work/grubx64.efi" \
    || { rm -rf "$work"; die "$E_ENV" "Could not find the boot files inside the packages (Ubuntu may have changed the layout)."; }
  local f
  for f in shimx64.efi mmx64.efi grubx64.efi; do
    head -c 2 "$work/$f" | grep -q 'MZ' || { rm -rf "$work"; die "$E_INTEGRITY" "$f is not a UEFI program. Refusing."; }
  done
  for f in shimx64.efi mmx64.efi grubx64.efi; do sync_file "$work/$f"; mv -f "$work/$f" "$TFTP/$f"; done
  chmod a+r "$TFTP"/shimx64.efi "$TFTP"/mmx64.efi "$TFTP"/grubx64.efi
  {
    echo "suite=$suite"; echo "fetched=$(now_iso)"
    echo "shim-signed=${got_ver[shim-signed]}"; echo "grub-efi-amd64-signed=${got_ver[grub-efi-amd64-signed]}"
    for f in shimx64.efi mmx64.efi grubx64.efi; do echo "file=$f sha256=$(sha256_of "$TFTP/$f")"; done
  } | atomic_write "$STATE/shim-x86_64.built-from"
  rm -rf "$work"
  ok "Ubuntu's signed boot files are ready in $TFTP"
  hint "The PC's firmware checks shim (signed by Microsoft); shim checks grub and the kernel (signed by Canonical)."
}

shim_ready() { [[ -s $TFTP/shimx64.efi && -s $TFTP/grubx64.efi ]]; }

# grub reads this over TFTP. The kernel is signed by Canonical; Secure Boot refuses anything else.
write_grub_cfg() {
  local args; args=$(kernel_args)
  mkdir -p "$TFTP/grub"
  {
    echo "# netboot-android $SCRIPT_VERSION - generated $(now_iso)"
    echo "set default=0"
    echo "set timeout=3"
    echo "menuentry \"$P_LABEL (netboot-android)\" {"
    echo "  echo \"Loading the kernel from $PHONE_IP ...\""
    echo "  linux (http,$PHONE_IP:$HTTP_PORT)/$KERNEL_REL $args"
    echo "  echo \"Loading the initial RAM disk ...\""
    echo "  initrd (http,$PHONE_IP:$HTTP_PORT)/$INITRD_REL"
    echo "}"
  } | atomic_write "$TFTP/grub/grub.cfg"
}

# =============================================================================
# Reuse an earlier download instead of fetching it again
# =============================================================================
# Prints candidate files (complete images first), best first.
iso_candidates() {
  local d dirs=()
  [[ -n $ISO_FILE ]] && printf '%s\n' "$ISO_FILE"
  dirs=("$ROOT" "$DL" "$HOME" "$HOME/Download" "$HOME/Downloads" "$HOME/storage/downloads"
        "$HOME/storage/shared/Download" /sdcard/Download /storage/emulated/0/Download
        /data/data/com.termux/files/home/netboot /root/netboot "$PWD")
  local IFS=:; for d in $EXTRA_ISO_DIRS; do [[ -n $d ]] && dirs+=("$d"); done; unset IFS
  for d in "${dirs[@]}"; do
    [[ -d $d ]] || continue
    find "$d" -maxdepth 2 -type f \( -name "$ISO_NAME" -o -name "$ISO_NAME.part" \) 2>/dev/null || true
  done
}

# Puts an earlier download where fetch expects it. It is still fully verified afterwards;
# the original file is never modified or deleted.
adopt_existing_iso() {   # adopt_existing_iso REMOTE_BYTES
  local remote=${1:-0} cand size min norm
  [[ -s $ISO ]] && return 0
  min=$(( P_ISO_MB * 900000 ))         # about 90% of the expected size, when the server will not tell us
  norm=$(readlink -f "$ISO" 2>/dev/null || echo "$ISO")
  while IFS= read -r cand; do
    [[ -n $cand && -f $cand ]] || continue
    [[ $(readlink -f "$cand" 2>/dev/null || echo "$cand") == "$norm" || $cand == "$ISO.part" ]] && continue
    size=$(file_size "$cand")
    if [[ $cand == *.part ]]; then
      (( size > 1048576 )) || continue
      [[ -s $ISO.part ]] && continue
      if (( remote > 0 && size >= remote )); then continue; fi
      info "Found an unfinished download: $cand ($((size/1048576)) MB). Resuming from it."
      cp -f "$cand" "$ISO.part" || { rm -f "$ISO.part"; continue; }
      return 0
    fi
    if (( remote > 0 )); then
      (( size == remote )) || { info "Ignoring $cand: its size ($size) is not the expected $remote."; continue; }
    else
      (( size >= min )) || { info "Ignoring $cand: too small to be the full image."; continue; }
    fi
    info "Found an earlier download: $cand. Checking it instead of downloading again."
    if ln "$cand" "$ISO" 2>/dev/null; then :
    elif (( $(free_mb "$ROOT") > size / 1048576 + 256 )) && cp -f "$cand" "$ISO"; then :
    elif ln -sf "$(readlink -f "$cand")" "$ISO" 2>/dev/null; then
      warn "Not enough space for a second copy, so $ISO points at $cand. Keep that file in place."
    else
      continue
    fi
    return 0
  done <<<"$(iso_candidates)"
  return 1
}

iso_is_verified() {
  [[ -s $ISO && -s $ISO_VERIFIED ]] || return 1
  local size mtime
  read -r _ size mtime < "$ISO_VERIFIED" || return 1
  [[ $size == "$(file_size "$ISO")" && $mtime == "$(file_mtime "$ISO")" ]]
}

iso_verified_sha() { awk '{print $1}' "$ISO_VERIFIED"; }

verify_download() {
  local file=$1 orig=$2 list="" signed_list=0 iso_sig=0 hash_ok=0 sha256 algohash expect
  : > "$VERIFY_REC.tmp"
  record "TARGET distro=$DISTRO arch=$TARGET_ARCH url=$ISO_URL"

  if [[ -n $SUMS_URL || -n $ISO_SIG_URL ]]; then prepare_keyring; fi

  if [[ -n $SUMS_URL ]]; then
    vfetch "$SUMS_URL" "$SUMS_FILE" protected
    if [[ $SUMS_CLEARSIGNED == 1 ]]; then
      verify_clearsigned "$SUMS_FILE" "$SUMS_FILE.plain" "checksum list" || return 1
      list="$SUMS_FILE.plain"; signed_list=1
    elif [[ -n $SUMS_SIG_URL ]]; then
      vfetch "$SUMS_SIG_URL" "$SUMS_FILE.sig" protected
      verify_detached "$SUMS_FILE.sig" "$SUMS_FILE" "checksum list" || return 1
      list="$SUMS_FILE"; signed_list=1
    else
      list="$SUMS_FILE"
      info "Checksum list is unsigned; it is a secondary check behind the ISO signature"
    fi
  fi

  if [[ -n $ISO_SIG_URL ]]; then
    vfetch "$ISO_SIG_URL" "$ISO_SIG_FILE" protected
    info "Checking the ISO signature (reads the whole file)"
    verify_detached "$ISO_SIG_FILE" "$file" "ISO image" || return 30   # 30 = the image itself is bad
    iso_sig=1
  fi

  info "Hashing the ISO (one pass)"
  write_libs
  if [[ -n $PYTHON && $SUMS_ALGO == sha512 ]]; then
    local both; both=$("$PYTHON" "$LIB/hashfile.py" "$file" sha256,sha512)
    sha256=$(awk '$1=="sha256"{print $2}' <<<"$both"); algohash=$(awk '$1=="sha512"{print $2}' <<<"$both")
  else
    sha256=$(sha256_of "$file"); algohash=$sha256
    [[ -z $list || $SUMS_ALGO == sha256 ]] || algohash=$(sha512_of "$file")
  fi
  if [[ -n $list ]]; then
    expect=$(sums_lookup "$list" "$orig" "$SUMS_ALGO")
    if [[ -z $expect ]]; then
      err "$orig is not listed in the checksum file. The vendor may have published a newer release; set ISO_URL."
      return 1
    fi
    if [[ $algohash != "$expect" ]]; then
      err "$SUMS_ALGO MISMATCH for $orig (expected $expect, got $algohash)"
      return 30   # 30 = the image itself is bad
    fi
    ok "$SUMS_ALGO matches the published checksum"
    hash_ok=1
    record "HASH algo=$SUMS_ALGO value=$expect name=$orig signed_list=$signed_list"
  fi

  if (( (signed_list && hash_ok) || iso_sig )); then
    record "ISO sha256=$sha256 size=$(file_size "$file") name=$orig"
    printf '%s\n' "$sha256" > "$VERIFY_REC.sha"
    return 0
  fi
  err "No complete signature chain verified this ISO"
  return 1
}

fetch() {
  mkdir -p "$ROOT" "$DL" "$STATE"

  if iso_is_verified; then
    ok "ISO present and verified: $ISO"
    return 0
  fi
  if [[ -z $SUMS_URL && -z $ISO_SIG_URL && $ALLOW_UNVERIFIED != 1 ]]; then
    die "No checksum or signature source for $DISTRO. Set SUMS_URL or ISO_SIG_URL, or ALLOW_UNVERIFIED=1."
  fi

  local target code rc attempt=0 resumed=0 remote=0 have need_mb avail_mb vrc=0
  if [[ -n $ISO_FILE && ! -f $ISO_FILE ]]; then die "$E_USAGE" "--iso: no such file: $ISO_FILE"; fi
  # Cheap checks first: if the vendor key cannot be confirmed, say so now, not after 6 GB.
  if [[ -n $SUMS_URL || -n $ISO_SIG_URL ]]; then
    info "Checking the vendor signing key before the big download"
    prepare_keyring
  fi
  if [[ ! -s $ISO ]]; then
    remote=$(curl -sIL --proto-redir '=https' --connect-timeout 20 "$ISO_URL" 2>/dev/null \
             | awk 'tolower($1)=="content-length:" {gsub("\r","",$2); n=$2} END{print n+0}' || echo 0)
    adopt_existing_iso "$remote" || true
  fi
  if [[ -s $ISO ]]; then
    target=$ISO
    info "ISO present but not verified. Verifying now."
  else
    target="$ISO.part"
    [[ -s $ISO.part ]] && resumed=1
    have=$(file_size "$ISO.part" 2>/dev/null || echo 0)
    if (( remote > 0 )); then
      need_mb=$(( (remote - have) / 1048576 + 1 )); avail_mb=$(free_mb "$DL")
      if (( avail_mb < need_mb + 256 )); then
        die "$E_DISK" "Not enough space for the download: need about $need_mb MB more, only $avail_mb MB free."
      fi
    fi
    info "Downloading $ISO_NAME (about ${P_ISO_MB} MB). Resumable: re-run to continue."
    while :; do
      rc=0
      code=$(curl -L --proto-redir '=https' -C - --retry 5 --retry-delay 5 --connect-timeout 30 \
                  --speed-limit 10240 --speed-time 60 \
                  -# -o "$ISO.part" -w '%{http_code}' "$ISO_URL") || rc=$?
      if [[ $code == 416 ]]; then info "Download was already complete"; break; fi
      if (( rc == 0 )) && [[ $code =~ ^[23] ]]; then break; fi
      if (( rc == 0 )) && [[ $code =~ ^[45] ]]; then
        rm -f "$ISO.part"; die "$E_NET" "The server answered HTTP $code for $ISO_URL. The partial file was discarded."
      fi
      if (( rc == 33 )); then   # the server cannot resume: a stale partial file would never complete
        warn "This server does not support resuming. Discarding the partial file and starting over."
        rm -f "$ISO.part"; resumed=0
      fi
      attempt=$((attempt+1))
      (( attempt < 5 )) || die "$E_NET" "Download kept failing (curl error $rc). Your progress is saved; re-run fetch to resume."
      warn "Download interrupted (curl error $rc). Retrying in $((attempt*5))s (attempt $attempt of 5); progress is kept."
      sleep $((attempt*5))
    done
    if (( remote > 0 )) && [[ $(file_size "$ISO.part") != "$remote" ]]; then
      warn "Downloaded size $(file_size "$ISO.part") differs from the server's $remote; verification will decide."
    fi
    sync_file "$ISO.part"
  fi

  if [[ -z $SUMS_URL && -z $ISO_SIG_URL ]]; then
    [[ $target == "$ISO.part" ]] && mv -f "$ISO.part" "$ISO"
    rm -f "$ISO_VERIFIED"
    warn "ISO is UNVERIFIED (ALLOW_UNVERIFIED=1)"
    return 0
  fi

  ( verify_download "$target" "$ISO_NAME" ) || vrc=$?
  if (( vrc == 0 )); then
    [[ $target == "$ISO.part" ]] && mv -f "$ISO.part" "$ISO"
    mv -f "$VERIFY_REC.tmp" "$VERIFY_REC"
    printf '%s %s %s\n' "$(cat "$VERIFY_REC.sha")" "$(file_size "$ISO")" "$(file_mtime "$ISO")" > "$ISO_VERIFIED"
    rm -f "$VERIFY_REC.sha"
    ok "ISO verified: $ISO"
    return 0
  fi
  rm -f "$VERIFY_REC.tmp" "$VERIFY_REC.sha"
  if (( vrc == 30 )); then
    # the image does not match its signed checksum or signature: it really is bad
    rm -f "$ISO.part"; [[ $target == "$ISO" ]] && rm -f "$ISO" "$ISO_VERIFIED"
    if (( resumed )) && [[ ${FETCH_RETRIED:-0} != 1 ]]; then
      warn "A resumed download did not match its signed checksum (a stale partial file is the usual cause). Downloading again from scratch, once."
      FETCH_RETRIED=1; fetch; return
    fi
    die "$E_INTEGRITY" "The image does not match the vendor's signed checksum. It was discarded."
  fi
  # anything else (key lookup, network, checksum list): the download itself is fine, so KEEP it
  [[ $target == "$ISO.part" ]] && mv -f "$ISO.part" "$ISO"
  info "Your download is complete and was kept: $ISO ($(file_size "$ISO") bytes)"
  die "$E_NET" "The download is safe; only the verification step could not finish (see above). Fix the cause or try again later, then run fetch again. It will only re-verify, not download again."
}

# =============================================================================
# Extract boot files
# =============================================================================
pick_shortest() { awk '{ print length($0), $0 }' | sort -n | head -n1 | cut -d' ' -f2-; }

discover_layout() {
  local list=$1
  [[ -n $K ]] || K=$(grep -E '(^|/)(vmlinuz|vmlinuz-linux|loader/linux)$' <<<"$list" | pick_shortest || true)
  [[ -n $K ]] || K=$(grep -E '(^|/)vmlinuz[^/]*$' <<<"$list" | grep -viE 'efi|grub' | pick_shortest || true)
  [[ -n $I ]] || I=$(grep -E '(^|/)(initrd|initrd\.img|initramfs-linux\.img|sysresccd\.img|loader/initrd)$' <<<"$list" \
                     | grep -vi fallback | pick_shortest || true)
  if [[ $FAMILY != casper && -z $R ]]; then
    R=$(grep -E '(^|/)(filesystem\.squashfs|airootfs\.sfs|airootfs\.erofs|squashfs\.img)$' <<<"$list" | pick_shortest || true)
  fi
}

extract() {
  [[ -s $ISO ]] || die "ISO missing: $ISO. Run: $0 --distro $DISTRO --arch $TARGET_ARCH fetch"
  if ! iso_is_verified; then
    [[ $ALLOW_UNVERIFIED == 1 ]] || die "ISO is not verified. Run fetch again, or set ALLOW_UNVERIFIED=1."
    warn "Extracting from an UNVERIFIED ISO"
  fi
  need bsdtar

  info "Reading the ISO file table"
  local raw list dot=""
  raw=$(bsdtar -tf "$ISO") || die "Cannot read $ISO as an ISO image"
  [[ $(head -n1 <<<"$raw") == ./* ]] && dot="./"
  list=$(sed 's|^\./||' <<<"$raw")
  has() { grep -qxF "$1" <<<"$list"; }

  local K="" I="" R="" S="" B="" U=""
  has "$P_KERNEL" && K=$P_KERNEL
  has "$P_INITRD" && I=$P_INITRD
  if [[ -n $P_ROOTFS ]] && has "$P_ROOTFS"; then R=$P_ROOTFS; fi
  if [[ -z $K || -z $I || ( $FAMILY != casper && -z $R ) ]]; then
    warn "Preset paths not all found. The vendor may have changed its layout; discovering."
    discover_layout "$list"
  fi
  [[ -n $K ]] || die "No kernel found in the ISO. List it with: bsdtar -tf $ISO | less"
  [[ -n $I ]] || die "No initrd found in the ISO"
  [[ $FAMILY == casper || -n $R ]] || die "No root filesystem image found in the ISO"

  if [[ $FAMILY == archiso ]]; then
    B=${R%%/*}
    local cand="${R%/*}/airootfs.sha512"
    has "$cand" && S=$cand
    if [[ $INCLUDE_UCODE == 1 ]]; then
      local u
      for u in "$B/boot/intel-ucode.img" "$B/boot/amd-ucode.img" "$B/boot/intel_ucode.img" "$B/boot/amd_ucode.img"; do
        has "$u" && U+="$u "
      done
    fi
  fi
  U=${U% }

  ok "kernel  : $K"
  ok "initrd  : $I"
  [[ -n $R ]] && ok "rootfs  : $R"
  [[ -n $S ]] && ok "checksum: $S"
  [[ -n $U ]] && ok "ucode   : $U"

  local -a files=("$dot$K" "$dot$I")
  [[ -n $R ]] && files+=("$dot$R")
  [[ -n $S ]] && files+=("$dot$S")
  local u
  for u in $U; do files+=("$dot$u"); done

  info "Extracting (the root image can be several GB)"
  mkdir -p "$HTTP"
  local stage="$HTTP.new" need_mb avail_mb rel f
  rm -rf "$stage"; mkdir -p "$stage"
  need_mb=$(bsdtar -tvf "$ISO" 2>/dev/null | awk -v want="$(printf '%s\n' "${files[@]#./}")" '
      BEGIN{n=split(want,a,"\n"); for(i=1;i<=n;i++) w[a[i]]=1}
      { name=$NF; sub(/^\.\//,"",name); if (name in w) sum+=$5 } END{printf "%d", sum/1048576 + 1}' || echo 0)
  avail_mb=$(free_mb "$HTTP")
  if (( need_mb > 1 && avail_mb < need_mb + need_mb/20 + 64 )); then
    rm -rf "$stage"
    die "$E_DISK" "Not enough space to extract: need about $need_mb MB, only $avail_mb MB free. Nothing was changed."
  fi
  if ! bsdtar -xf "$ISO" -C "$stage" "${files[@]}"; then
    rm -rf "$stage"
    die "Extraction failed. Your previous boot files were not touched."
  fi
  for f in "${files[@]}"; do
    rel=${f#./}
    [[ -f $stage/$rel ]] || { rm -rf "$stage"; die "Extraction incomplete: $rel is missing. Your previous boot files were not touched."; }
  done
  # every file is complete: move each into place (renames are atomic; other distros' files stay)
  for f in "${files[@]}"; do
    rel=${f#./}
    mkdir -p "$HTTP/$(dirname "$rel")"
    sync_file "$stage/$rel"
    mv -f "$stage/$rel" "$HTTP/$rel"
  done
  rm -rf "$stage"

  local root_rel=$R
  if [[ $FAMILY == casper ]]; then
    # casper's url= downloads the whole ISO and loop-mounts it, so serve the ISO itself
    mkdir -p "$HTTP/iso"
    rm -f "$HTTP/iso/$ISO_NAME"
    ln -f "$ISO" "$HTTP/iso/$ISO_NAME" 2>/dev/null || ln -sf "$ISO" "$HTTP/iso/$ISO_NAME"
    root_rel="iso/$ISO_NAME"
    ok "Serving the ISO as iso/$ISO_NAME (client downloads it into RAM)"
  fi
  chmod -R a+rX "$HTTP"

  mkdir -p "$STATE"
  {
    printf 'KERNEL_REL=%q\n' "$K"
    printf 'INITRD_REL=%q\n' "$I"
    printf 'ROOTFS_REL=%q\n' "$root_rel"
    printf 'SHA_REL=%q\n' "$S"
    printf 'BASEDIR=%q\n' "$B"
    printf 'UCODE_RELS=%q\n' "$U"
  } | atomic_write "$LAYOUT"
  ok "Boot files ready in $HTTP"
}

load_layout() {
  [[ -f $LAYOUT ]] || die "Not extracted yet. Run: $0 --distro $DISTRO --arch $TARGET_ARCH extract"
  KERNEL_REL=""; INITRD_REL=""; ROOTFS_REL=""; SHA_REL=""; BASEDIR=""; UCODE_RELS=""
  # shellcheck disable=SC1090
  source "$LAYOUT"
}

# =============================================================================
# Configure: kernel args, signed boot script, dnsmasq
# =============================================================================
kernel_args() {
  local t
  case $FAMILY in
    casper)  t="ip=dhcp boot=casper netboot=url url=@BASE@/@ROOTFS@ cloud-config-url=/dev/null --- quiet splash" ;;
    live)    t="boot=live components fetch=@BASE@/@ROOTFS@ ip=dhcp quiet" ;;
    archiso) t="archisobasedir=@BASEDIR@ archiso_http_srv=@BASE@/ ip=dhcp"
             [[ -n $SHA_REL ]] && t+=" checksum=y"
             [[ -n $P_EXTRA_ARGS ]] && t+=" $P_EXTRA_ARGS" ;;
    dracut)  t="root=live:@BASE@/@ROOTFS@ rd.live.image rd.neednet=1 ip=dhcp quiet rhgb" ;;
    *) die "internal: unknown family $FAMILY" ;;
  esac
  t=${U_BOOT_ARGS:-$t}
  t=${t//@ROOTFS@/$ROOTFS_REL}
  t=${t//@BASEDIR@/$BASEDIR}
  t=${t//@ISO@/iso/$ISO_NAME}
  t=${t//@BASE@/$BASE_URL}
  printf '%s' "$t"
}

require_ipxe_matches_ca() {
  local f
  for f in $(ipxe_files_for_arch); do
    [[ -s $TFTP/$f ]] || die "Missing $f. Run: $0 build-ipxe (or import-ipxe DIR)"
  done
  [[ $VERIFIED_BOOT == 1 ]] || return 0
  [[ -s $IPXE_BUILT ]] || die "No iPXE build record. Run: $0 build-ipxe"
  local want have
  want=$(ca_fpr_hex) || die "No boot CA. Run: $0 attest-init"
  have=$(awk -F= '$1=="ca_sha256"{print $2}' "$IPXE_BUILT")
  [[ $have == "$want" ]] || die "iPXE was built with a different CA ($have). Rebuild: $0 build-ipxe"
}

configure() {
  resolve_network
  load_layout
  write_libs
  if [[ $BOOT_LOADER == shim ]]; then
    shim_supported || die "$E_USAGE" "Ubuntu's signed boot files work for Ubuntu on x86_64 only. Use the iPXE route for $DISTRO / $TARGET_ARCH."
    shim_ready || die "$E_ENV" "Ubuntu's signed boot files are missing. Run: $0 shim-fetch"
    VERIFIED_BOOT=0    # iPXE's own signature chain is not used; the firmware checks Ubuntu's signatures instead
  else
    require_ipxe_matches_ca
  fi
  if [[ $VERIFIED_BOOT == 1 ]]; then
    [[ -s $ATTEST/codesign.key ]] || die "Run: $0 attest-init"
  fi
  mkdir -p "$TFTP" "$HTTP" "$RUN"

  local args vb=$VERIFIED_BOOT
  args=$(kernel_args)

  info "Writing boot.ipxe ($DISTRO / $TARGET_ARCH, verified boot: $vb)"
  {
    echo '#!ipxe'
    echo "set base http://${PHONE_IP}:${HTTP_PORT}"
    echo "echo netboot-android: ${P_LABEL} (${TARGET_ARCH}) from \${base}"
    echo "echo This image needs about ${CLIENT_RAM_GB} GB of RAM on this PC."
    echo "kernel --name kernel \${base}/${KERNEL_REL} ${args} || goto fail"
    [[ $vb == 1 ]] && echo "imgverify kernel \${base}/${KERNEL_REL}.sig || goto fail"
    local n=0 u
    for u in $UCODE_RELS; do
      echo "initrd --name ucode${n} \${base}/${u} || goto fail"
      [[ $vb == 1 ]] && echo "imgverify ucode${n} \${base}/${u}.sig || goto fail"
      n=$((n+1))
    done
    echo "initrd --name initrd \${base}/${INITRD_REL} || goto fail"
    [[ $vb == 1 ]] && echo "imgverify initrd \${base}/${INITRD_REL}.sig || goto fail"
    echo "boot || goto fail"
    echo ":fail"
    echo "echo Boot failed, or a signature did not verify. Refusing to boot."
    echo "shell"
  } > "$TFTP/boot.ipxe"

  if [[ $vb == 1 ]]; then
    info "Signing boot files with the local code-signing certificate"
    cms_sign "$TFTP/boot.ipxe"
    cms_sign "$HTTP/$KERNEL_REL"
    cms_sign "$HTTP/$INITRD_REL"
    local u
    for u in $UCODE_RELS; do cms_sign "$HTTP/$u"; done
    ok "Signed: boot.ipxe, kernel, initrd${UCODE_RELS:+, microcode}"
  elif [[ $BOOT_LOADER == shim ]]; then
    info "Secure Boot route: Ubuntu's own signatures protect shim, grub and the kernel; nothing of yours needs signing"
  else
    warn "VERIFIED_BOOT=0: boot files are NOT signed and the client will not check them"
  fi
  [[ $BOOT_LOADER == shim ]] && write_grub_cfg

  # dnsmasq appends ".0" to pxe-service basenames that have no extension
  [[ -s $TFTP/undionly.kpxe ]] && cp -f "$TFTP/undionly.kpxe" "$TFTP/undionly.0"

  info "Writing dnsmasq.conf ($MODE mode on $IFACE, $NET/$PREFIX_LEN)"
  {
    echo "# netboot-android $SCRIPT_VERSION - generated $(now_iso)"
    echo "port=0"
    echo "interface=$IFACE"
    echo "bind-interfaces"
    echo "except-interface=lo"
    echo "log-dhcp"
    echo "log-facility=-"
    echo "user=root"
    echo "group=root"
    echo "pid-file=$RUN/dnsmasq.pid"
    echo "dhcp-leasefile=$RUN/dnsmasq.leases"
    echo "enable-tftp"
    echo "tftp-root=$TFTP"
    if [[ $MODE == proxy ]]; then
      echo "# Proxy-DHCP: the existing DHCP server keeps assigning addresses"
      echo "dhcp-range=$NET,proxy,$MASK"
    else
      direct_pool
      echo "# Direct mode: this host is the only DHCP server on the link"
      echo "dhcp-range=$POOL_START,$POOL_END,$MASK,1h"
      echo "dhcp-authoritative"
      echo "dhcp-option=3"
      echo "dhcp-option=6"
    fi
    echo "dhcp-userclass=set:ipxe,iPXE"
    echo "dhcp-match=set:efi64,option:client-arch,7"
    echo "dhcp-match=set:efi64,option:client-arch,9"
    echo "dhcp-match=set:arm64,option:client-arch,11"
    echo "pxe-prompt=\"netboot-android\",0"
    if [[ $BOOT_LOADER == shim ]]; then
      echo "pxe-service=tag:!ipxe,X86-64_EFI,\"netboot-android (UEFI, Secure Boot ok)\",shimx64.efi"
      echo "pxe-service=tag:!ipxe,BC_EFI,\"netboot-android (UEFI, Secure Boot ok)\",shimx64.efi"
    elif [[ $TARGET_ARCH == x86_64 ]]; then
      echo "pxe-service=tag:!ipxe,x86PC,\"netboot-android (BIOS)\",undionly"
      echo "pxe-service=tag:!ipxe,X86-64_EFI,\"netboot-android (UEFI)\",ipxe.efi"
      echo "pxe-service=tag:!ipxe,BC_EFI,\"netboot-android (UEFI)\",ipxe.efi"
    else
      echo "pxe-service=tag:!ipxe,ARM64_EFI,\"netboot-android (ARM64 UEFI)\",ipxe-arm64.efi"
    fi
    echo "# First match wins"
    echo "dhcp-boot=tag:ipxe,boot.ipxe"
    if [[ $BOOT_LOADER == shim ]]; then
      echo "dhcp-boot=tag:efi64,shimx64.efi"
    elif [[ $TARGET_ARCH == x86_64 ]]; then
      echo "dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi"
      echo "dhcp-boot=tag:!efi64,tag:!arm64,tag:!ipxe,undionly.kpxe"
    else
      echo "dhcp-boot=tag:arm64,tag:!ipxe,ipxe-arm64.efi"
    fi
  } > "$DNSMASQ_CONF"

  chmod -R a+rX "$TFTP" "$HTTP" 2>/dev/null || true
  chmod a+rx "$ROOT"

  info "Recording the integrity manifest (hashes every served file)"
  write_manifest
  {
    echo "configured=$(now_iso)"
    echo "iface=$IFACE mode=$MODE net=$NET/$PREFIX_LEN phone=$PHONE_IP port=$HTTP_PORT loader=$BOOT_LOADER"
    echo "args=$args"
  } > "$STATE/$DISTRO-$TARGET_ARCH.config"

  ok "Configured"
  info "Kernel arguments: $args"
  if (( IS_HOTSPOT )); then
    warn "$IFACE looks like this phone's hotspot. Android's own DHCP server may hold port 67, so dnsmasq may fail to start. A router Wi-Fi network or a direct Ethernet cable (--mode direct) is more reliable."
  fi
}

# =============================================================================
# Integrity manifest
# =============================================================================
manifest_files() {
  local f u
  echo "tftp/boot.ipxe"
  [[ $VERIFIED_BOOT == 1 ]] && echo "tftp/boot.ipxe.sig"
  for f in $(boot_files); do echo "tftp/$f"; done
  [[ $BOOT_LOADER == shim ]] && echo "tftp/grub/grub.cfg"
  [[ $BOOT_LOADER != shim && -s $TFTP/undionly.0 ]] && echo "tftp/undionly.0"
  echo "http/$KERNEL_REL"
  echo "http/$INITRD_REL"
  [[ -n $ROOTFS_REL ]] && echo "http/$ROOTFS_REL"
  [[ -n $SHA_REL ]] && echo "http/$SHA_REL"
  for u in $UCODE_RELS; do echo "http/$u"; done
  if [[ $VERIFIED_BOOT == 1 ]]; then
    echo "http/$KERNEL_REL.sig"
    echo "http/$INITRD_REL.sig"
    for u in $UCODE_RELS; do echo "http/$u.sig"; done
  fi
  echo "dnsmasq.conf"
  echo "lib/httpd.py"
}

fp_of() { stat -c '%s %Y %i %d' "$1" 2>/dev/null || echo "0 0 0 0"; }

# detached GPG signature with the local attestation key (same identity as self-sign)
gpg_sign_file() {
  [[ -n $(attest_fpr) ]] || return 0
  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --yes --local-user "$(attest_fpr)" \
      --armor --detach-sign --output "$1.asc" "$1" >/dev/null 2>&1
}
gpg_verify_file() {
  [[ -n $(attest_fpr) ]] || return 0
  [[ -s $1.asc ]] || return 1
  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --status-fd 1 --verify "$1.asc" "$1" 2>/dev/null \
    | awk -v f="$(attest_fpr)" '$2=="VALIDSIG" && $NF==f {ok=1} END{exit !ok}'
}

# Hashes every served file once. Big files whose size/mtime/inode/device are unchanged
# since a signed earlier run reuse that earlier hash instead of being read again.
write_manifest() {
  local rel f h tmp fpt sz fp a b c d e trust=0 reused=0 hashed=0
  declare -A oh=() ofp=()
  if [[ -f $MANIFEST && -f $MANIFEST.fp ]] && gpg_verify_file "$MANIFEST.fp"; then
    trust=1
    while read -r a b c; do oh[$c]=$a; done < "$MANIFEST"
    while read -r a b c d e; do ofp[$e]="$a $b $c $d"; done < "$MANIFEST.fp"
  fi
  tmp="$MANIFEST.tmp"; fpt="$MANIFEST.fp.tmp"
  : > "$tmp"; : > "$fpt"
  while IFS= read -r rel; do
    f="$ROOT/$rel"
    [[ -f $f ]] || die "Manifest: missing $rel"
    sz=$(file_size "$f"); fp=$(fp_of "$f")
    if [[ $FAMILY == casper && $rel == "http/$ROOTFS_REL" ]] && iso_is_verified; then
      h=$(iso_verified_sha)
    elif (( sz >= BIG_BYTES && trust )) && [[ ${ofp[$rel]:-} == "$fp" && -n ${oh[$rel]:-} ]]; then
      h=${oh[$rel]}; reused=$((reused+1))
    else
      h=$(sha256_of "$f"); hashed=$((hashed+1))
    fi
    printf '%s %s %s\n' "$h" "$sz" "$rel" >> "$tmp"
    printf '%s %s\n' "$fp" "$rel" >> "$fpt"
  done <<<"$(manifest_files)"
  sync_file "$tmp"; sync_file "$fpt"
  mv -f "$fpt" "$MANIFEST.fp"
  mv -f "$tmp" "$MANIFEST"
  rm -f "$MANIFEST.fp.asc"
  gpg_sign_file "$MANIFEST.fp" || warn "Could not sign the fingerprint list; big files will be fully re-hashed at serve time."
  (( reused == 0 )) || info "Reused hashes for $reused unchanged big file(s) instead of re-reading them"
  log_event INFO "manifest written hashed=$hashed reused=$reused"
}

# Tiered gate. Small files: always fully hashed. Big files: skipped when their signed
# fingerprint still matches (checked later in the background by deep_verify_bg).
BIG_FAST=()
verify_manifest() {
  [[ -f $MANIFEST ]] || die "No manifest. Run: $0 configure"
  local h s rel f cur bad=0 checked=0 fast=0 trust=0 a b c d e t0=$SECONDS mode=$DEEP_VERIFY
  declare -A ofp=()
  BIG_FAST=()
  if [[ $mode == auto ]]; then
    if [[ -f $MANIFEST.fp ]] && gpg_verify_file "$MANIFEST.fp"; then
      trust=1
      while read -r a b c d e; do ofp[$e]="$a $b $c $d"; done < "$MANIFEST.fp"
    else
      warn "No valid signed fingerprint list: every file will be fully re-hashed (slower)."
    fi
  fi
  info "Integrity gate: checking every served file (mode: $mode)"
  while read -r h s rel; do
    f="$ROOT/$rel"
    if [[ ! -f $f ]]; then err "MISSING: $rel"; bad=$((bad+1)); continue; fi
    if [[ $(file_size "$f") != "$s" ]]; then err "SIZE CHANGED: $rel"; bad=$((bad+1)); continue; fi
    if (( s >= BIG_BYTES && trust )) && [[ ${ofp[$rel]:-} == "$(fp_of "$f")" ]]; then
      BIG_FAST+=("$h $rel"); fast=$((fast+1)); checked=$((checked+1)); continue
    fi
    if [[ $mode == 0 ]] && (( s >= BIG_BYTES )); then checked=$((checked+1)); continue; fi
    cur=$(sha256_of "$f")
    if [[ $cur != "$h" ]]; then err "HASH MISMATCH: $rel"; bad=$((bad+1)); continue; fi
    checked=$((checked+1))
  done < "$MANIFEST"
  (( bad == 0 )) || die "$E_INTEGRITY" "Integrity gate FAILED ($bad file(s)). Refusing to serve. Re-run extract and configure."
  ok "Integrity gate passed ($checked files, $fast big file(s) by fingerprint, $((SECONDS-t0))s)"
}

# Runs niced in the background while serving; stops everything loudly on a mismatch.
DEEP_PID=""
deep_verify_bg() {
  local item h rel cur np=""
  command -v ionice >/dev/null 2>&1 && np="ionice -c3"
  for item in "${BIG_FAST[@]}"; do
    h=${item%% *}; rel=${item#* }
    cur=$($np nice -n 19 sha256sum "$ROOT/$rel" 2>/dev/null | awk '{print $1}')
    if [[ $cur != "$h" ]]; then
      printf '%s\n' "$rel" > "$RUN/DEEP_FAIL"
      err "BACKGROUND VERIFY FAILED for $rel: it changed on disk. Stopping the servers."
      kill_servers
      return 1
    fi
  done
  : > "$RUN/DEEP_OK"
  log_event INFO "background deep verify passed (${#BIG_FAST[@]} file(s))"
}

# =============================================================================
# Attestation reports
# =============================================================================
attest_report() {
  [[ -n $(attest_fpr) ]] || die "Run: $0 attest-init first"
  load_layout
  [[ -f $MANIFEST ]] || die "Run: $0 configure first"
  mkdir -p "$ATTEST/reports"

  local ts plain out h
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  plain="$ATTEST/reports/report-$ts.txt"
  out="$plain.asc"

  {
    echo "netboot-android attestation report"
    echo "version=$SCRIPT_VERSION"
    echo "generated=$(now_iso)"
    echo "host=$(uname -srm)"
    if (( IS_ANDROID )); then
      echo "android_model=$(getprop ro.product.model 2>/dev/null || echo unknown)"
      echo "android_build=$(getprop ro.build.fingerprint 2>/dev/null || echo unknown)"
    fi
    echo
    echo "[identity]"
    echo "script_sha256=$(sha256_of "$SELF")"
    if [[ -f $IPXE_BUILT ]]; then echo "loader_record=$(tr '\n' ' ' < "$IPXE_BUILT" | cut -c1-240)"; fi
    echo "script_signed_sha256=$(awk '{print $1}' "$ATTEST/script.sha256" 2>/dev/null || echo none)"
    echo "attest_key=$(attest_fpr)"
    echo "boot_ca_sha256=$(ca_fpr_hex 2>/dev/null || echo none)"
    if [[ -n $RELEASE_TIME ]]; then
      echo "release_time=$(epoch_to_iso "$RELEASE_TIME")"
      echo "release_code=$(release_code "$SELF" "$RELEASE_TIME" | awk '{print $2}')"
    else
      echo "release_time=none"
    fi
    echo
    echo "[target]"
    echo "distro=$DISTRO arch=$TARGET_ARCH family=$FAMILY label=\"$P_LABEL\""
    echo "vendor_key=$KEY_FPR"
    echo "iso_url=$ISO_URL"
    if iso_is_verified; then echo "iso_verified_sha256=$(iso_verified_sha)"; else echo "iso_verified=no"; fi
    echo
    echo "[vendor-verification]"
    if [[ -f $VERIFY_REC ]]; then cat "$VERIFY_REC"; else echo "none"; fi
    echo
    echo "[tls-pins]"
    echo "snapshot_date=$PIN_SNAPSHOT_DATE"
    for h in $(pin_hosts_for_target); do
      if [[ -s $PIN_DIR/$h ]]; then
        echo "pin host=$h source=refreshed keys=$(active_pins "$h" | grep -c . || true)"
      else
        echo "pin host=$h source=snapshot keys=$(active_pins "$h" | grep -c . || true)"
      fi
    done
    echo "last_audit:"
    tail -n 20 "$PIN_AUDIT" 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "[ipxe]"
    if [[ -f $IPXE_BUILT ]]; then cat "$IPXE_BUILT"; else echo "none"; fi
    echo
    echo "[boot]"
    cat "$STATE/$DISTRO-$TARGET_ARCH.config" 2>/dev/null || echo "not configured"
    echo "verified_boot=$VERIFIED_BOOT"
    echo
    echo "[files]"
    awk '{print "FILE", $1, $2, $3}' "$MANIFEST"
  } > "$plain"

  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --yes --local-user "$(attest_fpr)" \
      --clearsign --output "$out" "$plain" || die "Signing the report failed"
  rm -f "$plain"

  cp -f "$out" "$HTTP/attestation.txt.asc"
  cp -f "$ATTEST/attest-key.asc" "$HTTP/attest-key.asc"
  cp -f "$ATTEST/ca.crt" "$HTTP/attest-ca.crt" 2>/dev/null || true
  chmod a+r "$HTTP/attestation.txt.asc" "$HTTP/attest-key.asc" "$HTTP/attest-ca.crt" 2>/dev/null || true

  ok "Signed report: $out"
  info "Also published to clients at $BASE_URL/attestation.txt.asc" 2>/dev/null || true
}

verify_attest() {
  local file=${1:-}
  if [[ -z $file ]]; then
    file=$(ls -1t "$ATTEST"/reports/*.asc 2>/dev/null | head -n1 || true)
  fi
  [[ -n $file && -f $file ]] || die "No report found. Run: $0 attest"

  local st plain bad=0 n=0 tag h s rel cur
  st=$(mktemp); plain=$(mktemp)
  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --yes --status-file "$st" \
      --output "$plain" --decrypt "$file" >/dev/null 2>&1 || true
  if ! awk -v f="$(attest_fpr)" '$2=="VALIDSIG" && $NF==f {x=1} END{exit !x}' "$st"; then
    rm -f "$st" "$plain"
    die "Report signature INVALID or not made by this device's attestation key"
  fi
  ok "Report signature valid: $(basename "$file")"

  info "Re-hashing every file listed in the report"
  while read -r tag h s rel; do
    [[ $tag == FILE ]] || continue
    n=$((n+1))
    if [[ ! -f $ROOT/$rel ]]; then err "MISSING: $rel"; bad=$((bad+1)); continue; fi
    cur=$(sha256_of "$ROOT/$rel")
    if [[ $cur != "$h" ]]; then err "CHANGED: $rel"; bad=$((bad+1)); else ok "$rel"; fi
  done < "$plain"
  rm -f "$st" "$plain"
  (( bad == 0 )) || die "$bad of $n file(s) no longer match the attested state"
  ok "All $n files match the attested state"
}

# =============================================================================
# Backup and restore of the working folder
# =============================================================================
# Restorable point-in-time copy of $ROOT (keys, attestation, pins, state, TFTP
# files, configs). Rebuildable bulk (extracted http/, src/, run/) is skipped, and
# downloads/ only with BACKUP_DL=1. Each archive gets a SHA-256 sidecar.
backup_fingerprint() {
  local base; base=$(basename "$ROOT")
  [[ -d $ROOT ]] || return 0
  ( cd "$(dirname "$ROOT")" && find "$base" \
      \( -path "$base/http" -o -path "$base/run" -o -path "$base/src" \
         -o -path "$base/state/lock.d" -o -path "$base/state/undo.d" \) -prune -o \
      -type f ! -name '*.log' ! -name '*.log.*' ! -name '*.tmp' ! -name '*.part' ! -name 'last-serve' ! -name 'offsite.status' \
      -exec stat -c '%n %s %Y' {} + 2>/dev/null ) \
    | { if (( ${BACKUP_DL:-0} )); then cat; else grep -v "^$base/downloads/" ; fi; } \
    | grep -v "^$(basename "$BACKUP_DIR")/" | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}
BACKUP_FP_FILE="$BACKUP_DIR/.last-fingerprint"

backup_create() {
  local label=${1:-manual} base parent ts out
  need tar; need sha256sum
  [[ -d $ROOT ]] || die "Nothing to back up: $ROOT does not exist"
  base=$(basename "$ROOT"); parent=$(dirname "$ROOT")
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out="$BACKUP_DIR/netboot-$label-$ts.tar.gz"
  ( umask 077; mkdir -p "$BACKUP_DIR" ) || die "Cannot create $BACKUP_DIR"
  local ex=(--exclude="$base/http" --exclude="$base/run" --exclude="$base/src")
  (( BACKUP_DL )) || ex+=(--exclude="$base/downloads")
  case "$(readlink -f "$BACKUP_DIR")/" in "$(readlink -f "$ROOT")"/*) ex+=(--exclude="$base/${BACKUP_DIR#"$ROOT"/}") ;; esac
  info "Backing up $ROOT -> $out"
  if ! ( umask 077; tar -C "$parent" -czpf "$out.part" "${ex[@]}" "$base" ) 2>/dev/null; then
    rm -f "$out.part"
    die "Backup failed (unreadable files? run: sudo chown -R \$(id -u) $ROOT)."
  fi
  tar -tzf "$out.part" >/dev/null 2>&1 || { rm -f "$out.part"; die "Backup archive failed its read-back test"; }
  mv -f "$out.part" "$out"
  ( cd "$BACKUP_DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
  printf 'version=%s\ncreated=%s\ndistro=%s\narch=%s\nfiles=%s\n' "$SCRIPT_VERSION" "$(now_iso)" "$DISTRO" "$TARGET_ARCH" \
    "$(tar -tzf "$out" | grep -vc '/$' || true)" > "$out.meta"
  chmod 600 "$out" "$out.sha256" 2>/dev/null || true
  ok "Backup written: $out ($(file_size "$out") bytes)"
  backup_fingerprint > "$BACKUP_FP_FILE" 2>/dev/null || true
  backup_prune
  backup_upload "$out"
}

# Builds the unofficial Terabox CLI (fcr--/tbc) at a pinned commit. It talks only to
# www.terabox.com (checked in the source at that commit) and needs your ndus cookie.
terabox_install() {
  need git; need go
  local d="$SRC_DIR/tbc" rev
  mkdir -p "$SRC_DIR"
  [[ -d $d/.git ]] || git clone -q "$TBC_REPO" "$d" || die "Could not clone $TBC_REPO"
  git -C "$d" fetch -q origin "$TBC_COMMIT" 2>/dev/null || git -C "$d" fetch -q origin || true
  git -C "$d" checkout -q "$TBC_COMMIT" || die "Pinned commit $TBC_COMMIT not found"
  rev=$(git -C "$d" rev-parse HEAD)
  [[ $rev == "$TBC_COMMIT" ]] || die "Checked-out commit $rev does not match the pin"
  ( cd "$d" && go build -o "$SRC_DIR/tbc-bin" ./cmd/tbc ) || die "go build failed (needs Go 1.24 or newer)"
  ok "Terabox CLI built at ${TBC_COMMIT:0:12}: $SRC_DIR/tbc-bin"
  info "Save your ndus cookie to a private file, then: TERABOX_COOKIE_FILE=FILE $0 backup"
}

terabox_cmd() {
  local bin=${TBC_BIN:-$SRC_DIR/tbc-bin}
  [[ -x $bin ]] || return 1
  if [[ -n $TERABOX_COOKIE_FILE ]]; then
    [[ -s $TERABOX_COOKIE_FILE ]] || return 1
    chmod 600 "$TERABOX_COOKIE_FILE" 2>/dev/null || true
    printf '%q -c %q put -d %q' "$bin" "$TERABOX_COOKIE_FILE" "$TERABOX_DIR"
  elif [[ -n ${TERABOX_COOKIE:-} ]]; then
    printf '%q put -d %q' "$bin" "$TERABOX_DIR"
  else
    return 1
  fi
}

# Optional offsite copy. The archive holds the attestation GPG key and CA key, so it
# is encrypted first and nothing is uploaded without a passphrase file. A failure here
# only warns: the verified local backup already exists.
# Google One storage is Google Drive storage. Uses rclone's official Drive backend:
# create a remote once with `rclone config` (type "drive", scope drive.file), then set
# GDRIVE_REMOTE=NAME:folder, for example gdrive:netboot-backups.
gdrive_cmd() {
  [[ -n $GDRIVE_REMOTE ]] || return 1
  command -v rclone >/dev/null 2>&1 || { warn "GDRIVE_REMOTE is set but rclone is not installed (Termux: pkg install rclone)"; return 1; }
  printf 'rclone copy --retries 3 -- "$1" %q' "$GDRIVE_REMOTE"
}

backup_upload() {
  local f=$1 enc="$1.gpg" c
  local -a labels=() cmds=()
  if [[ -n $BACKUP_UPLOAD_CMD ]]; then labels+=("custom"); cmds+=("$BACKUP_UPLOAD_CMD \"\$1\""); fi
  if c=$(terabox_cmd); then labels+=("Terabox"); cmds+=("$c \"\$1\""); fi
  if c=$(gdrive_cmd); then labels+=("Google One (Drive)"); cmds+=("$c"); fi
  (( ${#cmds[@]} )) || return 0
  if [[ -z $BACKUP_GPG_PASSFILE || ! -s $BACKUP_GPG_PASSFILE ]]; then
    warn "Offsite upload is configured but BACKUP_GPG_PASSFILE is missing or empty. Not uploading an unencrypted archive."
    return 0
  fi
  need gpg
  rm -f "$enc"
  if ! ( umask 077; gpg --batch --no-tty --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSFILE" \
         --symmetric --cipher-algo AES256 --output "$enc" "$f" ) >/dev/null 2>&1; then
    rm -f "$enc"; warn "Encryption failed. Offsite upload skipped."; return 0
  fi
  local i good="" badl=""
  for i in "${!cmds[@]}"; do
    info "Uploading $(basename "$enc") to ${labels[$i]}"
    if bash -c "${cmds[$i]}" _ "$enc"; then
      ok "${labels[$i]} upload done"; good+="${good:+, }${labels[$i]}"
    else
      warn "${labels[$i]} upload failed. Local backup is intact: $f"; badl+="${badl:+, }${labels[$i]}"
    fi
  done
  rm -f "$enc"
  printf '%s %s%s\n' "$(now_iso)" "${good:+OK: $good}" "${badl:+ FAILED: $badl}" | atomic_write "$STATE/offsite.status" || true
}

backup_prune() {
  [[ $BACKUP_KEEP =~ ^[0-9]+$ ]] && (( BACKUP_KEEP > 0 )) || return 0
  local f n=0
  while IFS= read -r f; do
    n=$((n+1))
    if (( n > BACKUP_KEEP )); then rm -f -- "$f" "$f.sha256" "$f.meta"; fi
  done <<<"$(ls -1t "$BACKUP_DIR"/netboot-*.tar.gz 2>/dev/null || true)"
  return 0
}

backup_list() {
  ls -1t "$BACKUP_DIR"/netboot-*.tar.gz 2>/dev/null || { info "No backups in $BACKUP_DIR"; return 0; }
}

backup_verify() {
  local f=$1
  [[ -f $f ]] || die "No such backup: $f"
  [[ -f $f.sha256 ]] || die "Missing checksum file: $f.sha256"
  ( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null 2>&1 ) \
    || die "Backup checksum mismatch: $f"
  tar -tzf "$f" >/dev/null 2>&1 || die "Backup archive is unreadable: $f"
}

# Runs before anything that can change or remove served state.
auto_backup() {
  [[ $AUTO_BACKUP == 1 ]] || return 0      # backups happen only when you ask for them
  [[ -d $ROOT ]] || return 0
  local now last
  now=$(backup_fingerprint 2>/dev/null || true)
  last=$(cat "$BACKUP_FP_FILE" 2>/dev/null || true)
  if [[ -n $now && $now == "$last" ]] && compgen -G "$BACKUP_DIR/netboot-*.tar.gz" >/dev/null; then
    ok "Nothing has changed since the last backup. Skipping it."
    return 0
  fi
  # A backup is a safety net, never a gate: if it cannot finish, say so and carry on.
  if ! ( backup_create "auto-$1" ); then
    warn "The automatic backup did not finish, so I am continuing without it. Fix it later with: $0 backup   (or turn it off: $0 backup-auto off)"
  fi
  return 0
}

# Turn the automatic backup on or off for good (saved in the settings file)
backup_auto_cmd() {
  case "${1:-}" in
    on)  save_setting AUTO_BACKUP 1 && ok "Automatic backups are ON: one is taken before serve or clean, only when something changed." ;;
    off) save_setting AUTO_BACKUP 0 && ok "Automatic backups are OFF (the default). Take one yourself any time with: $0 backup" ;;
    *)   info "Backups are $([[ $AUTO_BACKUP == 1 ]] && echo "AUTOMATIC (before serve and clean)" || echo "ONLY WHEN YOU ASK (the default)"). Take one: $0 backup   |   Automatic: $0 backup-auto on" ;;
  esac
}

restore() {
  local f=${1:-} stage base parent top n
  [[ -n $f ]] || { backup_list; die "Usage: $0 restore ARCHIVE [--dry-run]   (a file from the list above)"; }
  [[ -f $f ]] || f="$BACKUP_DIR/$f"
  need tar
  backup_verify "$f"
  base=$(basename "$ROOT"); parent=$(dirname "$ROOT")
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    info "Dry run: restoring $(basename "$f") would replace these items in $ROOT (nothing is changed):"
    tar -tzf "$f" | awk -F/ -v b="$base" 'NF>=2 && $1==b && $2!="" {print $2}' | sort -u | sed 's/^/    /'
    [[ -f $f.meta ]] && sed 's/^/    /' "$f.meta"
    return 0
  fi
  kill_servers
  [[ -d $ROOT ]] && backup_create "pre-restore"
  stage="$ROOT.restore.NEW"
  rm -rf "$stage"; mkdir -p "$stage"
  if ! tar -C "$stage" -xzpf "$f"; then
    rm -rf "$stage"; die "Restore archive could not be unpacked. Nothing was changed."
  fi
  [[ -d $stage/$base ]] || { rm -rf "$stage"; die "This archive was not made from a folder named '$base'. Nothing was changed."; }
  warn "Restoring $(basename "$f") into $ROOT (downloads and extracted files stay as they are)"
  run_root "chown -R $(id -u):$(id -g) '$ROOT'" >/dev/null 2>&1 || true
  mkdir -p "$ROOT"
  n=0
  for top in "$stage/$base"/* "$stage/$base"/.[!.]*; do
    [[ -e $top ]] || continue
    if [[ $(basename "$top") == state ]]; then
      # state holds the live lock and undo journal: copy over it instead of replacing the folder
      rm -rf "$top/lock.d" "$top/undo.d"
      mkdir -p "$ROOT/state"; cp -af "$top"/. "$ROOT/state"/
    elif [[ -d $top ]]; then
      atomic_dir_swap "$top" "$ROOT/$(basename "$top")" || { rm -rf "$stage"; die "Could not swap in $(basename "$top"). Your previous state is in the pre-restore backup in $BACKUP_DIR."; }
    else
      mv -f "$top" "$ROOT/$(basename "$top")"
    fi
    n=$((n+1))
  done
  rm -rf "$stage"
  ok "Restored $n item(s). Run: $0 status, then $0 go"
}

# =============================================================================
# Serving
# =============================================================================
require_ready() {
  [[ -n $DNSMASQ && -x $DNSMASQ ]] || die "dnsmasq not found. Run: $0 deps"
  [[ -n $PYTHON ]] || die "python3 not found. Run: $0 deps"
  [[ -f $DNSMASQ_CONF && -f $LIB/httpd.py ]] || die "Not configured. Run: $0 --distro $DISTRO --arch $TARGET_ARCH configure"
  load_layout
  if [[ $BOOT_LOADER == shim ]]; then
    shim_ready || die "$E_ENV" "Ubuntu's signed boot files are missing. Run: $0 shim-fetch"
  else
    require_ipxe_matches_ca
  fi
}

setup_direct() {
  local ip=${DIRECT_CIDR%/*}
  if ! ip_q -4 -o addr show dev "$IFACE" | grep -q "inet $ip/"; then
    info "Assigning $DIRECT_CIDR to $IFACE"
    JID_DIRECT=$(journal_push "ip addr del $DIRECT_CIDR dev $IFACE 2>/dev/null; ip rule del from $ip lookup main pref 9000 2>/dev/null; ip rule del to ${NET:-0.0.0.0}/${PREFIX_LEN:-24} lookup main pref 9001 2>/dev/null; true")
    run_root "ip link set $IFACE up && ip addr add $DIRECT_CIDR dev $IFACE" || die "$E_ENV" "Could not assign $DIRECT_CIDR to $IFACE"
    DIRECT_ADDED=1
  fi
  if (( IS_ANDROID )); then
    # Android uses policy routing; keep replies to the direct link on that link
    run_root "ip rule add from $ip lookup main pref 9000 2>/dev/null; ip rule add to $NET/$PREFIX_LEN lookup main pref 9001 2>/dev/null; true" || true
  fi
}

teardown_direct() {
  (( DIRECT_ADDED )) || return 0
  local ip=${DIRECT_CIDR%/*}
  run_root "ip addr del $DIRECT_CIDR dev $IFACE 2>/dev/null; ip rule del from $ip lookup main pref 9000 2>/dev/null; ip rule del to $NET/$PREFIX_LEN lookup main pref 9001 2>/dev/null; true" || true
  [[ -n ${JID_DIRECT:-} ]] && journal_drop "$JID_DIRECT"
  DIRECT_ADDED=0
}

power_save_off() {
  if (( IS_ANDROID )); then
    JID_POWER=$(journal_push "iw dev $IFACE set power_save on 2>/dev/null; cmd wifi force-hi-perf-mode disabled 2>/dev/null; true")
    if run_root "command -v iw >/dev/null 2>&1 && iw dev $IFACE set power_save off" >/dev/null 2>&1; then
      ok "Wi-Fi power save disabled on $IFACE (iw)"; POWER_TWEAKED=1; return 0
    fi
    if run_root "cmd wifi force-hi-perf-mode enabled" >/dev/null 2>&1; then
      ok "Wi-Fi high-performance mode enabled"; POWER_TWEAKED=1; return 0
    fi
    journal_drop "$JID_POWER"; JID_POWER=""
    warn "Could not change Wi-Fi power save. Keep the screen on and Termux set to unrestricted battery use."
  fi
}

power_save_restore() {
  (( POWER_TWEAKED )) || return 0
  run_root "iw dev $IFACE set power_save on 2>/dev/null; cmd wifi force-hi-perf-mode disabled 2>/dev/null; true" >/dev/null 2>&1 || true
  [[ -n $JID_POWER ]] && journal_drop "$JID_POWER"
  POWER_TWEAKED=0
}

kill_servers() {
  if [[ -n $SERVE_HTTP_PID ]]; then kill "$SERVE_HTTP_PID" 2>/dev/null || true; fi
  pkill -f "$LIB/httpd.py" 2>/dev/null || true
  if [[ -s $RUN/dnsmasq.pid ]]; then
    run_root "kill \$(cat '$RUN/dnsmasq.pid') 2>/dev/null; rm -f '$RUN/dnsmasq.pid'" >/dev/null 2>&1 || true
  fi
  run_root "pkill -f '$DNSMASQ_CONF'" >/dev/null 2>&1 || true
}

cleanup() {
  trap - EXIT
  kill_servers
  teardown_direct
  power_save_restore
  (( IS_TERMUX )) && termux-wake-unlock 2>/dev/null || true
  run_root "chown -R $(id -u):$(id -g) '$RUN'" >/dev/null 2>&1 || true
  if [[ -n $TAIL_PID ]]; then kill "$TAIL_PID" 2>/dev/null || true; fi
  if [[ -n $DEEP_PID ]]; then pkill -P "$DEEP_PID" 2>/dev/null || true; kill "$DEEP_PID" 2>/dev/null || true; fi
  note_serve "stopped"
  release_lock
  echo
  info "Servers stopped"
}

serve() {
  if (( IS_PROOT )); then
    die "$E_ENV" "You are inside a proot Linux environment. It cannot see the phone's network or open the DHCP/TFTP ports, so it cannot serve a PC. Type 'exit' to return to Termux and run this there (rooted). This environment is good for building the loader: $0 proot-build"
  fi
  resolve_network
  require_ready
  [[ $MODE == direct ]] && setup_direct
  resolve_network

  grep -q "^interface=$IFACE$" "$DNSMASQ_CONF" && grep -q "$PHONE_IP:$HTTP_PORT" "$TFTP/boot.ipxe" \
    || die "Network changed since configure (now $IFACE $PHONE_IP). Run: $0 configure"

  auto_backup serve
  journal_replay
  verify_manifest
  save_profile
  note_serve "started ($DISTRO/$TARGET_ARCH on $IFACE $PHONE_IP)"

  if port_in_use tcp "$HTTP_PORT"; then die "$E_BUSY" "TCP $HTTP_PORT is in use. Set HTTP_PORT=... or run: $0 clean"; fi
  if port_in_use udp 67; then warn "UDP 67 is in use. dnsmasq may fail to bind (see selinux or hotspot notes)."; fi
  if port_in_use udp 69; then warn "UDP 69 is in use. TFTP may fail to bind."; fi

  trap cleanup EXIT
  trap 'exit 130' INT TERM

  (( IS_TERMUX )) && { termux-wake-lock 2>/dev/null || true; }
  power_save_off

  mkdir -p "$RUN"
  DNS_LOG="$ROOT/dnsmasq.log"
  printf '\n--- server start %s ---\n' "$(now_iso)" >> "$HTTP_LOG"
  info "Starting the HTTP server on $PHONE_IP:$HTTP_PORT (log: $HTTP_LOG)"
  start_http || die "$E_ENV" "HTTP server failed to start. See $HTTP_LOG.err"

  local vb_text="ON (signed, client verifies)"
  [[ $VERIFIED_BOOT == 1 ]] || vb_text="OFF"
  [[ $BOOT_LOADER == shim ]] && vb_text="Ubuntu signed chain (Secure Boot ok)"
  echo
  box \
    "PXE SERVER STATUS: RUNNING" \
    "" \
    "Live system    : $P_LABEL / $TARGET_ARCH" \
    "Client RAM     : about $CLIENT_RAM_GB GB or more" \
    "Interface      : $IFACE ($MODE DHCP)" \
    "Subnet         : $NET/$PREFIX_LEN" \
    "Server IP      : $PHONE_IP" \
    "Client URL     : $BASE_URL" \
    "Verified boot  : $vb_text" \
    "" \
    "Watching itself: restarts a crashed server, follows an address change" \
    "Live HTTP log  : $0 logs" \
    "Press Ctrl+C to stop."
  echo

  rm -f "$RUN/DEEP_FAIL" "$RUN/DEEP_OK"
  if (( ${#BIG_FAST[@]} )); then
    info "Verifying ${#BIG_FAST[@]} big file(s) in the background at low priority; serving starts now"
    deep_verify_bg & DEEP_PID=$!
  fi

  info "Starting dnsmasq ($MODE DHCP + TFTP) as root"
  start_dns
  tail -n 0 -F "$DNS_LOG" 2>/dev/null & TAIL_PID=$!
  sleep 1
  dns_alive || die "$E_ENV" "dnsmasq exited. If it could not bind a port, check: $0 selinux status, and whether a hotspot or another DHCP/TFTP service holds ports 67/69."
  protect_pid "$(run_root "cat '$RUN/dnsmasq.pid'" 2>/dev/null || true)"
  ok "Ready. Boot the PC from the network now."
  pc_instructions
  watchdog || true
  serve_epilogue
}

# ---- server processes, supervised by watchdog() ------------------------------------
start_http() {
  HTTPD_LOG="$HTTP_LOG" HTTPD_ALLOW="$ISO" "$PYTHON" "$LIB/httpd.py" "$PHONE_IP" "$HTTP_PORT" "$HTTP" >> "$HTTP_LOG.err" 2>&1 &
  SERVE_HTTP_PID=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    kill -0 "$SERVE_HTTP_PID" 2>/dev/null || return 1
    http_health && { protect_pid "$SERVE_HTTP_PID"; return 0; }
  done
  kill -0 "$SERVE_HTTP_PID" 2>/dev/null
}

http_health() { curl -fsS -m 2 -o /dev/null "http://$PHONE_IP:$HTTP_PORT/healthz" 2>/dev/null; }
http_stats()  { curl -fsS -m 2 "http://$PHONE_IP:$HTTP_PORT/healthz" 2>/dev/null || true; }

start_dns() {
  local ldp=""
  (( IS_TERMUX )) && ldp="LD_LIBRARY_PATH=$PREFIX/lib "
  { run_root "${ldp}$DNSMASQ --no-daemon --conf-file=$DNSMASQ_CONF" || true; } >> "$DNS_LOG" 2>&1 &
}

dns_alive() {
  run_root "p=\$(cat '$RUN/dnsmasq.pid' 2>/dev/null); [ -n \"\$p\" ] && kill -0 \"\$p\" 2>/dev/null" >/dev/null 2>&1
}

stop_dns() {
  run_root "kill \$(cat '$RUN/dnsmasq.pid' 2>/dev/null) 2>/dev/null; rm -f '$RUN/dnsmasq.pid'; pkill -f '$DNSMASQ_CONF' 2>/dev/null; true" >/dev/null 2>&1 || true
}

# Android's low-memory killer kills the least important apps first; make ours important.
protect_pid() {
  (( IS_ANDROID )) || return 0
  [[ ${1:-} =~ ^[0-9]+$ ]] || return 0
  run_root "echo -500 > /proc/$1/oom_score_adj" >/dev/null 2>&1 || true
}

WD_TIMES=()
wd_budget() {   # at most 5 restarts per 5 minutes; backs off a little each time
  local now t keep=()
  now=$(date +%s)
  for t in "${WD_TIMES[@]}"; do (( now - t < 300 )) && keep+=("$t"); done
  WD_TIMES=("${keep[@]}")
  (( ${#WD_TIMES[@]} < 5 )) || return 1
  sleep $(( ${#WD_TIMES[@]} * 2 ))
  WD_TIMES+=("$now")
  return 0
}

wd_restart() {   # http | dns
  if [[ -f $RUN/DEEP_FAIL ]]; then return 0; fi
  if ! wd_budget; then
    err "The $1 server keeps crashing (5 restarts in 5 minutes). Stopping so you can look. Log: $LOG_FILE"
    log_event ERROR "watchdog gave up on $1"
    return 1
  fi
  case "$1" in
    http) kill "$SERVE_HTTP_PID" 2>/dev/null || true
          if start_http; then ok "HTTP server restarted"; log_event WARN "watchdog restarted http"; else warn "HTTP restart failed; will retry"; fi ;;
    dns)  stop_dns; start_dns; sleep 1
          if dns_alive; then ok "dnsmasq restarted"; log_event WARN "watchdog restarted dnsmasq"; protect_pid "$(run_root "cat '$RUN/dnsmasq.pid'" 2>/dev/null || true)"; else warn "dnsmasq restart failed; will retry"; fi ;;
  esac
  return 0
}

NET_LOST=0
net_check() {
  local cur
  cur=$( ( LOG_QUIET=1; resolve_network >/dev/null 2>&1 && printf '%s %s' "$IFACE" "$PHONE_IP" ) 2>/dev/null || true )
  if [[ -z $cur ]]; then
    (( NET_LOST )) || warn "Network lost on $IFACE. The servers stay up and will carry on when it returns."
    NET_LOST=1; return 0
  fi
  NET_LOST=0
  [[ ${cur#* } != "$PHONE_IP" ]] || return 0
  warn "Phone address changed ($PHONE_IP -> ${cur#* }). Re-signing boot files and restarting the servers."
  log_event WARN "address change $PHONE_IP -> ${cur#* }"
  resolve_network
  if ( configure ) >/dev/null 2>&1; then
    kill "$SERVE_HTTP_PID" 2>/dev/null || true; stop_dns
    start_http && start_dns
    sleep 1
    if dns_alive; then ok "Serving again on $PHONE_IP"; else warn "Servers did not come back; the watchdog will retry."; fi
  else
    err "Could not update the boot files for the new address. Run: $0 heal"
  fi
}

LAST_REQ=-1
show_activity() {
  local st req bytes
  st=$(http_stats)
  [[ $st =~ requests=([0-9]+)\ bytes=([0-9]+) ]] || return 0
  req=${BASH_REMATCH[1]}; bytes=${BASH_REMATCH[2]}
  if [[ $req != "$LAST_REQ" ]]; then
    LAST_REQ=$req
    printf '%s[%s]%s %s requests served, %s MB sent\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_RESET" "$req" "$((bytes/1048576))"
  fi
  if [[ -f $DNS_LOG ]] && (( $(file_size "$DNS_LOG") > 5242880 )); then : > "$DNS_LOG"; fi
}

watchdog() {
  local tick=0 bad=0
  while :; do
    sleep 2 & wait $! || true
    tick=$((tick+2))
    if [[ -f $RUN/DEEP_FAIL ]]; then return 0; fi
    if ! kill -0 "$SERVE_HTTP_PID" 2>/dev/null; then
      warn "HTTP server stopped unexpectedly"; wd_restart http || return 1
    elif (( tick % 6 == 0 )); then
      if http_health; then bad=0
      else
        bad=$((bad+1))
        if (( bad >= 3 )); then warn "HTTP server is not answering"; bad=0; wd_restart http || return 1; fi
      fi
    fi
    if (( tick % 4 == 0 )) && ! dns_alive && [[ ! -f $RUN/DEEP_FAIL ]]; then
      warn "dnsmasq stopped unexpectedly"; wd_restart dns || return 1
    fi
    if (( tick % 6 == 0 )); then net_check; fi
    if (( tick % 10 == 0 )); then show_activity; fi
  done
}

serve_epilogue() {
  if [[ -f $RUN/DEEP_FAIL ]]; then
    die "$E_INTEGRITY" "Served file changed on disk: $(cat "$RUN/DEEP_FAIL"). Servers were stopped. Run '$0 heal' and re-extract."
  fi
}

logs() {
  [[ -f $HTTP_LOG ]] || die "No log yet. Start the server first: $0 serve"
  info "Following $HTTP_LOG (Ctrl+C to stop)"
  tail -n 50 -f "$HTTP_LOG"
}

selinux_ctl() {
  (( IS_ANDROID )) || { info "SELinux control is for Android only"; return 0; }
  case "${1:-status}" in
    status)     run_root getenforce ;;
    permissive) warn "This lowers device security. Restore with: $0 selinux enforcing"
                run_root "setenforce 0" && ok "SELinux set to permissive" ;;
    enforcing)  run_root "setenforce 1" && ok "SELinux set to enforcing" ;;
    *) die "Usage: $0 selinux {status|permissive|enforcing}" ;;
  esac
}

# =============================================================================
# Diagnostics
# =============================================================================
check() {
  local fails=0 t avail_mb cidr link_state

  info "Pre-flight checks: $DISTRO / $TARGET_ARCH on $(uname -m) ($( ((IS_TERMUX)) && echo Termux || echo Linux ))"

  if [[ $(id -u) -eq 0 ]] || { (( IS_ANDROID )) && [[ "$(su -c 'id -u' 2>/dev/null || true)" == "0" ]]; } \
     || { (( ! IS_ANDROID )) && sudo -n true 2>/dev/null; }; then
    ok "Root available"
  else
    if (( IS_ANDROID )); then
      err "No root. Grant Termux root in Magisk or KernelSU."; fails=$((fails+1))
    else
      warn "Root will be requested through sudo when needed"
    fi
  fi

  if [[ -n $DNSMASQ && -x $DNSMASQ ]]; then ok "dnsmasq: $DNSMASQ"; else err "dnsmasq missing (run: $0 deps)"; fails=$((fails+1)); fi
  if [[ -n $PYTHON ]]; then ok "python: $PYTHON"; else err "python3 missing (run: $0 deps)"; fails=$((fails+1)); fi

  for t in bsdtar curl ip awk gpg openssl sha256sum sha512sum; do
    if command -v "$t" >/dev/null 2>&1; then ok "Tool present: $t"; else err "Tool missing: $t (run: $0 deps)"; fails=$((fails+1)); fi
  done
  for t in git make perl; do
    if command -v "$t" >/dev/null 2>&1; then ok "Build tool present: $t"; else warn "Build tool missing: $t (needed for build-ipxe)"; fi
  done

  if port_in_use udp 67; then warn "UDP 67 (DHCP) in use"; else ok "UDP 67 free"; fi
  if port_in_use udp 69; then warn "UDP 69 (TFTP) in use"; else ok "UDP 69 free"; fi
  if port_in_use udp 4011; then warn "UDP 4011 (PXE) in use"; else ok "UDP 4011 free"; fi
  if port_in_use tcp "$HTTP_PORT"; then warn "TCP $HTTP_PORT in use"; else ok "TCP $HTTP_PORT free"; fi

  mkdir -p "$ROOT"
  avail_mb=$(free_mb "$ROOT")
  if (( avail_mb >= MIN_FREE_MB )); then
    ok "Storage: $avail_mb MB free (need $MIN_FREE_MB MB for $DISTRO)"
  else
    err "Storage: only $avail_mb MB free (need $MIN_FREE_MB MB for $DISTRO)"; fails=$((fails+1))
  fi

  case "$(fs_type "$ROOT")" in
    msdos|vfat|exfat) err "Folder is on a FAT/exFAT drive: no files over 4 GB and no links. Use internal storage."; fails=$((fails+1)) ;;
    fuse*|sdcardfs)   warn "Folder is on slow shared storage ($(fs_type "$ROOT")). Internal storage is faster." ;;
  esac
  local ma; ma=$(mem_avail_mb)
  if (( ma > 0 && ma < 300 )); then warn "Only $ma MB of RAM free. Close other apps so Android keeps the servers alive."; fi

  if ( resolve_network ) >/dev/null 2>&1; then
    resolve_network
    link_state=$(ip_q -o link show "$IFACE")
    ok "Network: $IFACE $PHONE_IP/$PREFIX_LEN, mode $MODE${link_state:+, link up}"
    (( IS_HOTSPOT )) && warn "$IFACE looks like a hotspot. Android's DHCP server may block port 67."
    if [[ $MODE == proxy ]]; then
      info "Proxy mode needs the PC on the same network segment as $IFACE. Guest Wi-Fi and AP client isolation block PXE."
    fi
  elif (( IS_PROOT )); then
    warn "Inside a proot Linux: the phone's network and ports 67/69 are not reachable from here. Use this environment to BUILD the loader (run: $0 proot-build). Serve from Termux itself."
  else
    err "No usable network interface (set IFACE=..., or --mode direct for a cable)"; fails=$((fails+1))
  fi

  if (( ! IS_ANDROID )); then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
      warn "ufw is active. Allow UDP 67, 69, 4011 and TCP $HTTP_PORT."
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      warn "firewalld is active. Allow UDP 67, 69, 4011 and TCP $HTTP_PORT."
    fi
  else
    info "SELinux: $(run_root getenforce 2>/dev/null || echo unknown)"
  fi

  if [[ -n $(attest_fpr) ]]; then ok "Attestation key: $(attest_fpr)"; else warn "No attestation identity (run: $0 attest-init)"; fi
  if [[ -s $ATTEST/script.sha256.asc ]]; then ok "Script self-signature present"; else warn "Script not self-signed (run: $0 self-sign)"; fi

  local expired=0 h
  for h in $(pin_hosts_for_target); do
    if [[ -z $(active_pins "$h") ]]; then warn "No valid pin for $h"; expired=$((expired+1)); fi
  done
  (( expired == 0 )) && ok "Valid pins for all hosts in use"
  [[ -s $PIN_AUDIT ]] && grep -q INTERCEPTION "$PIN_AUDIT" && warn "Pin audit log contains INTERCEPTION entries: $PIN_AUDIT"

  if [[ $BOOT_LOADER == shim ]]; then
    if shim_ready; then ok "Ubuntu's signed boot files (shim + grub) present"; else warn "Ubuntu's signed boot files not fetched yet (run: $0 shim-fetch)"; fi
  elif [[ -s $IPXE_BUILT ]]; then ok "iPXE: $(head -n1 "$IPXE_BUILT")"; else warn "iPXE not built or imported yet"; fi
  if iso_is_verified; then ok "ISO present and verified"; elif [[ -s $ISO ]]; then warn "ISO present but not verified"; else warn "ISO not downloaded"; fi
  if [[ -f $LAYOUT ]]; then ok "Boot files extracted"; else warn "Not extracted yet"; fi
  if [[ -f $MANIFEST ]]; then ok "Configured (manifest present)"; else warn "Not configured yet"; fi
  info "Client needs about $CLIENT_RAM_GB GB RAM. Disable Secure Boot and enable network (PXE) boot in its firmware."

  echo
  if (( fails == 0 )); then ok "All required checks passed"; else err "$fails required check(s) failed"; return 1; fi
}

clean() {
  auto_backup clean
  info "Stopping servers"
  kill_servers
  ok "Servers stopped"

  if [[ -d $HTTP ]]; then
    run_root "chown -R $(id -u):$(id -g) '$HTTP' '$RUN'" >/dev/null 2>&1 || true
    rm -rf -- "${HTTP:?}"/*
    ok "Extracted and served files removed"
  fi
  rm -f -- "$TFTP/boot.ipxe" "$TFTP/boot.ipxe.sig" "$TFTP/undionly.0" "$DNSMASQ_CONF" "$HTTP_LOG"
  rm -f -- "$STATE"/*.layout "$STATE"/*.manifest "$STATE"/*.config
  rm -rf -- "${RUN:?}"
  ok "Generated configs and manifests removed"
  info "Kept: ISOs and their verification records, iPXE binaries and source, pins, keyrings, attestation identity and reports"
}

# =============================================================================
# Health: status, doctor, heal, go
# =============================================================================
fs_type()  { stat -f -c %T "$1" 2>/dev/null || echo unknown; }
mem_avail_mb() { awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
is_pid_alive() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null; }

PROFILE="$STATE/profile"
save_profile() {
  mkdir -p "$STATE"
  { printf "DISTRO='%s'\n" "$DISTRO"; printf "TARGET_ARCH='%s'\n" "$TARGET_ARCH"
    printf "DHCP_MODE='%s'\n" "$DHCP_MODE"; printf "IFACE='%s'\n" "${IFACE:-}"
    printf "HTTP_PORT='%s'\n" "$HTTP_PORT"; printf "BOOT_LOADER='%s'\n" "$BOOT_LOADER"; } | atomic_write "$PROFILE" || true
}
load_profile() {   # applies only values you did not give on the command line / environment
  [[ -r $PROFILE ]] || return 1
  local line name val
  while IFS= read -r line; do
    name=${line%%=*}; val=${line#*=}
    [[ $val == \'*\' ]] || continue
    val=${val:1:${#val}-2}
    [[ $val != *\'* && -n $val ]] || continue
    case "$name" in
      DISTRO|TARGET_ARCH|DHCP_MODE|IFACE|HTTP_PORT|BOOT_LOADER)
        [[ " $CLI_SET " == *" $name "* || -n ${PRE_ENV[$name]:-} ]] || printf -v "$name" '%s' "$val" ;;
    esac
  done < "$PROFILE"
  return 0
}
note_serve() { printf '%s %s\n' "$(now_iso)" "$1" | atomic_write "$STATE/last-serve" 2>/dev/null || true; }

F_LVL=(); F_TAG=(); F_MSG=(); F_FIX=()
finding() { F_LVL+=("$1"); F_TAG+=("$2"); F_MSG+=("$3"); F_FIX+=("${4:-}"); }

orphans_running() {
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -f "$LIB/httpd.py" >/dev/null 2>&1 || pgrep -f "$DNSMASQ_CONF" >/dev/null 2>&1
}

diagnose() {
  F_LVL=(); F_TAG=(); F_MSG=(); F_FIX=()
  local other=0 cfg_ip cur n avail ft ma last age st f missing
  # lock
  if [[ -f $LOCK_DIR/owner ]] && lock_owner_alive; then
    read -r n _ < "$LOCK_DIR/owner"
    if [[ $n != "$BASHPID" ]]; then other=1; finding INFO LOCK "Another netboot-android command is running (pid $n)" ""; fi
  fi
  # leftovers from a crash
  n=$(journal_count)
  (( n == 0 )) || finding WARN JOURNAL "$n system change(s) from an earlier run were never undone (IP address, rules, Wi-Fi mode)" "$0 heal"
  if (( ! other )) && orphans_running; then finding WARN ORPHAN "Server processes from an earlier run are still running" "$0 heal"; fi
  if [[ -d $HTTP.new ]] || compgen -G "$HTTP.old.*" >/dev/null || compgen -G "$STATE/*.tmp" >/dev/null || compgen -G "$STATE/.conf.*" >/dev/null; then
    finding WARN TMPFILES "Half-finished temporary files from an interrupted step" "$0 heal"
  fi
  if compgen -G "$ROOT/*.part" >/dev/null; then
    finding INFO PARTIAL "A partial download is saved and will resume (run: $0 fetch)" ""
  fi
  if [[ -d $RUN && ! -O $RUN && $(id -u) -ne 0 ]]; then finding WARN PERMS "$RUN is owned by root from the last serve" "$0 heal"; fi
  if [[ -f $DNSMASQ_CONF && ! -f $LIB/httpd.py ]]; then finding WARN LIBS "Helper programs are missing" "$0 heal"; fi
  # storage and memory
  mkdir -p "$ROOT" 2>/dev/null || true
  avail=$(free_mb "$ROOT")
  if (( avail >= ${MIN_FREE_MB:-0} )); then finding OK DISK "Storage: $avail MB free" ""
  elif [[ -f $MANIFEST ]]; then finding WARN DISK "Storage is low: $avail MB free (serving still works)" "$0 clean   (keeps ISOs and keys)"
  else finding FAIL DISK "Storage: only $avail MB free, need ${MIN_FREE_MB:-?} MB for $DISTRO" "free space or set NETBOOT_HOME to a bigger drive"; fi
  ft=$(fs_type "$ROOT")
  case "$ft" in
    msdos|vfat|exfat) finding FAIL FSTYPE "Folder is on a $ft drive: no files over 4 GB, no links. Move NETBOOT_HOME to internal storage" "NETBOOT_HOME=\$HOME/netboot" ;;
    fuse*|sdcardfs)   finding WARN FSTYPE "Folder is on $ft storage (slow, may lack links). Internal storage is faster and safer" "" ;;
  esac
  ma=$(mem_avail_mb)
  if (( ma > 0 && ma < 300 )); then finding WARN MEM "Only $ma MB of RAM free: close other apps so Android keeps the servers alive" ""
  elif (( ma > 0 )); then finding OK MEM "Memory: $ma MB free"; fi
  # required programs (installed by the "deps" step)
  missing=$(missing_tools)
  if [[ -n $missing ]]; then finding FAIL TOOLS "Missing programs: $missing. Setup installs them" "$0 deps"
  else finding OK TOOLS "Required programs are installed" ""; fi
  # trust chain
  if [[ -z $(attest_fpr) ]]; then
    last=$(ls -1t "$BACKUP_DIR"/netboot-*.tar.gz 2>/dev/null | head -n1 || true)
    if [[ -n $last ]]; then finding FAIL ATTEST "No attestation identity here, but a backup exists" "$0 restore $(basename "$last")"
    else finding FAIL ATTEST "No attestation identity yet" "$0 attest-init"; fi
  else
    st=$(self_status)
    case "$st" in
      ok)      finding OK SELF "Script matches its signed fingerprint" "" ;;
      unset)   finding WARN SELF "Script fingerprint is not signed yet" "$0 self-sign" ;;
      changed) finding FAIL SELF "Script changed since it was signed (updated? run self-sign)" "$0 self-sign" ;;
      bad)     finding FAIL SELF "Signed script record failed verification (possible tampering)" "$0 fingerprints" ;;
    esac
  fi
  if [[ -s $(loader_pin_path) ]]; then
    if loader_pin_matches; then
      if [[ $(pin_get attested) == yes ]]; then finding INFO LOADERPIN "Loader is the GitHub build you approved (provenance verified)" ""
      else finding WARN LOADERPIN "Loader is the GitHub build you approved, but its build provenance was never checked" "$0 ipxe-fetch new"; fi
    else
      finding FAIL LOADERPIN "The loader on disk is NOT the one you approved" "$0 ipxe-fetch"
    fi
  elif [[ -s $TFTP/ipxe.efi && -f $IPXE_BUILT ]] && grep -q '^source=cloud' "$IPXE_BUILT"; then
    finding WARN LOADERTRUST "The iPXE loader came from GitHub without a saved approval" "$0 ipxe-fetch new"
  fi
  if [[ $BOOT_LOADER == shim ]]; then
    if shim_ready; then finding OK IPXE "Ubuntu's signed boot files present (Secure Boot ok)" ""
    else finding FAIL IPXE "Ubuntu's signed boot files not fetched yet" "$0 shim-fetch"; fi
  else
  [[ -s $TFTP/ipxe.efi ]] && finding OK IPXE "iPXE loader present" "" || finding FAIL IPXE "iPXE loader missing (this phone can build it itself)" "$([[ $HOST_ARCH == aarch64 && $TARGET_ARCH == x86_64 ]] && echo "$0 ipxe-phone" || echo "$0 build-ipxe")"
  fi
  iso_is_verified && finding OK ISO "$P_LABEL image verified" "" || finding FAIL ISO "$P_LABEL image not downloaded/verified" "$0 --distro $DISTRO --arch $TARGET_ARCH fetch"
  [[ -f $LAYOUT ]] && finding OK EXTRACT "Boot files extracted" "" || finding FAIL EXTRACT "Boot files not extracted" "$0 --distro $DISTRO --arch $TARGET_ARCH extract"
  if [[ -f $MANIFEST && -f $TFTP/boot.ipxe ]]; then
    finding OK CONFIG "Configured and signed" ""
    cfg_ip=$(sed -n 's|^set base http://\([0-9.]*\):.*|\1|p' "$TFTP/boot.ipxe" | head -n1)
    cur=$( ( LOG_QUIET=1; resolve_network 2>/dev/null; printf '%s %s' "$IFACE" "$PHONE_IP" ) 2>/dev/null || true )
    if [[ -z $cur || $cur == " " ]]; then finding FAIL NET "No usable network connection" "connect Wi-Fi/Ethernet"
    elif [[ ${cur#* } != "$cfg_ip" ]]; then finding WARN NETCHG "Phone address changed ($cfg_ip -> ${cur#* }); boot files must be re-signed" "$0 heal"
    else finding OK NET "Network ${cur%% *} at ${cur#* } matches the boot files" ""; fi
  else
    finding FAIL CONFIG "Not configured yet" "$0 --distro $DISTRO --arch $TARGET_ARCH configure"
  fi
  # backups
  last=$(ls -1t "$BACKUP_DIR"/netboot-*.tar.gz 2>/dev/null | head -n1 || true)
  if [[ -z $last ]]; then finding INFO BACKUP "No backup (optional: $0 backup)" ""
  else
    age=$(( ( $(date +%s) - $(file_mtime "$last") ) / 3600 ))
    (( age < 168 )) && finding OK BACKUP "Last backup $age h ago" "" || finding WARN BACKUP "Last backup is $((age/24)) days old" "$0 backup"
  fi
  [[ -s $STATE/offsite.status ]] && finding INFO OFFSITE "Offsite: $(cat "$STATE/offsite.status")" ""
  [[ -s $STATE/last-serve ]] && finding INFO SERVE "Last serve: $(cat "$STATE/last-serve")" ""
  return 0
}

print_findings() {
  local i col tag
  for i in "${!F_LVL[@]}"; do
    case "${F_LVL[$i]}" in
      OK)   col=$C_GREEN;  tag=" OK " ;;
      WARN) col=$C_YELLOW; tag="WARN" ;;
      FAIL) col=$C_RED;    tag="FAIL" ;;
      *)    col=$C_CYAN;   tag=" .. " ;;
    esac
    printf '  %s[%s]%s %s\n' "$col" "$tag" "$C_RESET" "${F_MSG[$i]}"
    if [[ -n ${F_FIX[$i]} && ${F_LVL[$i]} != OK ]]; then printf '         %sfix:%s %s\n' "$C_DIM" "$C_RESET" "${F_FIX[$i]}"; fi
  done
  return 0
}

verdict() {   # 0 ready, 1 attention
  local i bad=0
  for i in "${!F_LVL[@]}"; do [[ ${F_LVL[$i]} == FAIL ]] && bad=$((bad+1)); done
  if (( bad == 0 )); then
    printf '\n  %s%sREADY TO SERVE.%s Run: %s go\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$0"; return 0
  fi
  printf '\n  %s%sNEEDS ATTENTION (%d problem(s)).%s Run: %s heal   or follow the fixes above.\n\n' "$C_BOLD" "$C_RED" "$bad" "$C_RESET" "$0"; return 1
}

status() {
  load_profile && set_distro || true
  printf '%sStatus: %s / %s  (network mode %s)%s\n' "$C_BOLD" "$P_LABEL" "$TARGET_ARCH" "$DHCP_MODE" "$C_RESET"
  diagnose; print_findings; verdict
}

doctor() { status; }

# Safe repairs only. Everything here is idempotent and never touches keys, backups, or downloads.
heal_safe() {
  local did=0 d
  if [[ $(journal_count) -gt 0 ]]; then journal_replay; did=1; fi
  if orphans_running; then info "Stopping leftover server processes"; kill_servers; did=1; fi
  for d in "$HTTP.new" "$STATE"/.conf.* "$MANIFEST.tmp" "$MANIFEST.fp.tmp" "$VERIFY_REC.tmp" "$VERIFY_REC.sha"; do
    [[ -e $d ]] && { rm -rf -- "$d"; did=1; ok "Removed leftover: ${d#"$ROOT"/}"; }
  done
  for d in "$HTTP".old.*; do
    [[ -e $d ]] || continue
    if [[ ! -d $HTTP ]]; then mv -T "$d" "$HTTP" && ok "Restored the previous boot files (an update was interrupted)"
    else rm -rf -- "$d"; ok "Removed leftover: ${d#"$ROOT"/}"; fi
    did=1
  done
  if [[ -d $RUN && ! -O $RUN ]]; then run_root "chown -R $(id -u):$(id -g) '$RUN'" >/dev/null 2>&1 && { ok "Fixed ownership of $RUN"; did=1; }; fi
  if [[ -f $DNSMASQ_CONF && ! -f $LIB/httpd.py ]]; then write_libs; ok "Rewrote helper programs"; did=1; fi
  if [[ -s $(loader_pin_path) ]] && ! loader_pin_matches; then
    info "The loader is missing or changed. Restoring the exact one you approved."
    if ( ipxe_fetch ) >/dev/null 2>&1; then ok "Approved loader restored"; did=1; else warn "Could not restore it now (offline?). Run: $0 ipxe-fetch"; fi
  fi
  (( did )) || ok "Nothing needed fixing"
  log_event INFO "heal_safe did=$did"
  return 0
}

heal() {
  load_profile && set_distro || true
  info "Checking and repairing (safe fixes only; nothing is deleted that you cannot rebuild)"
  heal_safe
  diagnose
  local i netchg=0
  for i in "${!F_TAG[@]}"; do [[ ${F_TAG[$i]} == NETCHG ]] && netchg=1; done
  if (( netchg )); then
    info "The phone's address changed. Re-signing the boot files for the new address"
    if ( configure ) >/dev/null 2>&1; then ok "Boot files updated for the new address"; else warn "Could not update automatically. Run: $0 configure"; fi
    diagnose
  fi
  print_findings
  verdict || {
    local setup_bad=0
    for i in "${!F_LVL[@]}"; do
      [[ ${F_LVL[$i]} == FAIL ]] || continue
      case "${F_TAG[$i]}" in TOOLS|ATTEST|IPXE|LOADERPIN|ISO|EXTRACT|CONFIG) setup_bad=1 ;; esac
    done
    if (( setup_bad )) && [[ -t 0 ]]; then
      say "The missing pieces are setup steps. The guide does them in the right order and skips what is done."
      ask_yn "Run the guided setup now?" y && GUIDE_WELCOMED=1 guided
    fi
    return 1
  }
}

go_cmd() {
  load_profile && set_distro || true
  info "go: $P_LABEL / $TARGET_ARCH, network mode $DHCP_MODE"
  heal_safe
  diagnose
  local i hard=0
  for i in "${!F_LVL[@]}"; do
    if [[ ${F_TAG[$i]} == NETCHG ]]; then
      info "Phone address changed; re-signing boot files"
      ( configure ) >/dev/null 2>&1 && ok "Boot files updated" || die "$E_ENV" "Could not re-sign for the new address. Run: $0 configure"
    elif [[ ${F_LVL[$i]} == FAIL && ${F_TAG[$i]} != SELF ]]; then
      hard=1; err "${F_MSG[$i]}"; [[ -n ${F_FIX[$i]} ]] && next_step "${F_FIX[$i]}"
    fi
  done
  (( hard == 0 )) || die "$E_ENV" "Not ready to serve. Run '$0 status' for the full picture."
  serve
}

# =============================================================================
# Inside a proot Linux on the phone: build the loader for the Termux install
# =============================================================================
proot_build_flow() {
  echo
  box \
    "YOU ARE INSIDE A PROOT LINUX ON THE PHONE" \
    "" \
    "This environment can compile the loader but cannot run the PXE" \
    "server (no access to the phone's network or ports 67/69)." \
    "" \
    "Important: the loader must contain the certificate of the install" \
    "that will SERVE, i.e. your Termux one. Keys made in here are not" \
    "used. So we build with a copy of Termux's PUBLIC certificate."
  echo
  say "${C_BOLD}Step A, in Termux (not here):${C_RESET} copy the public certificate into this environment"
  say "  cp ~/netboot/attest/ca.crt \"\$PREFIX\"/var/lib/proot-distro/installed-rootfs/*/root/ca.crt"
  hint "If you have more than one proot Linux, replace * with this one's folder name."
  echo
  local ca="${TRUST_CA:-/root/ca.crt}" ans
  read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Path to that ca.crt inside this environment [$ca]: " ans || ans=""
  ca=${ans:-$ca}
  [[ -s $ca ]] || die "$E_ENV" "No file at $ca. Do Step A in Termux first, then run: $0 proot-build"
  if grep -q 'PRIVATE KEY' "$ca"; then die "$E_INTEGRITY" "That file contains a PRIVATE KEY. Never copy private keys around. Use ca.crt only."; fi
  openssl x509 -in "$ca" -noout -text 2>/dev/null | grep -q 'CA:TRUE' || die "$E_INTEGRITY" "$ca is not a CA certificate. Copy ~/netboot/attest/ca.crt from Termux."
  ok "Certificate: $(openssl x509 -in "$ca" -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)..."
  if ! have_cross_gcc && [[ $TARGET_ARCH == x86_64 && $(uname -m) == aarch64 ]]; then
    ask_yn "Install the x86_64 compiler and build tools now?" y || return 0
    ( deps ) || die "$E_ENV" "Tool install failed. See the messages above."
  fi
  say "Building. On a phone this takes roughly 20 to 45 minutes."
  ( export TRUST_CA="$ca" FALLBACK_SERVER=""; build_ipxe ) || die "$E_ENV" "The build did not finish. Run $0 proot-build again."
  echo
  box \
    "DONE. NOW, BACK IN TERMUX:" \
    "" \
    "mkdir -p ~/loader" \
    "cp \"\$PREFIX\"/var/lib/proot-distro/installed-rootfs/*$TFTP/ipxe.efi ~/loader/" \
    "cp \"\$PREFIX\"/var/lib/proot-distro/installed-rootfs/*$TFTP/undionly.kpxe ~/loader/" \
    "cd ~/netboot-android && ./netboot-android.sh import-ipxe ~/loader" \
    "" \
    "import-ipxe checks that the loader contains your certificate."
  echo
}

# =============================================================================
# Easy mode: the zero-argument screen, one plain question, and a one-tap shortcut
# =============================================================================
pick_goal() {
  local c=1
  say "${C_BOLD}What do you want to do?${C_RESET}"
  say "  1) Rescue or repair a PC          ${C_DIM}(SystemRescue: small and fast, about 4 GB of RAM)${C_RESET}"
  say "  2) Try a full desktop             ${C_DIM}(Ubuntu: about 10 GB of RAM)${C_RESET}"
  say "  3) Something else                 ${C_DIM}(shows the full list)${C_RESET}"
  if [[ $ASSUME_YES != 1 ]]; then
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Choose 1, 2 or 3 [1]: " c || c=1
  fi
  case "${c:-1}" in
    2) DISTRO=ubuntu; TARGET_ARCH=x86_64 ;;
    3) choose_target; choose_mode ;;
    *) DISTRO=systemrescue; TARGET_ARCH=x86_64 ;;
  esac
  set_distro
  save_profile
  ok "OK: $P_LABEL"
}

pc_instructions() {
  local sb_line="Secure Boot must be OFF for this route (the iPXE loader is not signed)."
  [[ $BOOT_LOADER == shim ]] && sb_line="Secure Boot may stay ON (Ubuntu route). BIOS-only PCs cannot."
  echo
  box \
    "NOW, ON THE PC YOU WANT TO BOOT:" \
    "" \
    "1. Plug it into the same network (or cable) as this phone." \
    "2. Turn it on and tap the boot-menu key right away:" \
    "     Dell F12   HP F9 or Esc   Lenovo F12 or Enter, then F12" \
    "     Asus F8 or Esc   Acer F12   Microsoft Surface: hold Volume Down" \
    "     (not sure? try F12, then Esc, then F2 to open settings)" \
    "3. Pick: Network, PXE, or IPv4 Network Boot. UEFI is fine." \
    "4. If it will not list network boot: in settings turn ON" \
    "   network boot, then try again." \
    "" \
    "$sb_line" \
    "A good sign: text scrolls here when the PC asks for its files." \
    "Stop the server with Ctrl+C when the PC has booted."
  echo
}

shortcut_cmd() {
  local dir="$HOME/.shortcuts" f
  mkdir -p "$dir"
  f="$dir/Boot-a-PC"
  atomic_write "$f" <<EOF
#!/usr/bin/env bash
# Created by netboot-android.sh: one tap starts serving with your saved settings.
exec "$SELF" --yes go
EOF
  chmod 700 "$f"
  ok "Created the one-tap shortcut: $f"
  say "To use it on Android:"
  say "  1. Install the free app Termux:Widget (same place you got Termux)."
  say "  2. Long-press your home screen > Widgets > Termux:Widget > add it."
  say "  3. Tap 'Boot-a-PC' in that widget. That is it."
  hint "Needs root already granted to Termux. It never starts by itself; you tap it."
}

# Picks the one screen that makes sense for the current state.
# Everything in order, skipping what is already done
run_all() {
  once() { local d=$1; shift; if [[ $GUIDE_REDO != 1 ]] && "$d"; then info "Already done, skipping: $1"; else "$@"; fi; }
  once g_done_deps deps
  once g_done_attest attest_init
  once g_done_sign self_sign
  once g_done_pins pins_refresh
  once g_done_ipxe build_ipxe
  fetch
  once g_done_extract extract
  once g_done_configure configure
  once g_done_report attest_report
  serve
}

easy_home() {
  if [[ ! -t 0 || ! -t 1 ]]; then interactive; return; fi
  if (( IS_PROOT )); then proot_build_flow; return; fi
  local i key setup_bad=0 note="" fixcmd=""
  load_profile && set_distro || true
  clear 2>/dev/null || true
  banner
  if [[ ! -r $PROFILE && -z $(attest_fpr) ]]; then
    box \
      "FIRST TIME HERE? I'll set everything up for you." \
      "" \
      "It takes about 20-40 minutes, mostly downloading." \
      "You only answer a couple of simple questions." \
      "Nothing is deleted. Type q at any question to stop."
    echo
    ask_yn "Start now?" y || { info "OK. Run me again whenever you are ready."; return 0; }
    echo
    pick_goal
    GUIDE_WELCOMED=1 guided
    return 0
  fi
  diagnose
  for i in "${!F_LVL[@]}"; do
    [[ ${F_LVL[$i]} == FAIL ]] || continue
    case "${F_TAG[$i]}" in
      TOOLS|ATTEST|IPXE|LOADERPIN|ISO|EXTRACT|CONFIG) setup_bad=1; note=${note:-${F_MSG[$i]}} ;;
      SELF) note=${F_MSG[$i]}; fixcmd=self ;;
      *) note=${note:-${F_MSG[$i]}}; fixcmd=${fixcmd:-heal} ;;
    esac
  done
  if (( setup_bad )); then
    box "SETUP ISN'T FINISHED" "" "$note"
    echo
    ask_yn "Continue the guided setup (it skips what is already done)?" y && guided
    return 0
  fi
  if [[ $fixcmd == self ]]; then
    self_check_soft || true
    return 0
  fi
  if [[ -n $fixcmd ]]; then
    box "ONE THING NEEDS ATTENTION" "" "$note"
    echo
    if ask_yn "Try to fix it automatically?" y; then heal || true; fi
    return 0
  fi
  heal_safe >/dev/null 2>&1 || true
  box \
    "READY.  $P_LABEL" \
    "" \
    "Enter = boot a PC now      m = full menu" \
    "s = status                 q = quit"
  echo
  read -r -p "${C_BOLD}${C_BLUE}>${C_RESET} " key || key=q
  case "${key,,}" in
    "")  with_lock go_cmd ;;
    m)   interactive ;;
    s)   status || true ;;
    *)   info "Bye." ;;
  esac
}

# =============================================================================
# Guided mode: walks through everything, one plain step at a time
# =============================================================================
GSTEP=0; GTOTAL=13

say()  { printf '%s\n' "$*"; }
hint() { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ask_yn "Question" y|n   (Enter takes the default; q quits safely)
ask_yn() {
  local q=$1 d=${2:-y} a h="[y/N]"
  [[ $d == y ]] && h="[Y/n]"
  if [[ $ASSUME_YES == 1 ]]; then   # --yes takes the suggested answer; it never overrides a "no" default
    printf '%s %s %s\n' "$q" "$h" "(--yes: ${d})"; [[ $d == y ]]; return
  fi
  while true; do
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} $q $h " a || { echo; a=""; }
    a=${a,,}
    case "$a" in
      "")     [[ $d == y ]]; return ;;
      y|yes)  return 0 ;;
      n|no)   return 1 ;;
      q|quit) echo; info "Stopped. Nothing is half-done. Start the guide again any time."; exit 0 ;;
      *)      warn "Please type y, n, or q to quit" ;;
    esac
  done
}

gstep_head() {
  GSTEP=$((GSTEP+1))
  printf '\n%s== Step %d of %d: %s ==%s\n' "${C_BOLD}${C_CYAN}" "$GSTEP" "$GTOTAL" "$1" "$C_RESET"
  shift
  local l; for l in "$@"; do say "$l"; done
}

# guided_run "Title" "Plain explanation" DONE_CHECK_FUNCTION|"" command args...

# In the guide, "something is missing" is expected before the next steps install it.
# Real blockers (root, storage, network) still stop and offer Retry.
check_soft() {
  local log rc=0
  log=$(mktemp)
  check 2>&1 | tee "$log" || true
  if ! grep -q 'required check' "$log"; then rm -f "$log"; return 0; fi
  if grep -qE 'No root|FAT/exFAT|No usable network|only [0-9]+ MB free' "$log"; then rc=1; fi
  rm -f "$log"
  echo
  if (( rc )); then
    err "Something above must be fixed first (root, storage, or network). Fix it, then choose Retry."
    return 1
  fi
  info "That is OK. The missing items are exactly what the next steps set up. Carrying on."
  return 0
}

guided_run() {
  local title=$1 why=$2 donefn=$3 a; shift 3
  # A finished step is skipped on its own. Use --redo to be offered it again.
  if [[ -n $donefn && $GUIDE_REDO != 1 ]] && "$donefn"; then
    GSTEP=$((GSTEP+1)); GUIDE_SKIPPED=$((GUIDE_SKIPPED+1))
    printf '%s[+]%s Step %d of %d: %s %s(already done, skipping)%s\n' "$C_GREEN" "$C_RESET" "$GSTEP" "$GTOTAL" "$title" "$C_DIM" "$C_RESET"
    return 0
  fi
  gstep_head "$title" "$why"
  if [[ -n $donefn ]] && "$donefn"; then
    ok "Already done."
    ask_yn "Do it again anyway?" n || return 0
  else
    ask_yn "Do this step now?" y || { warn "Skipped. Later steps may need it."; return 0; }
  fi
  while true; do
    if ( with_lock "$@" ); then ok "Finished: $title"; return 0; fi
    err "That step did not finish. Read the message above."
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} [r]etry, [s]kip, or [q]uit? " a || a=s
    case "${a,,}" in
      r|retry) ;;
      q|quit)  exit 0 ;;
      *)       warn "Skipped. You can run it later from the menu."; return 0 ;;
    esac
  done
}

g_done_deps()    { [[ -z $(missing_tools) ]]; }
g_done_check()   {   # the pre-flight only matters on a first run or when the basics are broken
  g_done_deps && [[ -n $(attest_fpr) ]] || return 1
  diagnose
  local i
  for i in "${!F_LVL[@]}"; do
    [[ ${F_LVL[$i]} == FAIL ]] || continue
    case "${F_TAG[$i]}" in DISK|FSTYPE|TOOLS) return 1 ;; esac
  done
  return 0
}
g_done_attest()  { [[ -n $(attest_fpr) ]]; }
g_done_sign()    { [[ $(self_status) == ok ]]; }
g_done_pins() {   # every server we talk to already has a valid pin
  local h
  for h in $(pin_hosts_for_target); do
    [[ -n $(active_pins "$h") ]] || return 1
  done
  return 0
}
g_done_ipxe()    { if [[ $BOOT_LOADER == shim ]]; then shim_ready; else [[ -s $TFTP/ipxe.efi ]]; fi; }
g_done_fetch()   { iso_is_verified; }
g_done_extract() {   # the layout record exists and the files it names are really there
  [[ -f $LAYOUT ]] || return 1
  ( KERNEL_REL=""; INITRD_REL=""; ROOTFS_REL=""
    # shellcheck disable=SC1090
    source "$LAYOUT"
    [[ -s $HTTP/$KERNEL_REL && -s $HTTP/$INITRD_REL ]] && { [[ -z $ROOTFS_REL ]] || [[ -s $HTTP/$ROOTFS_REL ]]; } )
}
g_done_configure() {   # configured for the current network, the chosen loader, and the current extraction
  local cfg_ip cur conf="$STATE/$DISTRO-$TARGET_ARCH.config"
  [[ -f $MANIFEST && -f $TFTP/boot.ipxe && -f $conf ]] || return 1
  [[ -f $LAYOUT && ! $LAYOUT -nt $MANIFEST ]] || return 1
  if [[ $BOOT_LOADER == shim ]]; then
    grep -q 'loader=shim' "$conf" || return 1
  else
    ! grep -q 'loader=shim' "$conf" || return 1
  fi
  cfg_ip=$(sed -n 's|^set base http://\([0-9.]*\):.*|\1|p' "$TFTP/boot.ipxe" | head -n1)
  cur=$( ( LOG_QUIET=1; resolve_network >/dev/null 2>&1 && printf '%s' "$PHONE_IP" ) 2>/dev/null || true )
  [[ -n $cur && $cur == "$cfg_ip" ]]
}
g_done_report() {   # a signed report newer than the current configuration
  local latest
  latest=$(ls -1t "$ATTEST"/reports/*.asc 2>/dev/null | head -n1 || true)
  [[ -n $latest && -f $MANIFEST && ! $MANIFEST -nt $latest ]]
}

guided_ipxe() {
  local host_cpu c
  if g_done_ipxe && [[ $GUIDE_REDO != 1 ]]; then
    GSTEP=$((GSTEP+1)); GUIDE_SKIPPED=$((GUIDE_SKIPPED+1))
    printf '%s[+]%s Step %d of %d: Boot loader %s(already in place, skipping)%s\n' "$C_GREEN" "$C_RESET" "$GSTEP" "$GTOTAL" "$C_DIM" "$C_RESET"
    return 0
  fi
  gstep_head "Get the network-boot loader (iPXE)" \
    "iPXE is the tiny program the PC runs first. It is built with YOUR key inside," \
    "so it only boots files you signed. Building takes 10-30 minutes on a phone."
  if g_done_ipxe; then ok "Already done."; ask_yn "Do it again anyway?" n || return 0; fi
  if shim_supported; then
    echo
    say "${C_BOLD}Ubuntu can use its own signed boot files, which is the easy way:${C_RESET}"
    say "  1) Ubuntu's signed boot files  ${C_GREEN}recommended: nothing to build, ready in about a minute${C_RESET}"
    hint "   Works with Secure Boot ON or OFF. For UEFI PCs (almost all since about 2012), not very old BIOS-only ones."
    say "  2) iPXE with your own certificate  ${C_DIM}(a signed chain you control; has to be built or fetched)${C_RESET}"
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Choose 1 or 2 [1]: " c || c=""
    if [[ ${c:-1} != 2 ]]; then
      BOOT_LOADER=shim; save_profile
      ( shim_fetch ) && ok "Ubuntu's signed boot files are ready" || warn "That did not finish. Run it again: $0 shim-fetch"
      return 0
    fi
    BOOT_LOADER=ipxe; save_profile
  fi
  host_cpu=$(uname -m); [[ $host_cpu == aarch64 ]] && host_cpu=arm64
  if [[ $host_cpu == "$TARGET_ARCH" ]]; then
    hint "This device matches the PC's CPU ($TARGET_ARCH), so building here works and keeps everything on this device."
    say "  1) Build it here (slow on a phone, but automatic)  ${C_GREEN}recommended${C_RESET}"
    say "  2) I built it on another computer I control: import it"
    say "  3) One-time build on GitHub, then pinned and verified"
    say "  4) Skip for now"
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Choose 1-4 [1]: " c || c=""
    case "${c:-1}" in
      1) ( build_ipxe ) && ok "iPXE built" || warn "Build did not finish. Run it again from the menu." ;;
      2) guided_ipxe_import ;;
      3) ipxe_cloud ;;
      *) warn "Skipped. configure will stop until iPXE is in place." ;;
    esac
  else
    hint "This phone is $host_cpu and the PC is $TARGET_ARCH, so it cannot compile the loader the normal way."
    say "  1) One-time build on GitHub, then pinned and verified  ${C_GREEN}default, about 5 minutes${C_RESET}"
    say "  2) Build it on this phone with an x86_64 compiler (slow, nothing leaves the phone)"
    say "  3) Build it on a $TARGET_ARCH Linux computer I control, then import it"
    say "  4) Skip for now"
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Choose 1-4 [1]: " c || c=""
    case "${c:-1}" in
      1) ipxe_cloud ;;
      2) ipxe_phone ;;
      3) ipxe_own_machine_help; guided_ipxe_import ;;
      *) warn "Skipped. configure will stop until iPXE is in place." ;;
    esac
  fi
}

ipxe_phone() {   # set up the compiler if needed, then build
  if ! xbox_ready; then
    say "First time only: this downloads a small Debian environment (about 600 MB) and an x86_64 compiler."
    ask_yn "Set it up now?" y || { warn "Skipped."; return 0; }
    ( xbox_setup ) || { warn "Setup did not finish. Run it again; it resumes."; return 1; }
  fi
  say "Building the loader on this phone. This is the slow part: about 20-45 minutes."
  hint "Keep the screen on and Termux unrestricted; if it stops, run the same step again."
  ( build_ipxe ) && ok "iPXE built on this phone" || warn "Build did not finish. Run it again from the menu."
}

ipxe_own_machine_help() {
  echo
  box \
    "BUILD THE LOADER ON A COMPUTER YOU CONTROL" \
    "" \
    "On any $TARGET_ARCH Linux computer:" \
    "1. Get this script there (same file as on the phone)." \
    "2. Copy ONLY your public certificate from the phone:" \
    "     $ATTEST/ca.crt" \
    "   (never copy anything else from that folder)" \
    "3. Check both copies match: run  ./netboot-android.sh fingerprints" \
    "   on both and compare the lines." \
    "4. On the computer run:" \
    "     TRUST_CA=ca.crt ./netboot-android.sh --arch $TARGET_ARCH build-ipxe" \
    "5. Copy ipxe.efi and undionly.kpxe from its ~/netboot/tftp back to" \
    "   a folder on this phone."
  echo
  hint "Phone to computer tips: termux-setup-storage then copy into ~/storage/downloads, or use scp."
  read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Press Enter when the two files are on this phone: " _ || true
}

guided_ipxe_import() {
  local dir
  read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Folder holding ipxe.efi and undionly.kpxe: " dir || dir=""
  ( import_ipxe "$dir" ) && ok "iPXE imported" || warn "Import did not finish. Check the folder and retry from the menu."
}

# ---- offsite backup wizard ---------------------------------------------------
save_setting() {   # NAME value -> $STATE/backup.conf (plain text, mode 600)
  local name=$1 val=$2 f="$STATE/backup.conf" tmp
  [[ $val != *\'* && $val != *$'\n'* ]] || { warn "Not saving $name: unsupported character in the value"; return 1; }
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.conf.XXXXXX")
  { [[ -f $f ]] && grep -v "^$name=" "$f" || true; printf "%s='%s'\n" "$name" "$val"; } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$f"
  printf -v "$name" '%s' "$val"
}

offsite_wizard() {
  local pf r remotes pick cf
  printf '\n%s== Offsite backups: Google One (Drive) and/or Terabox ==%s\n' "${C_BOLD}${C_CYAN}" "$C_RESET"
  say "Every backup is already saved on this device. This adds a second, encrypted copy"
  say "in the cloud, so losing the phone does not lose your keys. Totally optional."
  hint "Your files are locked with a passphrase BEFORE they leave the device."
  ask_yn "Set up cloud copies now?" y || { info "No problem. Run this again from the menu any time."; return 0; }

  # 1. passphrase
  pf=${BACKUP_GPG_PASSFILE:-$HOME/.netboot-backup-pass}
  if [[ -s $pf ]]; then
    ok "Passphrase file found: $pf"
  else
    say ""
    say "${C_BOLD}Passphrase.${C_RESET} I will make a long random one and keep it in a private file."
    warn "WRITE IT DOWN somewhere safe (a password manager). Without it the cloud copies cannot be opened."
    if ask_yn "Create it now?" y; then
      ( umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n=' > "$pf" ) || { err "Could not write $pf"; return 1; }
      chmod 600 "$pf"
      box "YOUR BACKUP PASSPHRASE (save it now)" "" "$(cat "$pf")" ""
      read -r -p "Press Enter once you have saved it... " _ || true
    else
      warn "Without a passphrase nothing is uploaded. Local backups still work."
      return 0
    fi
  fi
  save_setting BACKUP_GPG_PASSFILE "$pf"

  # 2. Google Drive
  say ""
  say "${C_BOLD}Google One storage${C_RESET} (this is your Google Drive space; uses the official rclone tool)."
  if ask_yn "Use Google One / Drive?" y; then
    if ! command -v rclone >/dev/null 2>&1; then
      if (( IS_TERMUX )); then
        ask_yn "rclone is not installed. Install it now (pkg install rclone)?" y && { pkg install -y rclone || warn "Install failed"; }
      else
        warn "rclone is not installed. Install it with your package manager, then run this again."
      fi
    fi
    if command -v rclone >/dev/null 2>&1; then
      remotes=$(rclone listremotes 2>/dev/null || true)
      if [[ -z $remotes ]]; then
        say "No cloud account is linked yet. Next I will open rclone's setup:"
        hint "Choose: n (new remote) > name it gdrive > type: drive > scope: drive.file > accept the defaults."
        hint "No browser on this device? Answer 'n' to auto config and follow its instructions."
        ask_yn "Open rclone setup now?" y && rclone config
        remotes=$(rclone listremotes 2>/dev/null || true)
      fi
      if [[ -n $remotes ]]; then
        say "Linked accounts:"; printf '  %s\n' $remotes
        read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Which one? (name with the colon, e.g. gdrive:) " pick || pick=""
        if grep -qxF "$pick" <<<"$remotes"; then
          save_setting GDRIVE_REMOTE "${pick}netboot-backups" && ok "Google Drive will receive backups in the folder netboot-backups"
        else
          warn "Not a linked account. Skipping Google Drive."
        fi
      fi
    fi
  fi

  # 3. Terabox
  say ""
  say "${C_BOLD}Terabox${C_RESET} (unofficial open-source tool; logs in with your 'ndus' cookie, like a password)."
  if ask_yn "Use Terabox?" n; then
    if [[ ! -x ${TBC_BIN:-$SRC_DIR/tbc-bin} ]]; then
      if command -v go >/dev/null 2>&1; then
        ask_yn "Build the Terabox tool now (pinned version)?" y && { ( terabox_install ) || warn "Build failed"; }
      else
        warn "Go 1.24+ is needed to build it. Install Go, then run this again."
      fi
    fi
    cf=${TERABOX_COOKIE_FILE:-$HOME/.terabox-cookie}
    if [[ ! -s $cf ]]; then
      say "Log in at terabox.com in a browser, open developer tools > Storage/Cookies, copy the value of 'ndus'."
      read -r -s -p "${C_BOLD}${C_BLUE}?${C_RESET} Paste it here (hidden), or press Enter to skip: " r || r=""; echo
      if [[ -n $r ]]; then ( umask 077; printf 'ndus=%s\n' "${r#ndus=}" > "$cf" ); chmod 600 "$cf"; ok "Saved to $cf"; fi
    fi
    if [[ -s $cf && -x ${TBC_BIN:-$SRC_DIR/tbc-bin} ]]; then
      save_setting TERABOX_COOKIE_FILE "$cf" && ok "Terabox will receive backups in /netboot-backups"
    else
      warn "Terabox is not fully set up, so it is skipped."
    fi
  fi

  # 4. automatic backups: off unless you say so
  say ""
  if ask_yn "Also take a backup automatically before each serve? (otherwise only when you run: $0 backup)" n; then
    save_setting AUTO_BACKUP 1 && ok "Automatic backups are ON"
  else
    save_setting AUTO_BACKUP 0
    info "Backups will only happen when you ask: $0 backup"
  fi

  # 5. test
  say ""
  if [[ -n ${GDRIVE_REMOTE:-}${TERABOX_COOKIE_FILE:-} ]] && ask_yn "Take a one-off test backup now to try the cloud copy?" n; then
    ( backup_create test ) || warn "The test did not finish. Your settings are saved; fix the issue and test again from the menu."
  fi
  ok "Settings saved in $STATE/backup.conf. serve and clean will use them automatically."
}

guided() {
  [[ -t 0 || $ASSUME_YES == 1 ]] || die "Guided mode needs a terminal. Run it directly in Termux or a shell."
  if (( IS_PROOT )); then proot_build_flow; return; fi
  if [[ ${GUIDE_WELCOMED:-0} != 1 ]]; then
    clear 2>/dev/null || true
    printf '\n'
    box \
      "WELCOME. I will walk you through, one small step at a time." \
      "" \
      "- Every step says what it does, in plain words." \
      "- Press Enter to accept the suggested answer (shown in capitals)." \
      "- Type q at any question to stop safely." \
      "- Nothing is deleted. Backups are optional and only" \
      "  happen when you ask (the backup step, or --backup)."
    say ""
    ask_yn "Ready to begin?" y || { info "OK. Come back any time."; return 0; }
  fi

  load_profile && set_distro || true
  if [[ -r $PROFILE && $GUIDE_REDO != 1 ]]; then
    GSTEP=$((GSTEP+1)); GUIDE_SKIPPED=$((GUIDE_SKIPPED+1))
    printf '%s[+]%s Step %d of %d: What to boot: %s %s(saved choice; change it with: %s guide --redo)%s\n' "$C_GREEN" "$C_RESET" "$GSTEP" "$GTOTAL" "$P_LABEL" "$C_DIM" "$0" "$C_RESET"
  else
    gstep_head "Choose what to boot" \
      "Now: $P_LABEL on a $TARGET_ARCH PC."
    if [[ -r $PROFILE ]]; then
      if ask_yn "Change that?" n; then pick_goal; fi
    else
      pick_goal
    fi
  fi

  guided_run "Check this device" \
    "Looks for root, tools, free space and network. Safe: it only reads things. (under a minute)" g_done_check check_soft
  guided_run "Install the tools needed" \
    "Installs packages such as dnsmasq, python, gpg. Needs internet. (2-5 minutes)" g_done_deps deps
  guided_run "Create your private keys" \
    "Makes a signing key and a small certificate authority that live only on this device." g_done_attest attest_init
  guided_run "Sign this script" \
    "Records the script's fingerprint so any later tampering is noticed." g_done_sign self_sign
  guided_run "Check the download servers" \
    "Confirms each vendor's server identity against public logs before trusting it. (about a minute)" g_done_pins pins_refresh
  guided_ipxe
  guided_run "Download and verify the Linux image" \
    "Downloads $P_LABEL and checks the vendor's signature. Large download, so use Wi-Fi. (10-40 minutes; safe to stop and resume)" g_done_fetch fetch
  guided_run "Unpack the boot files" \
    "Pulls the kernel and files the PC needs out of the image. (1-5 minutes)" g_done_extract extract
  guided_run "Sign and prepare everything" \
    "Signs the boot files with your key and writes the server settings for your current network." g_done_configure configure

  if [[ -f $STATE/offsite.asked && $GUIDE_REDO != 1 ]]; then
    GSTEP=$((GSTEP+1)); GUIDE_SKIPPED=$((GUIDE_SKIPPED+1))
    printf '%s[+]%s Step %d of %d: Cloud backups %s(already decided, skipping; change with: %s backup-setup)%s\n' "$C_GREEN" "$C_RESET" "$GSTEP" "$GTOTAL" "$C_DIM" "$0" "$C_RESET"
  else
    gstep_head "Cloud backups (optional)" \
      "Adds an encrypted offsite copy of your keys and settings to Google One and/or Terabox."
    offsite_wizard
    : > "$STATE/offsite.asked"
  fi

  guided_run "Write the signed report" \
    "A signed record of everything above that you can re-check later." g_done_report attest_report

  (( GUIDE_SKIPPED == 0 )) || info "Skipped $GUIDE_SKIPPED step(s) that were already done. (--redo shows them again.)"
  gstep_head "Start the boot server" \
    "Plug the PC into the same network (or cable), set it to network (PXE) boot," \
    "Secure Boot off, then power it on. Press Ctrl+C here to stop the server."
  hint "No backup is taken unless you ask for one (./netboot-android.sh backup, or --backup)."
  if ask_yn "Start the server now?" y; then
    run_step serve
  else
    info "Whenever you are ready, choose 'Start the PXE server' in the menu."
  fi
}

# =============================================================================
# Interactive mode
# =============================================================================
run_step() {
  if ( with_lock "$@" ); then echo; ok "Step complete"; else echo; warn "Step did not finish. Read the messages above, fix the issue, and retry."; fi
  echo
}

choose_target() {
  local choice
  echo "Select the CPU of the machine that will boot:"
  select choice in "x86_64  (Intel/AMD PCs and most laptops)" "arm64   (ARM64 machines)"; do
    case "$REPLY" in
      1) TARGET_ARCH=x86_64; break ;;
      2) TARGET_ARCH=arm64; break ;;
      *) warn "Enter 1 or 2" ;;
    esac
  done
  echo "Select the live system:"
  select choice in \
    "ubuntu        Ubuntu 26.04.1 desktop        (x86_64, arm64)" \
    "ubuntu24      Ubuntu 24.04.5.1 desktop      (x86_64)" \
    "debian        Debian 13.7 live standard     (x86_64)" \
    "fedora        Fedora Workstation 44 live    (x86_64)" \
    "arch          Arch Linux latest             (x86_64)" \
    "systemrescue  SystemRescue 13.02            (x86_64)" \
    "parrot        Parrot Security 7.4           (x86_64, arm64)"; do
    case "$REPLY" in
      1) DISTRO=ubuntu; break ;;
      2) DISTRO=ubuntu24; break ;;
      3) DISTRO=debian; break ;;
      4) DISTRO=fedora; break ;;
      5) DISTRO=arch; break ;;
      6) DISTRO=systemrescue; break ;;
      7) DISTRO=parrot; break ;;
      *) warn "Enter a number from 1 to 7" ;;
    esac
  done
  ( set_distro ) || { warn "That combination is not available"; return 0; }
  set_distro
  ok "Target: $P_LABEL / $TARGET_ARCH (client RAM about $CLIENT_RAM_GB GB)"
}

choose_mode() {
  local choice
  echo "How is the PC connected?"
  select choice in \
    "auto    Detect" \
    "proxy   Same Wi-Fi/router network (router keeps handing out addresses)" \
    "direct  Ethernet cable straight from this device to the PC"; do
    case "$REPLY" in
      1) DHCP_MODE=auto; break ;;
      2) DHCP_MODE=proxy; break ;;
      3) DHCP_MODE=direct; break ;;
      *) warn "Enter 1, 2, or 3" ;;
    esac
  done
  ok "Network mode: $DHCP_MODE"
}

interactive() {
  banner
  if [[ -z $(attest_fpr) ]]; then
    printf '%sFirst time here? Choose 1: the guided setup does everything for you.%s\n\n' "$C_YELLOW" "$C_RESET"
  fi
  local options=(
    "GUIDED SETUP: walk me through everything (start here)"
    "GO: fix small problems, then start the server"
    "Status: is everything ready?"
    "Heal: find and fix problems"
    "Start the PXE server"
    "Set up cloud backups (Google One / Terabox)"
    "Back up the working folder now"
    "Restore the working folder from a backup"
    "Pre-flight check"
    "Install dependencies"
    "Create attestation identity"
    "Self-sign this script"
    "Refresh certificate pins from CT"
    "Build iPXE from source"
    "Import iPXE built elsewhere"
    "Download and verify the ISO"
    "Extract boot files"
    "Configure (sign boot files, write dnsmasq)"
    "Write signed attestation report"
    "Change target"
    "Change network mode"
    "Show fingerprints for external comparison"
    "Verify latest attestation report"
    "Show HTTP log (last 50 lines)"
    "Clean up"
    "Verify this script against GitHub"
    "Help"
    "Quit"
  )
  local choice dir
  PS3="Choose a number: "
  select choice in "${options[@]}"; do
    case "$choice" in
      GUIDED*)                      guided ;;
      "GO:"*)                       run_step go_cmd ;;
      "Status:"*)                   status || true ;;
      "Heal:"*)                     run_step heal ;;
      "Start the PXE server")       run_step serve ;;
      "Set up cloud backups"*)      offsite_wizard ;;
      "Back up the working"*)       run_step backup_create manual ;;
      "Restore the working"*)       backup_list; read -r -p "Archive to restore: " dir; run_step restore "$dir" ;;
      "Pre-flight check")           run_step check ;;
      "Install dependencies")       run_step deps ;;
      "Create attestation"*)        run_step attest_init ;;
      "Self-sign"*)                 run_step self_sign ;;
      "Refresh certificate"*)       run_step pins_refresh ;;
      "Build iPXE"*)                run_step build_ipxe ;;
      "Import iPXE"*)               read -r -p "Directory holding the iPXE binaries: " dir; run_step import_ipxe "$dir" ;;
      "Download and verify"*)       run_step fetch ;;
      "Extract boot files")         run_step extract ;;
      "Configure"*)                 run_step configure ;;
      "Write signed"*)              run_step attest_report ;;
      "Change target")              choose_target ;;
      "Change network mode")        choose_mode ;;
      "Show fingerprints"*)         show_fingerprints ;;
      "Verify latest"*)             run_step verify_attest ;;
      "Show HTTP log"*)             tail -n 50 "$HTTP_LOG" 2>/dev/null || warn "No log yet" ;;
      "Clean up")                   run_step clean ;;
      "Verify this script"*)        run_step verify_upstream ;;
      "Help")                       usage; echo ;;
      "Quit")                       break ;;
      *)                            warn "Enter a number from 1 to ${#options[@]}" ;;
    esac
    PS3="Choose a number: "
  done
  ok "Goodbye"
}

# =============================================================================
# Help
# =============================================================================
usage() {
  cat <<EOF
netboot-android.sh $SCRIPT_VERSION
Verified PXE live boot of Linux ISOs from a rooted Android phone or any Linux host.

START HERE
  $0                         Run with no arguments and press Enter. It asks one simple
                             question the first time, then sets everything up for you.
  $0 go                      Already set up? Start serving a PC right now.
  $0 status                  What is ready, and what needs attention.
  $0 shortcut                Make a one-tap "Boot-a-PC" button (Termux:Widget).

USAGE
  $0 [--distro NAME] [--arch ARCH] [--mode MODE] [--iface IF] COMMAND [args]
  $0 -h | --help
  $0                         (no arguments: the easy screen for your situation)
  $0 --yes COMMAND           (accept suggested answers; never trusts a changed script)

FIRST RUN, IN ORDER
  check, deps, attest-init, self-sign, pins refresh, build-ipxe (or import-ipxe),
  fetch, extract, configure, attest, serve

COMMANDS
  go                    Heal, check, and start serving with your last settings (daily/emergency)
  status                One-screen health report: what is ready, what needs attention
  heal                  Fix safe problems automatically (stale locks, leftovers, address change)
  doctor                Same report as status, with the exact fix command for each problem
  verify [deep]         Re-check served files now (deep = full re-hash of everything)
  easy                  The zero-argument screen (same as running with no arguments)
  menu                  Full menu of every step
  shortcut              Create the one-tap Termux:Widget "Boot-a-PC" shortcut
  guide [--redo]        Step-by-step; finished steps are skipped on their own (--redo offers them again) guided setup (best for first time)
  ui, interactive       Menu of every step (no arguments does this too)
  backup-setup          Guided setup of Google One / Terabox cloud backups
  check                 Pre-flight: root, tools, ports 67/69/4011/$HTTP_PORT, storage,
                        network, pins, attestation, artifacts
  deps                  Install packages (Termux pkg, apt, dnf, pacman, or apk)
  attest-init           Create the local attestation key and boot code-signing CA
  self-sign             Record and sign this script's SHA-256
  fingerprints          Print values to compare against copies on another device
  release-stamp TIME    Stamp the planned upload time (UTC, e.g. 2026-10-09T18:00:00Z)
                        into this script and print its release code
  verify-upstream       Fetch this script from GitHub (pinned TLS) and prove the local
                        copy is byte-identical to the one committed at RELEASE_TIME
  pins refresh [HOST..] Validate each host against Certificate Transparency and
                        update pins. A served key missing from CT is reported as
                        interception and the old pins are kept.
  pins show             List pins in use
  build-ipxe            Build iPXE at IPXE_COMMIT with the boot CA and a
                        verify-first script embedded
  import-ipxe DIR       Use iPXE binaries built on another machine
  shim-fetch            Ubuntu only: get Ubuntu's own signed boot files (shim + grub). No building,
                        works with Secure Boot on or off (UEFI PCs). Use with --shim or BOOT_LOADER=shim
  ipxe-phone            Build the x86_64 loader ON THIS PHONE (sets up a small compiler first)
  proot-build           Inside a proot Linux on the phone: build the loader for your Termux install
  xbuild-setup          Only set up that on-phone compiler (Debian via proot-distro)
  ipxe-cloud            Build the loader on GitHub instead (WEAKER trust; asks first)
  ipxe-request          Print what to paste into the GitHub build page
  ipxe-fetch [new]      Download, verify, pin, and install the GitHub-built loader (new = replace the pinned one)
  fetch                 Download the ISO and verify it against the vendor key
  extract               Pull kernel, initrd, root image (and microcode) from the ISO
  configure             Sign boot files, write boot.ipxe, dnsmasq.conf, and the manifest
  attest                Write a signed attestation report (also served to clients)
  verify-attest [FILE]  Check a report's signature and re-hash every listed file
  backup                Archive the working folder (SHA-256 sidecar) into $BACKUP_DIR
  terabox-install       Build the unofficial Terabox CLI (fcr--/tbc, pinned) for offsite backups
  backup-list           List backups, newest first
  backup-auto on|off    Make backups automatic before serve and clean (off is the default); when on it
                        skips itself if nothing changed. --backup asks for one on a single run
  restore ARCHIVE       Verify a backup, save the current state, then restore it
                        (add --dry-run to only list what would be replaced)
  serve                 Backs up the working folder, integrity gate, then HTTP + dnsmasq (DHCP/TFTP) as root
  logs                  Follow the HTTP access log
  selinux {status|permissive|enforcing}
                        Android only. Permissive lowers device security.
  clean                 Back up, stop servers, remove generated files (keeps ISOs, keys, pins)
  all                   deps, attest-init, self-sign, pins refresh, build-ipxe, fetch,
                        extract, configure, attest, serve

OPTIONS
  --distro NAME   ubuntu (default), ubuntu24, debian, fedora, arch, systemrescue, parrot
  --arch ARCH     x86_64 (default) or arm64: the CPU of the PC that boots, not this device
  --mode MODE     auto (default), proxy (existing router DHCP), direct (cable to the PC)
  --iface IF      Network interface (default: detected)

TARGETS
  ubuntu        Ubuntu 26.04.1 desktop       x86_64, arm64   client RAM ~10 GB (arm64 ~7)
  ubuntu24      Ubuntu 24.04.5.1 desktop     x86_64          client RAM ~10 GB
  debian        Debian 13.7 live standard    x86_64          client RAM ~4 GB
  fedora        Fedora Workstation 44 live   x86_64          client RAM ~6 GB
  arch          Arch Linux latest            x86_64          client RAM ~4 GB
  systemrescue  SystemRescue 13.02           x86_64          client RAM ~4 GB
  parrot        Parrot Security 7.4          x86_64, arm64   client RAM ~12 GB

ENVIRONMENT VARIABLES
  NETBOOT_HOME          Working directory                         (default: ~/netboot)
  IFACE                 Network interface                         (default: detected)
  NET                   Network address override                  (default: detected)
  HTTP_PORT             HTTP port                                 (default: 8000)
  DHCP_MODE             auto | proxy | direct                     (default: auto)
  DIRECT_CIDR           Address used in direct mode               (default: 10.42.0.1/24)
  ISO_URL               Override the ISO URL (must still be listed in the vendor checksums)
  SUMS_URL, SUMS_SIG_URL, ISO_SIG_URL
                        Override verification sources
  KEY_FPR               Override the vendor signing key fingerprint
  BOOT_ARGS             Replace kernel arguments. Placeholders: @BASE@ @ROOTFS@ @BASEDIR@ @ISO@
  VERIFIED_BOOT         1 (default): signed boot chain. 0: unsigned (stock iPXE)
  DEEP_VERIFY           auto (default): small files fully hashed, big ones by signed fingerprint,
                        then a low-priority full re-hash runs while serving. 1/full: re-hash
                        everything first. 0: hash only files under 512 MB
  INCLUDE_UCODE         1 (default): load CPU microcode for Arch and SystemRescue
  IPXE_COMMIT           iPXE commit to build                      (default: $DEFAULT_IPXE_COMMIT)
  IPXE_CROSS            Cross-compiler prefix, e.g. x86_64-linux-gnu-
  IPXE_CC               Compiler (default: gcc if present, else clang)
  TRUST_CA              CA certificate when building iPXE on another machine
  FALLBACK_SERVER       Server IP baked into iPXE if DHCP gives none
  MIN_FREE_MB           Storage required by check                 (default: per target)
  CT_BOOTSTRAP=1        Reach the CT API without a pin, once, if its pins expired
  ALLOW_UNPINNED=1      Fetch transport-trusted content without a pin (not recommended)
  ALLOW_UNVERIFIED=1    Accept an ISO with no verified signature (not recommended)
  ACCEPT_SCRIPT_CHANGE=1  Run even though the script changed since self-sign
  AUTO_BACKUP           0 (default): backups only when you ask. 1: also back up before serve and clean (only if something changed)
  BACKUP_DIR            Where backups go                          (default: ~/netboot-backups)
  BACKUP_KEEP           Newest backups kept                       (default: 5)
  BACKUP_DL             1: include downloads/ (ISOs) in backups   (default: 0)
  BACKUP_UPLOAD_CMD     Offsite hook, run as: CMD FILE.gpg after each backup
  BACKUP_GPG_PASSFILE   Passphrase file; the archive is AES256-encrypted before upload
  TERABOX_COOKIE_FILE   File with your Terabox ndus cookie (or export TERABOX_COOKIE)
  TERABOX_DIR           Remote Terabox folder                     (default: /netboot-backups)
  GDRIVE_REMOTE         rclone Drive remote:folder for Google One storage (needs rclone)
  UPSTREAM_REPO         Repo for verify-upstream    (default: $DEFAULT_UPSTREAM_REPO)
  UPSTREAM_BRANCH       Branch for verify-upstream                (default: main)
  EXPECT_CODE           Release code you recorded; verify-upstream must match it

BUILDING iPXE FOR A DIFFERENT CPU
  Most phones are arm64 and most PCs are x86_64, so the phone usually cannot build
  the PC's iPXE natively. Copy $ATTEST/ca.crt and this script to any x86_64 Linux
  machine, then run:
    TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
  Copy ~/netboot/tftp/ipxe.efi and undionly.kpxe back to the phone and run:
    ./netboot-android.sh import-ipxe DIR

EXAMPLES
  $0 --distro debian all                       Full verified setup for Debian live
  $0 pins refresh                              Re-validate pins against CT
  $0 --mode direct --iface eth0 serve          Cable from a USB Ethernet adapter to the PC
  $0 --distro parrot --arch arm64 fetch        Download and verify Parrot for an ARM64 PC
  $0 verify-attest                             Prove nothing changed since the last report
  $0 fingerprints                              Values to compare on another device
EOF
}

# =============================================================================
# Argument parsing and dispatch
# =============================================================================
parse_args() {
  while (( $# )); do
    case "$1" in
      -h|--help)  usage; exit 0 ;;
      --dry-run)  DRY_RUN=1 ;;
      -y|--yes)   ASSUME_YES=1 ;;
      --no-backup) AUTO_BACKUP=0 ;;
      --redo)      GUIDE_REDO=1 ;;
      --backup)    AUTO_BACKUP=1 ;;
      --shim|--secure-boot) BOOT_LOADER=shim; CLI_SET+=" BOOT_LOADER" ;;
      --iso)      [[ $# -ge 2 ]] || die "--iso requires a path"; ISO_FILE="$2"; shift ;;
      --iso=*)    ISO_FILE="${1#*=}" ;;
      --distro)   [[ $# -ge 2 ]] || die "--distro requires a value"; DISTRO="$2"; CLI_SET+=" DISTRO"; shift ;;
      --distro=*) DISTRO="${1#*=}"; CLI_SET+=" DISTRO" ;;
      --arch)     [[ $# -ge 2 ]] || die "--arch requires a value"; TARGET_ARCH="$2"; CLI_SET+=" TARGET_ARCH"; shift ;;
      --arch=*)   TARGET_ARCH="${1#*=}"; CLI_SET+=" TARGET_ARCH" ;;
      --mode)     [[ $# -ge 2 ]] || die "--mode requires a value"; DHCP_MODE="$2"; CLI_SET+=" DHCP_MODE"; shift ;;
      --mode=*)   DHCP_MODE="${1#*=}"; CLI_SET+=" DHCP_MODE" ;;
      --iface)    [[ $# -ge 2 ]] || die "--iface requires a value"; IFACE="$2"; CLI_SET+=" IFACE"; shift ;;
      --iface=*)  IFACE="${1#*=}"; CLI_SET+=" IFACE" ;;
      -*)         die "Unknown option: $1 (try --help)" ;;
      *)          if [[ -z $COMMAND ]]; then COMMAND="$1"; else POSITIONAL+=("$1"); fi ;;
    esac
    shift
  done
}

if [[ ${NETBOOT_SOURCE_ONLY:-0} == 1 ]]; then return 0; fi   # lets tests source the functions
parse_args "$@"
COMMAND="${COMMAND:-ui}"
set_distro
case "$COMMAND" in
  help|fingerprints|release-stamp|verify-upstream) ;;
  *) guard_root; log_rotate ;;
esac
case "$COMMAND" in
  deps|attest-init|self-sign|pins|build-ipxe|ipxe-phone|shim-fetch|xbuild-setup|import-ipxe|proot-build|fetch|extract|configure|attest|serve|clean|backup|restore|terabox-install|all)
    acquire_lock ;;
esac

case "$COMMAND" in
  help|attest-init|self-sign|fingerprints|deps|release-stamp|verify-upstream|status|doctor|shortcut) ;;
  ui|easy|guide|guided|go) self_check_soft ;;
  *) self_check ;;
esac

case "$COMMAND" in
  ui|easy)       easy_home ;;
  menu|interactive) interactive ;;
  shortcut)      shortcut_cmd ;;
  guide|guided)   guided ;;
  go)             acquire_lock; go_cmd ;;
  status)         status || exit 1 ;;
  doctor)         doctor || exit 1 ;;
  heal)           acquire_lock; heal || exit 1 ;;
  verify)         resolve_network; load_layout; if [[ ${POSITIONAL[0]:-} == deep ]]; then DEEP_VERIFY=1; fi; verify_manifest ;;
  backup-setup)   offsite_wizard ;;
  help)           usage ;;
  check)          check ;;
  deps)           deps ;;
  attest-init)    attest_init ;;
  self-sign)      self_sign ;;
  fingerprints)   show_fingerprints ;;
  release-stamp)  release_stamp "${POSITIONAL[0]:-}" ;;
  verify-upstream) verify_upstream ;;
  pins)
    case "${POSITIONAL[0]:-show}" in
      refresh)
        if (( ${#POSITIONAL[@]} > 1 )); then pins_refresh "${POSITIONAL[@]:1}"; else pins_refresh; fi ;;
      show) pins_show ;;
      *) die "Usage: $0 pins {refresh [HOST...]|show}" ;;
    esac ;;
  build-ipxe)     build_ipxe ;;
  import-ipxe)    import_ipxe "${POSITIONAL[0]:-}" ;;
  ipxe-phone)     ipxe_phone ;;
  shim-fetch)     shim_fetch ;;
  proot-build)    proot_build_flow ;;
  xbuild-setup)   xbox_setup ;;
  ipxe-request)   ipxe_request ;;
  ipxe-fetch)     ipxe_fetch "${POSITIONAL[0]:-}" ;;
  ipxe-cloud)     ipxe_cloud ;;
  fetch)          fetch ;;
  extract)        extract ;;
  configure)      configure ;;
  attest)         resolve_network; attest_report ;;
  verify-attest)  verify_attest "${POSITIONAL[0]:-}" ;;
  backup)         backup_create manual ;;
  backup-list)    backup_list ;;
  backup-auto)    backup_auto_cmd "${POSITIONAL[0]:-}" ;;
  terabox-install) terabox_install ;;
  restore)        restore "${POSITIONAL[0]:-}" ;;
  serve)          serve ;;
  logs)           logs ;;
  selinux)        selinux_ctl "${POSITIONAL[0]:-status}" ;;
  clean)          clean ;;
  all)
    run_all ;;
  *)
    known_cmds="go status heal doctor guide easy menu check deps fetch extract configure serve backup restore shortcut verify clean logs"
    sugg=$( { compgen -W "$known_cmds" -- "${COMMAND:0:2}" || compgen -W "$known_cmds" -- "${COMMAND:0:1}" || true; } | tr '\n' ' ')
    err "Unknown command: $COMMAND"
    say "Did you mean: ${sugg:-go, status, heal, guide}"
    say "Start here: run  $0  with no arguments, and press Enter."
    exit "$E_USAGE" ;;
esac
