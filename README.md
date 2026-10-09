# NETBOOT-ANDROID

*Pirouettes onstage, trips on own tutu, glares at the audience like it was THEIR fault.*

Ugh. Hello, darlings. Yes, it's me, in the pink tutu, which I wear *ironically*, unlike EVERY other girl in this company. They're all "ooh, look at my little turnout." Please. My turnout could boot a computer. And now it does.

`netboot-android.sh` is ONE bash script. It turns your rooted Android phone (in Termux) or any Linux machine into a **verified PXE boot server**. Your PC boots off the network and pulls a live Linux system straight from your phone. No USB stick. No disc. No clumsy little understudies fumbling with flash drives in the wings.

---

## Act I: The Choreography

Even the corps de ballet could follow this, and they can barely count to eight:

1. The PC, *dramatically*, from stage left: "I NEED TO BOOT."
2. The phone glides in and hands it **iPXE** over TFTP. *Plié.*
3. iPXE fetches the kernel, initrd and root image over HTTP. *Relevé.*
4. Linux boots. *Grand jeté.* Hold for applause. Longer. LONGER.

---

## Act II: Trust Issues (Every Ballerina Has Them)

The other girls trust ANYONE who hands them a bouquet. Not me. This script checks every link in the chain:

1. **Vendor keys.** Fingerprints are built in. Each key is fetched from at least two independent sources, and they must agree. Like two judges who both agree I'm the best. Which they do.
2. **Vendor signatures.** An ISO is accepted ONLY when a signature from the vendor key verifies.
3. **TLS pinning.** Download servers are pinned by public key and checked against Certificate Transparency logs. A key that isn't in CT means interception, and the script calls it out. Loudly. Center stage.
4. **Your own signing keys.** A GPG key and a code-signing CA, generated on YOUR device. Custom-fitted, like my pointe shoes. Theirs are from a bin.
5. **iPXE built from source** at a pinned commit with your CA baked in. It refuses to run the boot script, kernel or initrd unless the signature verifies. It has standards, sweetie.
6. **Integrity gate.** Every served file is re-hashed against the manifest before the servers start.
7. **Signed attestation reports** tie it all together, and you can re-verify any time.

---

## Act III: The Repertoire

Seven roles. I could dance all of them. The others could dance maybe one, badly.

| `--distro`     | Role                          | CPU            | PC RAM needed |
|----------------|-------------------------------|----------------|---------------|
| `ubuntu`       | Ubuntu 26.04.1 desktop        | x86_64, arm64  | ~10 GB (arm64 ~7) |
| `ubuntu24`     | Ubuntu 24.04.5.1 desktop      | x86_64         | ~10 GB |
| `debian`       | Debian 13.7 live standard     | x86_64         | ~4 GB |
| `fedora`       | Fedora Workstation 44 live    | x86_64         | ~6 GB |
| `arch`         | Arch Linux (latest)           | x86_64         | ~4 GB |
| `systemrescue` | SystemRescue 13.02            | x86_64         | ~4 GB |
| `parrot`       | Parrot Security 7.4           | x86_64, arm64  | ~12 GB |

`--arch` is the CPU of the PC that's BOOTING, not your phone. Brittany got this wrong in rehearsal. Twice.

---

## Act IV: Costume Check

You will need:

- A **rooted** Android phone with Termux (grant Termux root in Magisk or KernelSU), OR a Linux machine with sudo.
- Free storage: roughly 3 GB to 17 GB depending on the distro. The `check` command tells you.
- The PC on the same network as the phone, or a cable straight to it.
- On the PC: **PXE (network) boot ON, Secure Boot OFF.**

---

## Act V: Rehearsal, In Order, From The Top

Five, six, seven, eight:

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

Too much choreography for you? Fine, here's the version for the corps:

```sh
./netboot-android.sh --distro debian all
```

Run it with no arguments and you get a guided menu. Training wheels. On a tutu.

---

## Act VI: Partnering

Every ballerina needs a partner. Pick one:

- **`--mode proxy`**: Your router keeps handing out addresses, and the phone only adds the boot info. Guest Wi-Fi and client isolation will drop you mid-lift.
- **`--mode direct`**: A cable (USB Ethernet) straight from phone to PC. The phone does DHCP itself. A committed partner, finally.
- **`--mode auto`**: Lets the script pick. Like a blind date at the cast party.

The phone's own hotspot is unreliable, because Android's DHCP server may be hogging port 67. Like Jessica hogs the mirror.

