 # HI, BILLY MAYS HERE FOR NETBOOT-ANDROID!

**BOOT STUBBORN, STUCK-ON, CAN'T-FIND-THE-USB-STICK PCs IN SECONDS!**

You've seen it. You've been there. You need Linux on a PC, and you're crawling around the floor looking for a USB stick. Then you find one, and it's got a *tax return from 2014* on it! **THERE HAS TO BE A BETTER WAY!**

**THERE IS! NETBOOT-ANDROID!**

It's ONE bash script, `netboot-android.sh`, and it turns your rooted Android phone (running Termux) or ANY Linux machine into a **VERIFIED PXE BOOT SERVER!** Your PC boots straight off the network and pulls a live Linux system from your phone. **NO USB STICK! NO DISC! NO FOOLIN'!**

---

## LET ME SHOW YOU HOW IT WORKS!

Watch this!

1. Your PC yells, "I NEED TO BOOT!"
2. Your phone answers and hands it **iPXE** over TFTP! *Boom!*
3. iPXE grabs the kernel, the initrd, and the root image over HTTP! *Snap!*
4. **LINUX BOOTS RIGHT ON YOUR SCREEN!** *That's right!*

---

## BUT HOW DO I KNOW IT'S SAFE?! HERE'S THE POWER OF VERIFICATION!

Other boot servers just hand over files and **CROSS THEIR FINGERS!** Not this one! Every single link gets checked:

- ✅ **VENDOR KEYS!** Fingerprints are built right in! Each key comes from at least TWO independent sources, and they have to agree!
- ✅ **VENDOR SIGNATURES!** The ISO is accepted ONLY when the vendor's signature verifies!
- ✅ **TLS PINNING!** Download servers are pinned by public key and checked against **Certificate Transparency logs!** A key that's not in CT? That's interception, and the script SAYS SO!
- ✅ **YOUR OWN SIGNING KEYS!** A GPG key and a code-signing CA, made right on YOUR device!
- ✅ **iPXE BUILT FROM SOURCE!** At a pinned commit, with YOUR CA baked in! It REFUSES to run the boot script, kernel, or initrd unless the signature checks out!
- ✅ **INTEGRITY GATE!** Every served file is re-hashed BEFORE the servers start!
- ✅ **SIGNED ATTESTATION REPORTS!** Re-verify any time you want!

**CHECKED! SIGNED! VERIFIED! IT'S ALL IN ONE SCRIPT!**

---

## BUT WAIT! THERE'S MORE! SEVEN DISTROS!

Order now and you get **SEVEN** live systems, **ALL IN THE SAME SCRIPT!**

| `--distro`     | What you get                  | CPU            | PC RAM needed |
|----------------|-------------------------------|----------------|---------------|
| `ubuntu`       | Ubuntu 26.04.1 desktop        | x86_64, arm64  | ~10 GB (arm64 ~7) |
| `ubuntu24`     | Ubuntu 24.04.5.1 desktop      | x86_64         | ~10 GB |
| `debian`       | Debian 13.7 live standard     | x86_64         | ~4 GB |
| `fedora`       | Fedora Workstation 44 live    | x86_64         | ~6 GB |
| `arch`         | Arch Linux (latest)           | x86_64         | ~4 GB |
| `systemrescue` | SystemRescue 13.02            | x86_64         | ~4 GB |
| `parrot`       | Parrot Security 7.4           | x86_64, arm64  | ~12 GB |

`--arch` is the CPU of the PC that's BOOTING, not your phone!

---

## HOW MUCH?! YOU'D EXPECT TO PAY $99! $59! EVEN $29.99!

**NOT SO FAST!** It's **FREE!** Licensed under Apache-2.0! *(Just pay separate shipping and handling. Kidding! There's no shipping. It's a bash script.)*

---

## WHAT YOU NEED! (NOT MUCH!)

- A **rooted** Android phone with Termux (give Termux root in Magisk or KernelSU), OR a Linux machine with sudo!
- Free storage! About 3 GB to 17 GB depending on the distro! The `check` command tells you!
- The PC on the same network as the phone, OR a cable straight to it!
- On the PC: **PXE boot ON! Secure Boot OFF!**

---

## CALL NOW! (JUST KIDDING, JUST RUN THESE!)

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

**TOO MANY STEPS?!** Order the **ALL-IN-ONE:**

```sh
./netboot-android.sh --distro debian all
```

**ONE COMMAND!** Or run it with NO arguments for the **GUIDED MENU!**

---

## PICK YOUR NETWORK MODE!

- 📡 `--mode proxy`: Your router keeps handing out addresses, and the phone just adds the boot info! Guest Wi-Fi and client isolation will block it!
- 🔌 `--mode direct`: A cable from the phone (USB Ethernet) straight to the PC! The phone does DHCP itself!
- 🤖 `--mode auto`: It picks for you!

**HERE'S A TIP:** The phone's own hotspot is unreliable, because Android's DHCP server may be sitting on port 67!

---

## PHONE IS ARM64 AND YOUR PC IS x86_64?! NO PROBLEM!

Your phone can't build the PC's iPXE natively. So copy `~/netboot/attest/ca.crt` and the script to any x86_64 Linux machine and run:

```sh
TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
```

Copy `ipxe.efi` and `undionly.kpxe` back to the phone, then:

```sh
./netboot-android.sh import-ipxe DIR
```

**IT'S THAT EASY!**

---

## ACT NOW AND GET THESE EXTRA COMMANDS, AT NO EXTRA CHARGE!

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

## WHEN THINGS GO WRONG, WE'VE GOT YOU COVERED!

- **"PIN MISMATCH"?** Either the site rotated its certificate (run `pins refresh HOST`) or someone is tampering with your connection. DON'T download over that network!
- **dnsmasq won't start?** Something else holds port 67 or 69. Check your hotspot, other DHCP/TFTP services, and SELinux!
- **"Network changed since configure"?** Your IP moved. Run `configure` again!
- **"Script changed since self-sign"?** If YOU edited it, run `self-sign` again. If you DIDN'T, investigate!
- **Boot stops at `imgverify`?** The iPXE binaries were built with a different CA. Rebuild iPXE!

---

## THE FINE PRINT! (I TALK FAST, BUT READ THIS PART!)

Results may vary! netboot-android does NOT do the following:

- The big root image the initrd downloads AFTER boot (Ubuntu ISO, Debian/Parrot squashfs, Fedora squashfs) is **NOT** signature-checked on the client! Arch and SystemRescue DO check theirs!
- Self-verification is tamper EVIDENCE! Whoever can edit the script can edit the check! Compare the `fingerprints` output against a copy on another device!
- Embedded pins and vendor data were collected on **2026-10-08**! Run `pins refresh` on your own device before first use!
- Test on a machine you can afford to break!

---

# NETBOOT-ANDROID! BOOT LINUX FROM YOUR PHONE!

# **BILLY MAYS HERE! AND I'LL BE BACK WITH A NEW SCRIPT NEXT WEEK!**
