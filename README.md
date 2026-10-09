# NETBOOT-ANDROID

## 📺 CH. 1: "WHAT IS THIS?"

**Host:** A man whose head is a boot loader.

"Welcome back to the program! Tonight: `netboot-android.sh`! It's ONE bash script that turns your rooted Android phone (in Termux) or any Linux machine into a **verified PXE boot server**! Your PC boots off the network and pulls a live Linux system from your phone! No USB stick! No disc! Wubba lubba dub dub, I am not joking!"

*[channel flips]*

---

## 📺 CH. 2: "HOW IT WORKS"

**Chef Dhcpo:** "Step one: the PC cries, 'I NEED TO BOOT.' Step two: the phone hands it **iPXE** over TFTP. Step three: iPXE grabs the kernel, initrd and root image over HTTP. Step four: Linux comes out of the oven. Bon appétit!"

*[channel flips]*

---

## 📺 CH. 3: "TRUST ISSUES"

**The Honorable Judge Sha-256:** "Order! Order! This court only accepts evidence that has been verified!"

The script checks every link in the chain:

1. **Vendor keys.** Fingerprints are built in. Each key is fetched from at least two independent sources and they must agree.
2. **Vendor signatures.** An ISO is accepted ONLY when a signature from the vendor key verifies.
3. **TLS pinning.** Download servers are pinned by public key and checked against Certificate Transparency logs. A key that is not in CT means interception, and the script says so.
4. **Your own signing keys.** A GPG key and a code-signing CA, generated on YOUR device.
5. **iPXE built from source** at a pinned commit with your CA baked in. It refuses to run the boot script, kernel, or initrd unless the signature verifies.
6. **Integrity gate.** Every served file is re-hashed against the manifest before the servers start.
7. **Signed attestation reports** tie it together, and you can re-verify any time.

**Defense Attorney:** "Objection! This is a lot of checking!"
**Judge:** "Overruled. That's the whole point."

*[channel flips]*

---

## 📺 CH. 4: "THE MENU"

*A waiter made of spaghetti reads you the specials:*

| `--distro`     | Dish of the day               | CPU            | PC RAM needed |
|----------------|-------------------------------|----------------|---------------|
| `ubuntu`       | Ubuntu 26.04.1 desktop        | x86_64, arm64  | ~10 GB (arm64 ~7) |
| `ubuntu24`     | Ubuntu 24.04.5.1 desktop      | x86_64         | ~10 GB |
| `debian`       | Debian 13.7 live standard     | x86_64         | ~4 GB |
| `fedora`       | Fedora Workstation 44 live    | x86_64         | ~6 GB |
| `arch`         | Arch Linux (latest)           | x86_64         | ~4 GB |
| `systemrescue` | SystemRescue 13.02            | x86_64         | ~4 GB |
| `parrot`       | Parrot Security 7.4           | x86_64, arm64  | ~12 GB |

"`--arch` is the CPU of the PC that is BOOTING, not your phone. Sir, please stop eating the menu."

*[channel flips]*

---

## 📺 CH. 5: "PREPARE YOURSELF"

**You will need:**

- A **rooted** Android phone with Termux (grant Termux root in Magisk or KernelSU), OR a Linux machine with sudo.
- Free storage: roughly 3 GB to 17 GB depending on the distro. The `check` command tells you.
- The PC on the same network as the phone, or a cable straight to it.
- On the PC: **PXE (network) boot ON, Secure Boot OFF.**

*[channel flips]*

---

## 📺 CH. 6: "THE ROUTINE"

**Coach Cron:** "FIRST TIME, IN THIS ORDER! Let's go! And ONE! And TWO!"

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

"Too tired?! Do the all-in-one cooldown!"

```sh
./netboot-android.sh --distro debian all
```

"Run it with no arguments and you get a guided menu! Stretch!"

*[channel flips]*

---

## 📺 CH. 7: "HOW'S YOUR CONNECTION?"

**Host:** "Three suitors have entered the Network Mode Mansion!"

- 📡 **`--mode proxy`**: Your router keeps handing out addresses, and the phone only adds the boot info. Guest Wi-Fi and client isolation will block it. *"Not compatible!"*
- 🔌 **`--mode direct`**: A cable (USB Ethernet) straight from phone to PC. The phone does DHCP itself. *"They're going exclusive!"*
- 🤖 **`--mode auto`**: Lets the script pick. *"Matchmaker."*

**Warning from the producers:** The phone's own hotspot is unreliable, because Android's DHCP server may hold port 67.

*[channel flips]*

---

## 📺 CH. 8: "ARM64 AND x86_64: FORBIDDEN LOVE"

*Dramatic zoom.* "Maria, your phone is arm64, but your PC is x86_64! You cannot build its iPXE natively!"

"Then what do we do, Esteban?!"

"Copy `~/netboot/attest/ca.crt` and the script to any x86_64 Linux machine, and run:"

```sh
TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
```

