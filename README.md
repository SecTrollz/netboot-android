# NETBOOT-ANDROID

## HI, BILLY MAYS HERE!

**ARE YOU TIRED OF USB STICKS?!** Tired of burning discs? Tired of digging through your junk drawer for a flash drive that's STILL got your cousin's wedding photos on it?!

**WELL PUT DOWN THAT USB STICK, BECAUSE NOW THERE'S NETBOOT-ANDROID!**

It's ONE bash script, `netboot-android.sh`, that turns your rooted Android phone (running Termux) or any Linux machine into a **VERIFIED PXE BOOT SERVER!** Plug your PC into the network, tell it to boot from the network, and BAM! It pulls a live Linux system straight off your phone. **NO USB STICK! NO DISC! NO KIDDING!**

---

## HERE'S HOW IT WORKS!

1. Your PC shouts, "I NEED TO BOOT!"
2. Your phone answers and hands over **iPXE** over TFTP!
3. iPXE grabs the kernel, the initrd, and the root image over HTTP!
4. **LINUX BOOTS! IT'S THAT EASY!**

---

## BUT WAIT, IT CHECKS EVERYTHING!

Other boot servers just hand over files and hope for the best. **NOT THIS ONE!** Every link in the chain gets checked:

- ✅ **VENDOR KEYS!** Fingerprints are built right in. Each key is fetched from at least TWO independent sources, and they have to agree!
- ✅ **VENDOR SIGNATURES!** An ISO is accepted ONLY when a signature from the vendor's key checks out!
- ✅ **TLS PINNING!** Download servers are pinned by public key and checked against **Certificate Transparency logs!** If a server shows a key that's NOT in CT, that's interception, and the script says so!
- ✅ **YOUR OWN SIGNING KEYS!** A GPG key and a code-signing CA, generated right on YOUR device!
- ✅ **iPXE BUILT FROM SOURCE!** At a pinned commit, with YOUR CA baked in. It REFUSES to run the boot script, kernel, or initrd unless the signature verifies!
- ✅ **INTEGRITY GATE!** Every served file is re-hashed against the manifest BEFORE the servers start!
- ✅ **SIGNED ATTESTATION REPORTS!** Tie it all together, and you can re-verify any time!

**ALL THAT, AND IT'S JUST ONE SCRIPT!**

---

## BUT WAIT, THERE'S MORE! CHOOSE YOUR FLAVOR!

| `--distro`     | What you get                  | CPU            | PC RAM needed |
|----------------|-------------------------------|----------------|---------------|
| `ubuntu`       | Ubuntu 26.04.1 desktop        | x86_64, arm64  | ~10 GB (arm64 ~7) |
| `ubuntu24`     | Ubuntu 24.04.5.1 desktop      | x86_64         | ~10 GB |
| `debian`       | Debian 13.7 live standard     | x86_64         | ~4 GB |
| `fedora`       | Fedora Workstation 44 live    | x86_64         | ~6 GB |
| `arch`         | Arch Linux (latest)           | x86_64         | ~4 GB |
| `systemrescue` | SystemRescue 13.02            | x86_64         | ~4 GB |
| `parrot`       | Parrot Security 7.4           | x86_64, arm64  | ~12 GB |

**SEVEN DISTROS!** And `--arch` is the CPU of the PC that's BOOTING, not your phone!

---

## WHAT DO YOU NEED?! ALMOST NOTHING!

- A **rooted** Android phone with Termux (give Termux root in Magisk or KernelSU), OR a Linux machine with sudo!
- Free storage! About 3 GB to 17 GB depending on the distro! The `check` command tells you!
- The PC on the same network as the phone, OR a cable straight to it!
- On the PC: **PXE boot ON, Secure Boot OFF!**

---

## ORDER NOW! (JUST RUN THESE!)

```sh
./netboot-android.sh check          # is everything here?
./netboot-android.sh deps           # install packages
./netboot-android.sh attest-init    # make your keys and CA
./netboot-android.sh self-sign      # sign the script's own hash
./netboot-android.sh pins refresh   # check pins against CT
./netboot-android.sh build-ipxe     # build iPXE (or import-ipxe DIR)
./netboot-android.sh fetch          # download and verify the ISO
./netboot-android.sh extract        # pull out kernel, initrd, rootfs
./netboot-android.sh configure      # sign boot files, write dnsmasq conf
./netboot-android.sh attest         # signed report
./netboot-android.sh serve          # start the servers
```

**TOO MANY STEPS?! NO PROBLEM!** Just call:

```sh
./netboot-android.sh --distro debian all
```

**ONE COMMAND!** Or run it with no arguments for a **GUIDED MENU!**

---

## PICK YOUR NETWORK MODE!

- 📡 `--mode proxy`: Your router keeps handing out addresses, and the phone just adds the boot info! Guest Wi-Fi and client isolation will block it!
- 🔌 `--mode direct`: A cable from the phone (USB Ethernet) straight to the PC! The phone does DHCP itself!
- 🤖 `--mode auto`: It picks for you!

**PRO TIP:** The phone's own hotspot is unreliable, because Android's DHCP server may be sitting on port 67!

---

## PHONE IS ARM64 AND YOUR PC IS x86_64?! WE'VE GOT YOU COVERED!

Your phone can't build the PC's iPXE natively. Copy `~/netboot/attest/ca.crt` and the script to any x86_64 Linux machine and run:

```sh
TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
```

Copy `ipxe.efi` and `undionly.kpxe` back to the phone, then:

```sh
./netboot-android.sh import-ipxe DIR
```

**IT'S THAT EASY!**

---

## MORE COMMANDS! AT NO EXTRA CHARGE!

| Command | What it does |
|---|---|
| `fingerprints` | Values to compare against a copy on ANOTHER device! |
| `verify-attest` | Checks a signed report and re-hashes every file! |
| `pins show` | Lists the pins in use! |
| `logs` | Follows the HTTP log! |
| `selinux status\|permissive\|enforcing` | Android only! Permissive lowers device security, so set it back to `enforcing` after! |
| `clean` | Stops servers, removes generated files (keeps ISOs, keys, pins)! |

Run `./netboot-android.sh --help` for EVERY environment variable!

---

## TROUBLESHOOTING! WE'VE GOT ANSWERS!

- **"PIN MISMATCH"?** Either the site rotated its certificate (run `pins refresh HOST`) or someone is tampering with your connection. DON'T download over that network!
- **dnsmasq won't start?** Something else holds port 67 or 69. Check your hotspot, other DHCP/TFTP services, and SELinux!
- **"Network changed since configure"?** Your IP moved. Run `configure` again!
- **"Script changed since self-sign"?** If YOU edited it, run `self-sign` again. If you DIDN'T, investigate!
- **Boot stops at `imgverify`?** The iPXE binaries were built with a different CA. Rebuild iPXE!

---

## THE FINE PRINT! (YOU'VE GOT TO READ IT!)

Here's what netboot-android does NOT do, so there are no surprises:

- The big root image the initrd downloads AFTER boot (Ubuntu ISO, Debian/Parrot squashfs, Fedora squashfs) is **NOT** signature-checked on the client! Arch and SystemRescue DO check theirs!
- Self-verification is tamper EVIDENCE. Whoever can edit the script can edit the check! Compare the `fingerprints` output against a copy on another device!
- Embedded pins and vendor data were collected on **2026-10-08**. Run `pins refresh` on your own device before first use!
- Test on a machine you can afford to break!

Licensed under Apache-2.0. See `LICENSE`.

## **NETBOOT-ANDROID! BOOT LINUX FROM YOUR PHONE! ORDER NOW!**
