#!/usr/bin/env bash
# =============================================================================
#  setup.sh - install netboot-android, check it against GitHub, start setup
# =============================================================================
#
#  On the phone (Termux) or a Linux machine:
#      bash setup.sh                 install, verify, then run the guided setup
#      bash setup.sh --update        pull the latest version and verify it again
#
#  On a Linux PC, when the phone asks for a signed boot loader:
#      bash setup.sh --pc-helper PHONE_IP:PORT
#
#  Every step skips what is already done, so running it twice is safe.
#  This file is short on purpose. Read it before you run it.
# =============================================================================
set -euo pipefail
umask 022

REPO_URL="${REPO_URL:-https://github.com/SecTrollz/netboot-android.git}"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-$HOME/netboot-android}"
HELPER_HOME="${HELPER_HOME:-$HOME/netboot-pc-helper}"
HELPER_ARCH="${HELPER_ARCH:-x86_64}"

IS_TERMUX=0; [[ ${PREFIX:-} == *com.termux* ]] && IS_TERMUX=1
IS_ANDROID=0; [[ -e /system/build.prop || -n ${ANDROID_ROOT:-} ]] && IS_ANDROID=1

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
say()  { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[-]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

short_code() { local h=${1,,}; printf '%s-%s-%s-%s\n' "${h:0:4}" "${h:4:4}" "${h:8:4}" "${h:12:4}"; }

as_root() {
  if [[ $(id -u) -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else die "Root is needed to install packages. Install sudo or run as root."; fi
}

# install_pkgs ROLE   (ROLE: phone | builder)
install_pkgs() {
  local role=$1 t missing=0
  local -a need=(git curl openssl gpg python3)
  [[ $role == builder ]] && need+=(make gcc perl)
  for t in "${need[@]}"; do command -v "$t" >/dev/null 2>&1 || missing=1; done
  (( missing )) || { ok "Required tools are installed"; return 0; }
  say "Installing required tools"
  if (( IS_TERMUX )); then
    pkg install -y git curl openssl gnupg python
  elif command -v apt-get >/dev/null 2>&1; then
    as_root apt-get update
    if [[ $role == builder ]]; then as_root apt-get install -y git curl openssl gnupg python3 build-essential perl liblzma-dev
    else as_root apt-get install -y git curl openssl gnupg python3; fi
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y git curl openssl gnupg2 python3 gcc make perl xz-devel
  elif command -v pacman >/dev/null 2>&1; then
    as_root pacman -Sy --needed --noconfirm git curl openssl gnupg python base-devel perl xz
  elif command -v apk >/dev/null 2>&1; then
    as_root apk add git curl openssl gnupg python3 build-base perl xz-dev
  else
    die "Unknown package manager. Install these yourself: ${need[*]}"
  fi
}

check_root_android() {
  (( IS_ANDROID )) || return 0
  if [[ "$(su -c 'id -u' 2>/dev/null || true)" != 0 ]]; then
    die "This phone needs root. Open Magisk (or KernelSU), allow root for Termux, then run this again."
  fi
  ok "Root is available"
}

# Clones, or updates with --update. Prints the commit in use.
get_repo() {
  local update=$1
  if [[ -d $DEST/.git ]]; then
    if (( update )); then
      say "Updating $DEST"
      git -C "$DEST" fetch --quiet origin "$BRANCH"
      git -C "$DEST" merge --quiet --ff-only "origin/$BRANCH" \
        || die "Your copy has local changes that conflict with the update. Move $DEST aside and run this again."
    fi
  else
    say "Downloading netboot-android from $REPO_URL"
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$DEST"
  fi
  chmod +x "$DEST/netboot-android.sh"
  ok "Using commit $(git -C "$DEST" rev-parse HEAD)"
}

# Proves the local script is the copy committed on GitHub at its release time
verify_copy() {
  local script="$DEST/netboot-android.sh" a
  if ! grep -q '^RELEASE_TIME="[0-9][0-9]*"' "$script"; then
    warn "This version has no release stamp yet, so it cannot be checked against a published code."
    warn "It came from $REPO_URL at commit $(git -C "$DEST" rev-parse --short HEAD)."
    read -r -p "Press Enter to continue, or Ctrl+C to stop. " a
    return 0
  fi
  UPSTREAM_REPO="$REPO_URL" UPSTREAM_BRANCH="$BRANCH" "$script" verify-upstream \
    || die "This copy does NOT match the release on GitHub. Do not use it."
  echo "Compare the code above with the code the author published (README or release notes)."
  read -r -p "Is it the same? [y/N] " a
  [[ $a == [yY]* ]] || die "Stopped. Do not use this copy until the codes match."
}

install_shortcut() {
  local bin
  if (( IS_TERMUX )); then bin="$PREFIX/bin"; else bin="$HOME/.local/bin"; fi
  mkdir -p "$bin"
  ln -sf "$DEST/netboot-android.sh" "$bin/netboot"
  ok "Shortcut installed: netboot"
  case ":$PATH:" in *":$bin:"*) ;; *) warn "Add $bin to your PATH to use 'netboot' from anywhere." ;; esac
}

phone_setup() {
  local update=$1
  say "Setting up netboot-android on this $( ((IS_TERMUX)) && echo phone || echo machine)"
  check_root_android
  install_pkgs phone
  get_repo "$update"
  verify_copy
  # A verified update is a deliberate change: record the new script hash
  if [[ -s ${NETBOOT_HOME:-$HOME/netboot}/attest/attest.fpr ]]; then
    "$DEST/netboot-android.sh" self-sign >/dev/null && ok "Recorded the verified script in your attestation"
  fi
  install_shortcut
  echo
  ok "Installed. Starting the guided setup."
  exec "$DEST/netboot-android.sh" setup
}

# ----------------------------------------------------------------------------
# PC helper: builds signed iPXE for the phone, using the phone's boot CA
# ----------------------------------------------------------------------------
pc_helper() {
  local phone=$1 phone_ip port work tftp ca code a my_ip f
  [[ $phone =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$ ]] || die "Usage: bash setup.sh --pc-helper PHONE_IP:PORT"
  phone_ip=${phone%%:*}
  [[ $phone == *:* ]] || phone="$phone:8000"
  (( IS_ANDROID )) && die "Run --pc-helper on a Linux PC, not on the phone."

  install_pkgs builder
  get_repo 0
  verify_copy

  work=$HELPER_HOME; tftp="$work/home/tftp"; ca="$work/ca.crt"
  mkdir -p "$work"
  say "Fetching the boot CA from the phone at $phone"
  curl -fsS --connect-timeout 10 --max-time 60 -o "$ca" "http://$phone/attest-ca.crt" \
    || die "Could not reach the phone. Is it showing the PC HELPER screen, and are both on the same network?"
  openssl x509 -in "$ca" -noout 2>/dev/null || die "What the phone sent is not a certificate"
  code=$(short_code "$(openssl x509 -in "$ca" -outform DER | sha256sum | awk '{print $1}')")
  echo
  printf '    CA code:  %s%s%s\n\n' "$B" "$code" "$N"
  read -r -p "Does the phone show exactly this CA code? [y/N] " a
  [[ $a == [yY]* ]] || die "Stopped. The CA did not match, so something between the PC and the phone changed it."

  say "Building signed iPXE for $HELPER_ARCH (a few minutes)"
  NETBOOT_HOME="$work/home" TRUST_CA="$ca" FALLBACK_SERVER="$phone_ip" \
    "$DEST/netboot-android.sh" --arch "$HELPER_ARCH" build-ipxe \
    || die "The build failed. Read the messages above."

  my_ip=$(ip -4 route get "$phone_ip" 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
  [[ -n $my_ip ]] || die "Could not work out this PC's address on the phone's network"
  local hport=8090
  while (echo >"/dev/tcp/$my_ip/$hport") 2>/dev/null; do hport=$((hport+1)); done

  python3 -m http.server --bind "$my_ip" --directory "$tftp" "$hport" >/dev/null 2>&1 &
  local pid=$!
  trap 'kill '"$pid"' 2>/dev/null' EXIT
  sleep 1
  kill -0 "$pid" 2>/dev/null || die "Could not start the file share on $my_ip:$hport"

  echo
  printf '%s  READY%s\n\n' "$B" "$N"
  printf '  On the phone, type this address:  %s%s:%s%s\n\n' "$B" "$my_ip" "$hport" "$N"
  echo "  The phone will then show these codes. They must match exactly:"
  for f in "$tftp"/*.efi "$tftp"/*.kpxe; do
    [[ -s $f ]] || continue
    printf '    %-16s %s\n' "$(basename "$f")" "$(short_code "$(sha256sum "$f" | awk '{print $1}')")"
  done
  echo
  read -r -p "Press Enter after the phone says 'Signed iPXE installed' to stop sharing. " a
  ok "Done. You can close this window."
}

usage() {
  sed -n '4,13p' "$0" | sed 's/^#  \{0,1\}//'
}

main() {
  local update=0
  case "${1:-}" in
    -h|--help)   usage ;;
    --update)    phone_setup 1 ;;
    --pc-helper) [[ -n ${2:-} ]] || die "Usage: bash setup.sh --pc-helper PHONE_IP:PORT"; pc_helper "$2" ;;
    "")          phone_setup "$update" ;;
    *)           usage; die "Unknown option: $1" ;;
  esac
}

main "$@"