"Then bring `ipxe.efi` and `undionly.kpxe` back to the phone, and say:"

```sh
./netboot-android.sh import-ipxe DIR
```

*Gasp. Credits roll over a guitar solo.*

*[channel flips]*

---

## 📺 CH. 9: "THE REMOTE"

| Command | What it does |
|---|---|
| `fingerprints` | Values to compare against a copy on ANOTHER device |
| `release-stamp TIME` | Stamps the upload time into the script and prints its release code |
| `verify-upstream` | Proves this script is byte-identical to the GitHub copy committed at that time |
| `verify-attest` | Checks a signed report and re-hashes every file |
| `pins show` | Lists the pins in use |
| `logs` | Follows the HTTP log |
| `selinux status\|permissive\|enforcing` | Android only. Permissive lowers device security, so set it back to `enforcing` afterward |
| `clean` | Stops servers, removes generated files (keeps ISOs, keys, pins) |

"Run `./netboot-android.sh --help` for EVERY environment variable! There are so many! Buttons! Everywhere!"

*[channel flips]*

---

## 📺 CH. 9½: "THE TIME HEIST"

*A detective made of wristwatches stares into the rain.*

"The keys are hard-coded, kid. Fingerprints, pins, the iPXE commit. Somebody touches 'em, I want to know. So here's the play."

**Before the upload, pick the exact moment:**

```sh
./netboot-android.sh release-stamp 2026-10-09T18:00:00Z
```

That writes the time into the script as `RELEASE_TIME`, re-signs it if you have attestation set up, and prints a **release code**: an HMAC-SHA256 of the whole script keyed by that exact time. **Write the code down somewhere that isn't the phone.**

**Upload at that exact time** (the script prints these lines for you):

```sh
GIT_AUTHOR_DATE=2026-10-09T18:00:00Z GIT_COMMITTER_DATE=2026-10-09T18:00:00Z git commit -am "Release 2026-10-09T18:00:00Z"
git push origin main
```

**Later, on any device:**

```sh
./netboot-android.sh verify-upstream
EXPECT_CODE=xxxx-xxxx-xxxx-xxxx-xxxx ./netboot-android.sh verify-upstream
```

It pulls the script from GitHub over pinned TLS and finds the last commit that touched it. Then it checks three things:

1. That commit's timestamp must equal `RELEASE_TIME`.
2. The code recomputed from that timestamp must be identical for the local copy and the GitHub copy.
3. If you pass `EXPECT_CODE`, it must match too.

**All good:** you get one box: `UPSTREAM MATCH`, the commit, the upload time, the code.
**Anything off:** it names the problem. If keys or pins changed, it shows the exact lines.

"One thing, kid. The time ain't a secret. Anybody can read a commit date. The code alone proves nothing. What proves it is the copy on GitHub plus the code you wrote down off the phone. Don't squash-merge or rebase that commit either, or the timestamp changes and the case goes cold."

*[channel flips]*

---

## 📺 CH. 10: "THIS IS FINE"

**Dr. Segfault:** "Nurse, what are the symptoms?"

- **"PIN MISMATCH"**: Either the site rotated its certificate (run `pins refresh HOST`) or someone is tampering with your connection. Do NOT download over that network.
- **dnsmasq won't start**: Something else holds port 67 or 69. Check your hotspot, other DHCP/TFTP services, and SELinux.
- **"Network changed since configure"**: Your IP moved. Run `configure` again.
- **"Script changed since self-sign"**: If YOU edited it, run `self-sign` again. If you DIDN'T, investigate.
- **Boot stops at `imgverify`**: The iPXE binaries were built with a different CA. Rebuild iPXE.
- **"TIME MISMATCH"**: The newest commit touching the script on GitHub wasn't made at `RELEASE_TIME`. Either someone pushed a newer version, or the release commit was made without the `GIT_*_DATE` variables.
- **"Upstream verification FAILED"**: Your copy is not the one uploaded at that time. Read the diff it prints.

**Dr. Segfault:** "He's going to be fine. Probably. Clear!"

*[channel flips]*

---

## 📺 CH. 11: "THE FINE PRINT"

*[disclaimer voice, 4x speed]* "netboot-android does NOT do the following:

- The big root image the initrd downloads AFTER boot (the Ubuntu ISO, the Debian/Parrot squashfs, the Fedora squashfs) is **NOT** signature-checked on the client. Arch and SystemRescue DO check theirs.
- Self-verification is tamper EVIDENCE. Whoever can edit the script can edit the check. Compare the `fingerprints` output against a copy kept on another device.
- Embedded pins and vendor data were collected on **2026-10-08**. Run `pins refresh` on your own device before first use.
- Test on a machine you can afford to break.

Licensed under Apache-2.0. See `LICENSE`."

*[channel flips]*

---

## 📺 CH. 12: *[static]*

*A single pickle watches you from a beanbag chair.*

*"...boot."*

*[end of broadcast]*