---

## Act VII: Touring Abroad (arm64 Phone, x86_64 PC)

Your phone is arm64 and your PC is x86_64, so your phone can't build the PC's iPXE natively. It simply cannot. Like Madison and a fouetté.

Copy `~/netboot/attest/ca.crt` and the script to any x86_64 Linux machine, then:

```sh
TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
```

Bring `ipxe.efi` and `undionly.kpxe` back to the phone:

```sh
./netboot-android.sh import-ipxe DIR
```

---

## Act VIII: The Understudy Test (Did Anyone Swap Out My Keys?)

Somebody always tries to steal your role. The keys are hard-coded: the vendor fingerprints, the TLS pins, the iPXE commit. Here's how you catch an imposter.

**Before you upload, pick your exact curtain time:**

```sh
./netboot-android.sh release-stamp 2026-10-09T18:00:00Z
```

That writes the time into the script as `RELEASE_TIME` and re-signs it if you have attestation set up. Then it prints a **release code**: an HMAC-SHA256 of the whole script, keyed by that exact time. **Write the code down somewhere that isn't the phone.** Not on your hand. You'll sweat it off.

**Upload at exactly that time** (the script prints these lines for you):

```sh
GIT_AUTHOR_DATE=2026-10-09T18:00:00Z GIT_COMMITTER_DATE=2026-10-09T18:00:00Z git commit -am "Release 2026-10-09T18:00:00Z"
git push origin main
```

**Later, on any device:**

```sh
./netboot-android.sh verify-upstream
EXPECT_CODE=xxxx-xxxx-xxxx-xxxx-xxxx ./netboot-android.sh verify-upstream
```

It fetches the script from GitHub over pinned TLS, finds the last commit that touched it, and checks three things:

1. That commit's timestamp must equal `RELEASE_TIME`.
2. The code for your local copy must equal the code for the GitHub copy.
3. If you pass `EXPECT_CODE`, the GitHub copy's code must match it too.

**Flawless:** you get one box: `UPSTREAM MATCH`, the commit, the upload time, the code. Curtsy.
**Anything off:** it names the problem. If keys or pins changed, it shows the exact lines. Like a judge's scorecard.

Listen carefully, because I'm only saying this once, unlike SOME people. The time isn't a secret. Anyone can read a commit date. The code alone proves nothing. What proves it is the GitHub copy plus the code you wrote down off the phone. And don't squash-merge or rebase the release commit, or the timestamp changes and the whole performance is ruined.

---

## Act IX: Props Table

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

`./netboot-android.sh --help` lists EVERY environment variable. There are more of them than girls who think they deserve the lead.

---

## Act X: Injuries

Every production has them. Usually someone else's fault.

- **"PIN MISMATCH"**: Either the site rotated its certificate (run `pins refresh HOST`) or someone is tampering with your connection. Do NOT download over that network.
- **dnsmasq won't start**: Something else holds port 67 or 69. Check your hotspot, other DHCP/TFTP services, and SELinux.
- **"Network changed since configure"**: Your IP moved. Run `configure` again.
- **"Script changed since self-sign"**: If YOU edited it, run `self-sign` again. If you DIDN'T, investigate.
- **Boot stops at `imgverify`**: The iPXE binaries were built with a different CA. Rebuild iPXE.
- **"TIME MISMATCH"**: The newest commit touching the script on GitHub wasn't made at `RELEASE_TIME`. Either someone pushed a newer version, or the release commit was made without the `GIT_*_DATE` variables.
- **"Upstream verification FAILED"**: Your copy is not the one uploaded at that time. Read the diff it prints.

---

## Act XI: What I Won't Do (A Diva Has Limits)

- The big root image the initrd downloads AFTER boot (the Ubuntu ISO, the Debian/Parrot squashfs, the Fedora squashfs) is **NOT** signature-checked on the client. Arch and SystemRescue DO check theirs.
- Self-verification is tamper EVIDENCE. Whoever can edit the script can edit the check. Compare the `fingerprints` output against a copy kept on another device.
- Embedded pins and vendor data were collected on **2026-10-08**. Run `pins refresh` on your own device before first use.
- Test on a machine you can afford to break. Unlike my ankles, which are priceless.

Licensed under Apache-2.0. See `LICENSE`.

---

## Curtain

*Takes eleven bows. Nobody is clapping anymore. Takes a twelfth.*
