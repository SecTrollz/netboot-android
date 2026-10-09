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

SCRIPT_VERSION="2026.10.08-final"
RELEASE_TIME=""   # upload time (UTC epoch) set by release-stamp; must equal the upstream commit time

# =============================================================================
# Platform detection
# =============================================================================
IS_TERMUX=0; [[ ${PREFIX:-} == *com.termux* ]] && IS_TERMUX=1
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
IFACE="${IFACE:-}"
HTTP_PORT="${HTTP_PORT:-8000}"
DISTRO="${DISTRO:-ubuntu}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"
DHCP_MODE="${DHCP_MODE:-auto}"            # auto | proxy | direct
DIRECT_CIDR="${DIRECT_CIDR:-10.42.0.1/24}"
VERIFIED_BOOT="${VERIFIED_BOOT:-1}"
DEEP_VERIFY="${DEEP_VERIFY:-1}"
INCLUDE_UCODE="${INCLUDE_UCODE:-1}"
IPXE_COMMIT="${IPXE_COMMIT:-$DEFAULT_IPXE_COMMIT}"
IPXE_CROSS="${IPXE_CROSS:-}"
IPXE_CC="${IPXE_CC:-}"
FALLBACK_SERVER="${FALLBACK_SERVER:-}"
TRUST_CA="${TRUST_CA:-}"
ALLOW_UNPINNED="${ALLOW_UNPINNED:-0}"
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"
ACCEPT_SCRIPT_CHANGE="${ACCEPT_SCRIPT_CHANGE:-0}"
CT_BOOTSTRAP="${CT_BOOTSTRAP:-0}"
UPSTREAM_REPO="${UPSTREAM_REPO:-$DEFAULT_UPSTREAM_REPO}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
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

AUTO_BACKUP="${AUTO_BACKUP:-1}"           # 1: back up the working folder before serve and clean
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
DIRECT_ADDED=0
POWER_TWEAKED=0
COMMAND=""
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
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[-]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

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
need()       { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. Run: $0 deps"; }
today()      { date -u +%F; }
now_iso()    { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
sha256_of()  { sha256sum "$1" | awk '{print $1}'; }
sha512_of()  { sha512sum "$1" | awk '{print $1}'; }
file_size()  { stat -c %s "$1" 2>/dev/null || wc -c <"$1" | tr -d ' '; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
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
    die "Root is required for: $cmd"
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
import sys
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

class Handler(SimpleHTTPRequestHandler):
    def list_directory(self, path):
        self.send_error(403, "Directory listing disabled")
        return None

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - [%s] %s\n" % (self.client_address[0],
                         self.log_date_time_string(), fmt % args))
        sys.stderr.flush()

bind, port, directory = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.allow_reuse_address = True
server = ThreadingHTTPServer((bind, port), partial(Handler, directory=directory))
server.serve_forever()
PYEOF

  cat > "$LIB/findbytes.py" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
sys.exit(0 if bytes.fromhex(sys.argv[2]) in data else 1)
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
  done < <(ip_q -4 -o addr show | awk '{print $2, $4}')

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
  local host=$1 tmp=$2 dom after page n last f
  local -a files=() doms=("$host")
  local parent=${host#*.}
  [[ $parent == *.* ]] && doms+=("$parent")
  for dom in "${doms[@]}"; do
    after=""; page=0
    while (( page < 40 )); do
      f="$tmp/ct.$dom.$page.json"
      ct_get "$CT_API?domain=$dom&expand=dns_names&expand=issuer&expand=revocation${after:+&after=$after}" "$f" || return 1
      read -r n last < <("$PYTHON" "$LIB/ct_parse.py" page "$f") || return 1
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
  if (( ${#hosts[@]} == 0 )); then mapfile -t hosts < <(pin_hosts_for_target); fi

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
    if ( vfetch "$src" "$f" protected ); then
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

  (( agree >= 2 )) || die "Key $KEY_FPR was confirmed by only $agree source(s). Need at least 2."
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
  read -r sigkey primary < <(awk '$2=="VALIDSIG"{print $3, $NF}' "$st" | head -n1) || return 1
  [[ $primary == "$KEY_FPR" ]] || return 1
  while read -r _ rest; do
    if grep -qw "$sigkey" <<<"$rest"; then count=$((count+1)); fi
  done < "$GNUPG_HOME/source-fprs"
  (( count >= 2 )) || return 1
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

self_check() {
  if [[ ! -s $ATTEST/script.sha256 || ! -s $ATTEST/script.sha256.asc ]]; then
    warn "Self-attestation is not set up. Run: $0 attest-init, then $0 self-sign"
    return 0
  fi
  local st cur rec
  st=$(mktemp)
  gpg --homedir "$ATTEST_GNUPG" --batch --no-tty --status-file "$st" \
      --verify "$ATTEST/script.sha256.asc" "$ATTEST/script.sha256" >/dev/null 2>&1 || true
  if ! awk -v f="$(attest_fpr)" '$2=="VALIDSIG" && $NF==f {found=1} END{exit !found}' "$st"; then
    rm -f "$st"
    die "The signed script hash record failed verification. The attestation files may have been altered."
  fi
  rm -f "$st"
  cur=$(sha256_of "$SELF")
  rec=$(awk '{print $1}' "$ATTEST/script.sha256")
  if [[ $cur != "$rec" ]]; then
    if [[ $ACCEPT_SCRIPT_CHANGE == 1 ]]; then
      warn "Script changed since it was signed (ACCEPT_SCRIPT_CHANGE=1). Run $0 self-sign to record the new version."
    else
      die "This script changed since it was self-signed (now $cur). If you edited it yourself, run: $0 self-sign"
    fi
  fi
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
    pkg install -y dnsmasq python libarchive curl iproute2 procps openssl gnupg git \
                   clang make perl binutils liblzma xz-utils coreutils
    termux-wake-lock 2>/dev/null || warn "termux-wake-lock unavailable (install Termux:API to keep the CPU awake)"
  elif command -v apt-get >/dev/null 2>&1; then
    run_root "apt-get update && apt-get install -y dnsmasq python3 libarchive-tools curl iproute2 openssl gnupg git build-essential perl liblzma-dev"
  elif command -v dnf >/dev/null 2>&1; then
    run_root "dnf install -y dnsmasq python3 bsdtar curl iproute openssl gnupg2 git gcc make perl xz-devel"
  elif command -v pacman >/dev/null 2>&1; then
    run_root "pacman -Sy --needed --noconfirm dnsmasq python libarchive curl iproute2 openssl gnupg git base-devel perl xz"
  elif command -v apk >/dev/null 2>&1; then
    run_root "apk add dnsmasq python3 libarchive-tools curl iproute2 openssl gnupg git build-base perl xz-dev"
  else
    die "Unknown package manager. Install manually: dnsmasq python3 bsdtar curl iproute2 openssl gnupg git gcc make perl liblzma headers"
  fi
  DNSMASQ=$(find_bin dnsmasq || true)
  PYTHON=$(find_bin python3 || find_bin python || true)
  ok "Packages installed"
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

  read -r _ code < <(release_code "$SELF" "$epoch") || die "Could not compute the release code"
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
  read -r commit ctime < <(git -C "$repo" log -1 --format='%H %ct' "upstream/$UPSTREAM_BRANCH" -- "$UPSTREAM_PATH") \
    || die "No commit touching $UPSTREAM_PATH on $UPSTREAM_BRANCH"
  up=$(mktemp)
  git -C "$repo" show "$commit:$UPSTREAM_PATH" > "$up" || { rm -f "$up"; die "Cannot read $UPSTREAM_PATH at $commit"; }
  info "Upstream: $UPSTREAM_BRANCH @ $commit, committed $(epoch_to_iso "$ctime")"

  if [[ $ctime != "$RELEASE_TIME" ]]; then
    rm -f "$up"
    audit "UPSTREAM TIME-MISMATCH commit=$commit upstream=$ctime local=$RELEASE_TIME"
    die "TIME MISMATCH. Upstream commit time $(epoch_to_iso "$ctime") is not this script's RELEASE_TIME $(epoch_to_iso "$RELEASE_TIME")."
  fi

  local lhex lcode uhex ucode
  read -r lhex lcode < <(release_code "$SELF" "$RELEASE_TIME") || die "Could not hash $SELF"
  read -r uhex ucode < <(release_code "$up" "$ctime") || die "Could not hash the upstream copy"

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
    if [[ $lhex == "$uhex" ]]; then
      err "The local file matches upstream, but upstream is not the release you recorded."
    elif ! diff <(trust_block "$up") <(trust_block "$SELF") >/dev/null; then
      err "Hard-coded trust data differs (upstream '<', local '>'):"
      diff <(trust_block "$up") <(trust_block "$SELF") >&2 || true
    else
      err "Trust data is identical; other lines differ."
    fi
    rm -f "$up"
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
  else
    warn "Could not confirm the trust anchor inside $(basename "$bin"). If it is missing, every boot will fail closed at imgverify."
  fi
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
  if (( ! native )) && [[ -z $IPXE_CROSS ]]; then
    die "This device is $HOST_ARCH and the target is $TARGET_ARCH. Build on a $TARGET_ARCH Linux machine with this same script, or set IPXE_CROSS (for example IPXE_CROSS=x86_64-linux-gnu-). Then copy the binaries over with: $0 import-ipxe DIR"
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
    mopts=(TRUST="$ca" EMBED="$embed")
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
  make -C "$src/src" clean >/dev/null 2>&1 || true
  make -C "$src/src" -j"$(nproc_n)" "${mopts[@]}" "${targets[@]}" \
    || die "iPXE build failed. On Termux, clang builds are not guaranteed. Building on a Linux PC with gcc is the reliable route."

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
iso_is_verified() {
  [[ -s $ISO && -s $ISO_VERIFIED ]] || return 1
  local sha size mtime
  read -r sha size mtime < "$ISO_VERIFIED" || return 1
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
    verify_detached "$ISO_SIG_FILE" "$file" "ISO image" || return 1
    iso_sig=1
  fi

  info "Hashing the ISO"
  sha256=$(sha256_of "$file")
  if [[ -n $list ]]; then
    if [[ $SUMS_ALGO == sha256 ]]; then algohash=$sha256; else algohash=$(sha512_of "$file"); fi
    expect=$(sums_lookup "$list" "$orig" "$SUMS_ALGO")
    if [[ -z $expect ]]; then
      err "$orig is not listed in the checksum file. The vendor may have published a newer release; set ISO_URL."
      return 1
    fi
    if [[ $algohash != "$expect" ]]; then
      err "$SUMS_ALGO MISMATCH for $orig (expected $expect, got $algohash)"
      return 1
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

  local target code rc
  if [[ -s $ISO ]]; then
    target=$ISO
    info "ISO present but not verified. Verifying now."
  else
    target="$ISO.part"
    info "Downloading $ISO_NAME (about ${P_ISO_MB} MB). Resumable: re-run to continue."
    rc=0
    code=$(curl -L --proto-redir '=https' -C - --retry 5 --retry-delay 5 --connect-timeout 30 \
                -# -o "$ISO.part" -w '%{http_code}' "$ISO_URL") || rc=$?
    if [[ $code == 416 ]]; then
      info "Download was already complete"
    elif (( rc != 0 )); then
      die "Download interrupted (curl error $rc). Re-run fetch to resume."
    fi
  fi

  if [[ -z $SUMS_URL && -z $ISO_SIG_URL ]]; then
    [[ $target == "$ISO.part" ]] && mv -f "$ISO.part" "$ISO"
    rm -f "$ISO_VERIFIED"
    warn "ISO is UNVERIFIED (ALLOW_UNVERIFIED=1)"
    return 0
  fi

  if ( verify_download "$target" "$ISO_NAME" ); then
    [[ $target == "$ISO.part" ]] && mv -f "$ISO.part" "$ISO"
    mv -f "$VERIFY_REC.tmp" "$VERIFY_REC"
    printf '%s %s %s\n' "$(cat "$VERIFY_REC.sha")" "$(file_size "$ISO")" "$(file_mtime "$ISO")" > "$ISO_VERIFIED"
    rm -f "$VERIFY_REC.sha"
    ok "ISO verified: $ISO"
  else
    rm -f "$VERIFY_REC.tmp" "$VERIFY_REC.sha"
    if [[ $target == "$ISO.part" ]]; then rm -f "$ISO.part"; fi
    die "Verification FAILED. The download was discarded."
  fi
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
  bsdtar -xf "$ISO" -C "$HTTP" "${files[@]}" || die "Extraction failed"

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
  } > "$LAYOUT"
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
  require_ipxe_matches_ca
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
  else
    warn "VERIFIED_BOOT=0: boot files are NOT signed and the client will not check them"
  fi

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
    if [[ $TARGET_ARCH == x86_64 ]]; then
      echo "pxe-service=tag:!ipxe,x86PC,\"netboot-android (BIOS)\",undionly"
      echo "pxe-service=tag:!ipxe,X86-64_EFI,\"netboot-android (UEFI)\",ipxe.efi"
      echo "pxe-service=tag:!ipxe,BC_EFI,\"netboot-android (UEFI)\",ipxe.efi"
    else
      echo "pxe-service=tag:!ipxe,ARM64_EFI,\"netboot-android (ARM64 UEFI)\",ipxe-arm64.efi"
    fi
    echo "# First match wins"
    echo "dhcp-boot=tag:ipxe,boot.ipxe"
    if [[ $TARGET_ARCH == x86_64 ]]; then
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
    echo "iface=$IFACE mode=$MODE net=$NET/$PREFIX_LEN phone=$PHONE_IP port=$HTTP_PORT"
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
  for f in $(ipxe_files_for_arch); do echo "tftp/$f"; done
  [[ -s $TFTP/undionly.0 ]] && echo "tftp/undionly.0"
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

write_manifest() {
  local rel f h tmp
  tmp="$MANIFEST.tmp"
  : > "$tmp"
  while IFS= read -r rel; do
    f="$ROOT/$rel"
    [[ -f $f ]] || die "Manifest: missing $rel"
    if [[ $FAMILY == casper && $rel == "http/$ROOTFS_REL" ]] && iso_is_verified; then
      h=$(iso_verified_sha)
    else
      h=$(sha256_of "$f")
    fi
    printf '%s %s %s\n' "$h" "$(file_size "$f")" "$rel" >> "$tmp"
  done < <(manifest_files)
  mv -f "$tmp" "$MANIFEST"
}

verify_manifest() {
  [[ -f $MANIFEST ]] || die "No manifest. Run: $0 configure"
  local h s rel f cur bad=0 checked=0
  info "Integrity gate: checking every served file (DEEP_VERIFY=$DEEP_VERIFY)"
  while read -r h s rel; do
    f="$ROOT/$rel"
    if [[ ! -f $f ]]; then err "MISSING: $rel"; bad=$((bad+1)); continue; fi
    if [[ $(file_size "$f") != "$s" ]]; then err "SIZE CHANGED: $rel"; bad=$((bad+1)); continue; fi
    if [[ $DEEP_VERIFY == 1 ]] || (( s < 536870912 )); then
      cur=$(sha256_of "$f")
      if [[ $cur != "$h" ]]; then err "HASH MISMATCH: $rel"; bad=$((bad+1)); continue; fi
    fi
    checked=$((checked+1))
  done < "$MANIFEST"
  (( bad == 0 )) || die "Integrity gate FAILED ($bad file(s)). Refusing to serve. Re-run extract and configure."
  ok "Integrity gate passed ($checked files)"
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
    die "Backup failed (unreadable files? run: sudo chown -R \$(id -u) $ROOT). Set AUTO_BACKUP=0 to skip."
  fi
  tar -tzf "$out.part" >/dev/null 2>&1 || { rm -f "$out.part"; die "Backup archive failed its read-back test"; }
  mv -f "$out.part" "$out"
  ( cd "$BACKUP_DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
  chmod 600 "$out" "$out.sha256" 2>/dev/null || true
  ok "Backup written: $out ($(file_size "$out") bytes)"
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
  local i
  for i in "${!cmds[@]}"; do
    info "Uploading $(basename "$enc") to ${labels[$i]}"
    if bash -c "${cmds[$i]}" _ "$enc"; then ok "${labels[$i]} upload done"; else warn "${labels[$i]} upload failed. Local backup is intact: $f"; fi
  done
  rm -f "$enc"
}

backup_prune() {
  [[ $BACKUP_KEEP =~ ^[0-9]+$ ]] && (( BACKUP_KEEP > 0 )) || return 0
  local f n=0
  while IFS= read -r f; do
    n=$((n+1))
    if (( n > BACKUP_KEEP )); then rm -f -- "$f" "$f.sha256"; fi
  done < <(ls -1t "$BACKUP_DIR"/netboot-*.tar.gz 2>/dev/null || true)
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
  [[ $AUTO_BACKUP == 1 ]] || { warn "AUTO_BACKUP=0: skipping the pre-run backup"; return 0; }
  [[ -d $ROOT ]] || return 0
  backup_create "auto-$1"
}

restore() {
  local f=${1:-}
  [[ -n $f ]] || { backup_list; die "Usage: $0 restore ARCHIVE   (a file from the list above)"; }
  [[ -f $f ]] || f="$BACKUP_DIR/$f"
  need tar
  backup_verify "$f"
  kill_servers
  [[ -d $ROOT ]] && backup_create "pre-restore"
  warn "Restoring $f over $ROOT (files in the backup replace current copies; others are left alone)"
  run_root "chown -R $(id -u):$(id -g) '$ROOT'" >/dev/null 2>&1 || true
  tar -C "$(dirname "$ROOT")" -xzpf "$f" || die "Restore failed. The pre-restore backup is in $BACKUP_DIR"
  ok "Restored. Run: $0 check, then $0 configure and $0 serve"
}

# =============================================================================
# Serving
# =============================================================================
require_ready() {
  [[ -n $DNSMASQ && -x $DNSMASQ ]] || die "dnsmasq not found. Run: $0 deps"
  [[ -n $PYTHON ]] || die "python3 not found. Run: $0 deps"
  [[ -f $DNSMASQ_CONF && -f $LIB/httpd.py ]] || die "Not configured. Run: $0 --distro $DISTRO --arch $TARGET_ARCH configure"
  load_layout
  require_ipxe_matches_ca
}

setup_direct() {
  local ip=${DIRECT_CIDR%/*}
  if ! ip_q -4 -o addr show dev "$IFACE" | grep -q "inet $ip/"; then
    info "Assigning $DIRECT_CIDR to $IFACE"
    run_root "ip link set $IFACE up && ip addr add $DIRECT_CIDR dev $IFACE" || die "Could not assign $DIRECT_CIDR to $IFACE"
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
  DIRECT_ADDED=0
}

power_save_off() {
  if (( IS_ANDROID )); then
    if run_root "command -v iw >/dev/null 2>&1 && iw dev $IFACE set power_save off" >/dev/null 2>&1; then
      ok "Wi-Fi power save disabled on $IFACE (iw)"; POWER_TWEAKED=1; return 0
    fi
    if run_root "cmd wifi force-hi-perf-mode enabled" >/dev/null 2>&1; then
      ok "Wi-Fi high-performance mode enabled"; POWER_TWEAKED=1; return 0
    fi
    warn "Could not change Wi-Fi power save. Keep the screen on and Termux set to unrestricted battery use."
  fi
}

power_save_restore() {
  (( POWER_TWEAKED )) || return 0
  run_root "cmd wifi force-hi-perf-mode disabled" >/dev/null 2>&1 || true
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
  echo
  info "Servers stopped"
}

serve() {
  resolve_network
  require_ready
  [[ $MODE == direct ]] && setup_direct
  resolve_network

  grep -q "^interface=$IFACE$" "$DNSMASQ_CONF" && grep -q "$PHONE_IP:$HTTP_PORT" "$TFTP/boot.ipxe" \
    || die "Network changed since configure (now $IFACE $PHONE_IP). Run: $0 configure"

  auto_backup serve
  verify_manifest

  if port_in_use tcp "$HTTP_PORT"; then die "TCP $HTTP_PORT is in use. Set HTTP_PORT=... or run: $0 clean"; fi
  if port_in_use udp 67; then warn "UDP 67 is in use. dnsmasq may fail to bind (see selinux or hotspot notes)."; fi
  if port_in_use udp 69; then warn "UDP 69 is in use. TFTP may fail to bind."; fi

  trap cleanup EXIT
  trap 'exit 130' INT TERM

  (( IS_TERMUX )) && { termux-wake-lock 2>/dev/null || true; }
  power_save_off

  mkdir -p "$RUN"
  info "Starting the HTTP server on $PHONE_IP:$HTTP_PORT (log: $HTTP_LOG)"
  printf '\n--- server start %s ---\n' "$(now_iso)" >> "$HTTP_LOG"
  "$PYTHON" "$LIB/httpd.py" "$PHONE_IP" "$HTTP_PORT" "$HTTP" >> "$HTTP_LOG" 2>&1 &
  SERVE_HTTP_PID=$!
  sleep 1
  kill -0 "$SERVE_HTTP_PID" 2>/dev/null || die "HTTP server failed to start. See $HTTP_LOG"

  local vb_text="ON (signed, client verifies)"
  [[ $VERIFIED_BOOT == 1 ]] || vb_text="OFF"
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
    "Live HTTP log  : $0 logs" \
    "Press Ctrl+C to stop."
  echo

  info "Starting dnsmasq ($MODE DHCP + TFTP) as root"
  local ldp=""
  (( IS_TERMUX )) && ldp="LD_LIBRARY_PATH=$PREFIX/lib "
  run_root "${ldp}$DNSMASQ --no-daemon --conf-file=$DNSMASQ_CONF" \
    || die "dnsmasq exited. If it could not bind a port, check: $0 selinux status, and whether a hotspot or another DHCP/TFTP service holds ports 67/69."
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
  avail_mb=$(df -Pm "$ROOT" | awk 'NR==2{print $4}')
  if (( avail_mb >= MIN_FREE_MB )); then
    ok "Storage: $avail_mb MB free (need $MIN_FREE_MB MB for $DISTRO)"
  else
    err "Storage: only $avail_mb MB free (need $MIN_FREE_MB MB for $DISTRO)"; fails=$((fails+1))
  fi

  if ( resolve_network ) >/dev/null 2>&1; then
    resolve_network
    link_state=$(ip_q -o link show "$IFACE")
    ok "Network: $IFACE $PHONE_IP/$PREFIX_LEN, mode $MODE${link_state:+, link up}"
    (( IS_HOTSPOT )) && warn "$IFACE looks like a hotspot. Android's DHCP server may block port 67."
    if [[ $MODE == proxy ]]; then
      info "Proxy mode needs the PC on the same network segment as $IFACE. Guest Wi-Fi and AP client isolation block PXE."
    fi
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

  if [[ -s $IPXE_BUILT ]]; then ok "iPXE: $(head -n1 "$IPXE_BUILT")"; else warn "iPXE not built or imported yet"; fi
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
# Guided mode: walks through everything, one plain step at a time
# =============================================================================
GSTEP=0; GTOTAL=13

say()  { printf '%s\n' "$*"; }
hint() { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# ask_yn "Question" y|n   (Enter takes the default; q quits safely)
ask_yn() {
  local q=$1 d=${2:-y} a h="[y/N]"
  [[ $d == y ]] && h="[Y/n]"
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
guided_run() {
  local title=$1 why=$2 donefn=$3 a; shift 3
  gstep_head "$title" "$why"
  if [[ -n $donefn ]] && "$donefn"; then
    ok "Already done."
    ask_yn "Do it again anyway?" n || return 0
  else
    ask_yn "Do this step now?" y || { warn "Skipped. Later steps may need it."; return 0; }
  fi
  while true; do
    if ( "$@" ); then ok "Finished: $title"; return 0; fi
    err "That step did not finish. Read the message above."
    read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} [r]etry, [s]kip, or [q]uit? " a || a=s
    case "${a,,}" in
      r|retry) ;;
      q|quit)  exit 0 ;;
      *)       warn "Skipped. You can run it later from the menu."; return 0 ;;
    esac
  done
}

g_done_attest()  { [[ -n $(attest_fpr) ]]; }
g_done_sign()    { [[ -s $ATTEST/script.sha256.asc ]]; }
g_done_ipxe()    { [[ -s $TFTP/ipxe.efi ]]; }
g_done_fetch()   { iso_is_verified; }
g_done_extract() { [[ -f $LAYOUT ]]; }

guided_ipxe() {
  local host_cpu want c dir
  gstep_head "Get the network-boot loader (iPXE)" \
    "iPXE is the tiny program the PC runs first. It is built with YOUR key inside," \
    "so it only boots files you signed."
  if g_done_ipxe; then ok "Already done."; ask_yn "Do it again anyway?" n || return 0; fi
  host_cpu=$(uname -m); [[ $host_cpu == aarch64 ]] && host_cpu=arm64
  if [[ $host_cpu == "$TARGET_ARCH" ]]; then want=1
    hint "This device matches the PC's CPU ($TARGET_ARCH), so building here works."
  else want=2
    hint "This device is $host_cpu but the PC is $TARGET_ARCH. Easiest: build on any x86_64 Linux"
    hint "computer (see README, 'Building iPXE for a different CPU'), then choose 2."
  fi
  say "  1) Build it here (slow on a phone, but automatic)"
  say "  2) I already built it on another computer: import it"
  say "  3) Skip for now"
  read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Choose 1, 2 or 3 [$want]: " c || c=""
  c=${c:-$want}
  case "$c" in
    1) ( build_ipxe ) && ok "iPXE built" || warn "Build did not finish. Run it again from the menu." ;;
    2) read -r -p "${C_BOLD}${C_BLUE}?${C_RESET} Folder holding ipxe.efi and undionly.kpxe: " dir || dir=""
       ( import_ipxe "$dir" ) && ok "iPXE imported" || warn "Import did not finish. Check the folder and retry from the menu." ;;
    *) warn "Skipped. configure will stop until iPXE is in place." ;;
  esac
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

  # 4. test
  say ""
  if ask_yn "Run a test backup now to try it out?" y; then
    ( backup_create test ) || warn "The test did not finish. Your settings are saved; fix the issue and test again from the menu."
  fi
  ok "Settings saved in $STATE/backup.conf. serve and clean will use them automatically."
}

guided() {
  [[ -t 0 ]] || die "Guided mode needs a terminal. Run it directly in Termux or a shell."
  clear 2>/dev/null || true
  printf '\n'
  box \
    "WELCOME. I will walk you through, one small step at a time." \
    "" \
    "- Every step says what it does, in plain words." \
    "- Press Enter to accept the suggested answer (shown in capitals)." \
    "- Type q at any question to stop safely." \
    "- Nothing is deleted. A backup of your working folder is taken" \
    "  before the server starts."
  say ""
  ask_yn "Ready to begin?" y || { info "OK. Come back any time."; return 0; }

  gstep_head "Choose what to boot and how it connects" \
    "Now: $P_LABEL on a $TARGET_ARCH PC, network mode '$DHCP_MODE'."
  if ask_yn "Change that?" n; then choose_target; choose_mode; set_distro; fi

  guided_run "Check this device" \
    "Looks for root, tools, free space and network. Safe: it only reads things." "" check
  guided_run "Install the tools needed" \
    "Installs packages such as dnsmasq, python, gpg. Needs internet." "" deps
  guided_run "Create your private keys" \
    "Makes a signing key and a small certificate authority that live only on this device." g_done_attest attest_init
  guided_run "Sign this script" \
    "Records the script's fingerprint so any later tampering is noticed." g_done_sign self_sign
  guided_run "Check the download servers" \
    "Confirms each vendor's server identity against public logs before trusting it." "" pins_refresh
  guided_ipxe
  guided_run "Download and verify the Linux image" \
    "Downloads $P_LABEL and checks the vendor's signature. Large download: use Wi-Fi." g_done_fetch fetch
  guided_run "Unpack the boot files" \
    "Pulls the kernel and files the PC needs out of the image." g_done_extract extract
  guided_run "Sign and prepare everything" \
    "Signs the boot files with your key and writes the server settings for your current network." "" configure

  gstep_head "Cloud backups (optional)" \
    "Adds an encrypted offsite copy of your keys and settings to Google One and/or Terabox."
  offsite_wizard

  guided_run "Write the signed report" \
    "A signed record of everything above that you can re-check later." "" attest_report

  gstep_head "Start the boot server" \
    "Plug the PC into the same network (or cable), set it to network (PXE) boot," \
    "Secure Boot off, then power it on. Press Ctrl+C here to stop the server."
  hint "A backup of your working folder is taken first, automatically."
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
  if ( "$@" ); then echo; ok "Step complete"; else echo; warn "Step did not finish. Read the messages above, fix the issue, and retry."; fi
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

USAGE
  $0 [--distro NAME] [--arch ARCH] [--mode MODE] [--iface IF] COMMAND [args]
  $0 -h | --help
  $0                         (no arguments starts the interactive menu)

FIRST RUN, IN ORDER
  check, deps, attest-init, self-sign, pins refresh, build-ipxe (or import-ipxe),
  fetch, extract, configure, attest, serve

COMMANDS
  guide                 Step-by-step guided setup (best for first time)
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
  fetch                 Download the ISO and verify it against the vendor key
  extract               Pull kernel, initrd, root image (and microcode) from the ISO
  configure             Sign boot files, write boot.ipxe, dnsmasq.conf, and the manifest
  attest                Write a signed attestation report (also served to clients)
  verify-attest [FILE]  Check a report's signature and re-hash every listed file
  backup                Archive the working folder (SHA-256 sidecar) into $BACKUP_DIR
  terabox-install       Build the unofficial Terabox CLI (fcr--/tbc, pinned) for offsite backups
  backup-list           List backups, newest first
  restore ARCHIVE       Verify a backup, save the current state, then restore it
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
  DEEP_VERIFY           1 (default): full re-hash before serving. 0: hash files under 512 MB
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
  AUTO_BACKUP           1 (default): back up before serve and clean. 0: skip
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
      --distro)   [[ $# -ge 2 ]] || die "--distro requires a value"; DISTRO="$2"; shift ;;
      --distro=*) DISTRO="${1#*=}" ;;
      --arch)     [[ $# -ge 2 ]] || die "--arch requires a value"; TARGET_ARCH="$2"; shift ;;
      --arch=*)   TARGET_ARCH="${1#*=}" ;;
      --mode)     [[ $# -ge 2 ]] || die "--mode requires a value"; DHCP_MODE="$2"; shift ;;
      --mode=*)   DHCP_MODE="${1#*=}" ;;
      --iface)    [[ $# -ge 2 ]] || die "--iface requires a value"; IFACE="$2"; shift ;;
      --iface=*)  IFACE="${1#*=}" ;;
      -*)         die "Unknown option: $1 (try --help)" ;;
      *)          if [[ -z $COMMAND ]]; then COMMAND="$1"; else POSITIONAL+=("$1"); fi ;;
    esac
    shift
  done
}

parse_args "$@"
COMMAND="${COMMAND:-ui}"
set_distro

case "$COMMAND" in
  help|attest-init|self-sign|fingerprints|deps|release-stamp|verify-upstream) ;;
  *) self_check ;;
esac

case "$COMMAND" in
  ui|interactive) interactive ;;
  guide|guided)   guided ;;
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
  fetch)          fetch ;;
  extract)        extract ;;
  configure)      configure ;;
  attest)         resolve_network; attest_report ;;
  verify-attest)  verify_attest "${POSITIONAL[0]:-}" ;;
  backup)         backup_create manual ;;
  backup-list)    backup_list ;;
  terabox-install) terabox_install ;;
  restore)        restore "${POSITIONAL[0]:-}" ;;
  serve)          serve ;;
  logs)           logs ;;
  selinux)        selinux_ctl "${POSITIONAL[0]:-status}" ;;
  clean)          clean ;;
  all)
    deps
    attest_init
    [[ -s $ATTEST/script.sha256.asc ]] || self_sign
    pins_refresh
    build_ipxe
    fetch
    extract
    configure
    attest_report
    serve ;;
  *) usage; die "Unknown command: $COMMAND" ;;
esac
