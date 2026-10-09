# netboot-android

This is a README. You are reading it. Good. That is how it works.

`netboot-android.sh` is one bash script. It turns a rooted Android phone (in Termux), or any Linux machine, into a **verified PXE boot server**. A PC on the same network boots a live Linux system straight off the phone. No USB stick. No disc. Just the phone, sitting there, being a server. It does not know it is a server. Please do not tell it.

---

## Quick start

On the phone, install **Termux** (from F-Droid) and give it root in Magisk or KernelSU. Then, in Termux:

```sh
curl -fLO https://raw.githubusercontent.com/SecTrollz/netboot-android/main/setup.sh
less setup.sh     # it's short. Read it. It would want you to.
bash setup.sh
```

That installs everything, checks the script against GitHub, and starts a guided setup. The guided setup asks about five plain questions, like "how much memory does the computer have." You answer. It does the rest. When it's done, you type `netboot` and it remembers everything.

If it ever asks you to type **YES**, read the box above the question first. That box is the only part of this README that is not joking.

---

## What happens

1. The PC wakes up and asks the network for something to boot. It asks politely. It has never been told no.
2. The phone answers and hands it **iPXE** over TFTP.
3. iPXE fetches the kernel, the initrd and the root image from the phone over HTTP.
4. Linux boots.

That is the entire plot. There is no twist. The phone does not turn out to be the PC's father.

---

## Why you can trust it

Nearly every step is checked. The exceptions are listed plainly at the bottom, under "What it does not do." The script has trust issues, and they are healthy ones.

1. **Vendor keys.** The real signing key fingerprints for each distro are written into the script. Each key is downloaded from at least two independent places, and both places must agree. If they disagree, the script leaves.
2. **Vendor signatures.** An ISO is accepted only if a signature from that vendor key checks out.
3. **TLS pinning.** Download servers are pinned by their public keys, which are checked against Certificate Transparency logs. If a server shows a key that isn't in those logs, someone is in the middle, and the script says so out loud.
4. **Your own keys.** It makes a GPG key and a small code-signing CA on your device. They are yours. They will not be shared with a man named Greg.
5. **iPXE built from source** at a pinned commit, with your CA baked in. It refuses to run the boot script, the kernel, or the initrd unless their signatures check out.
6. **Integrity gate.** Before the servers start, every served file is hashed again and compared with the list. The list itself is signed by your key, so nobody can quietly edit both.
7. **Signed attestation reports.** A signed record of all of the above. You can re-check it whenever you want, including at 3 a.m., which is when most people want to.

---

## What it can boot

| `--distro`     | What you get                  | CPU            | PC RAM needed |
|----------------|-------------------------------|----------------|---------------|
| `ubuntu`       | Ubuntu 26.04.1 desktop        | x86_64, arm64  | ~10 GB (arm64 ~7) |
| `ubuntu24`     | Ubuntu 24.04.5.1 desktop      | x86_64         | ~10 GB |
| `debian`       | Debian 13.7 live standard     | x86_64         | ~4 GB |
| `fedora`       | Fedora Workstation 44 live    | x86_64         | ~6 GB |
| `arch`         | Arch Linux (latest)           | x86_64         | ~4 GB |
| `systemrescue` | SystemRescue 13.02            | x86_64         | ~4 GB |
| `parrot`       | Parrot Security 7.4           | x86_64, arm64  | ~12 GB |

`--arch` is the CPU of the **PC that boots**, not the phone. The phone is not booting anything. The phone is at work.

---

## What you need

- A **rooted** Android phone with Termux (give Termux root in Magisk or KernelSU), or a Linux machine with sudo.
- Free storage: about 3 GB to 17 GB, depending on the distro. `check` will tell you. `check` is very honest. It has never lied, not even about the soup.
- The PC on the same network as the phone, or a cable straight between them.
- On the PC: **network (PXE) boot on, Secure Boot off.**

---

## How to run it

Run `./netboot-android.sh` with no arguments. The first time, it starts the guided setup. After that, it shows a menu. The menu has numbers. You press a number. A thing happens. This is called technology.

If you prefer doing it by hand, do these in this order. The order matters. Do not do them in alphabetical order. Someone did once. We don't talk about it.

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

Or do all of it at once:

```sh
./netboot-android.sh --distro debian all
```

---

## Network modes

- **`--mode proxy`**: Your router keeps handing out addresses. The phone just adds the boot information, quietly, like someone adding a tip. Guest Wi-Fi and "client isolation" block this.
- **`--mode direct`**: A cable (USB Ethernet) goes straight from the phone to the PC. The phone handles DHCP itself. The router is not invited.
- **`--mode auto`**: The script picks. It usually picks correctly. It once picked a fight with a toaster, but that was a different script.

The phone's own hotspot is unreliable, because Android's DHCP server may already be sitting on port 67. It got there first. It is not moving.

---

## When the phone is arm64 and the PC is x86_64

Most phones are arm64. Most PCs are x86_64. The phone cannot build the PC's iPXE by itself. It tried. It got very quiet.

The guided setup handles this. It gives you two choices:

**1. The PC helper (recommended).** Any Linux PC on the same network builds a signed iPXE for the phone.
- The phone shows a command. On the PC, run it: `bash setup.sh --pc-helper <phone IP>:8000`
- The PC shows a short **CA code**, like `7792-d8ef-3ecf-0c95`. The phone shows one too. They must be the same.
- The PC builds for a few minutes, then shows an address. Type it on the phone.
- The phone downloads the files and shows short codes for them. The PC shows the same codes. Check that they match, press `y`, and you're done.

Matching codes means nothing was swapped on the way between the phone and the PC. Four groups of four characters. You can do this. You have matched socks before. Probably.

**2. Quick mode.** It downloads a stock iPXE from boot.ipxe.org, right now, on the phone. It works, but **boots are not signed**: the PC will run whatever kernel it's handed. The script makes you type `YES` first. Afterwards, `check`, the menu, the server screen and the attestation report all say UNSIGNED, so you can't forget. Upgrade any time with the menu's "Upgrade to signed boot," or with `netboot pc-helper`.

Doing it by hand also works: build with `TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe` on the PC, then `./netboot-android.sh import-ipxe DIR` on the phone.

---

## Proving nobody touched the keys

The vendor fingerprints, the TLS pins and the iPXE commit are written into the script. Here is how you prove, later, that they are exactly what you uploaded.

**1. Before uploading, choose the exact upload time:**

```sh
./netboot-android.sh release-stamp 2026-10-09T18:00:00Z
```

This writes the time into the script as `RELEASE_TIME`, and re-signs the script if you have attestation set up. It prints a **release code**: a SHA-256 hash of the whole script, bound to that exact time. It is not a password and not a signature. Anyone can work it out. Its only job is to be compared with the copy on GitHub and with the one you wrote down. **Write the code down somewhere that is not the phone.** A notebook. A different device. The inside of a cereal box you will definitely keep.

**2. Commit and push with exactly that time** (the script prints these lines for you):

```sh
GIT_AUTHOR_DATE=2026-10-09T18:00:00Z GIT_COMMITTER_DATE=2026-10-09T18:00:00Z git commit -am "Release 2026-10-09T18:00:00Z"
git push origin main
```

**3. Later, on any device:**

```sh
./netboot-android.sh verify-upstream
EXPECT_CODE=xxxx-xxxx-xxxx-xxxx-xxxx ./netboot-android.sh verify-upstream
```

It fetches the script from GitHub over pinned TLS, finds the last commit that touched it, and checks three things:

1. That commit's timestamp equals `RELEASE_TIME`.
2. The code for your copy equals the code for the GitHub copy.
3. If you gave `EXPECT_CODE`, the GitHub copy's code matches it.

**If everything matches:** one box appears that says `UPSTREAM MATCH`, with the commit, the upload time and the code. That's it. No confetti. The box is the confetti.

**If anything is off:** it tells you what. If keys or pins changed, it shows you the exact lines.

The time is not a secret. Anyone can read a commit date. The code alone proves nothing. The proof is the GitHub copy plus the code you wrote down somewhere else. Do not squash-merge or rebase the release commit, because that changes the timestamp and the check will fail. The check will be right to fail. Respect the check.

---

## Other commands

| Command | What it does |
|---|---|
| `setup` | The guided setup, again |
| `pc-helper` | Upgrade to signed boot using a Linux PC |
| `quick-ipxe` | Stock iPXE, UNSIGNED boot (asks for YES) |
| `fingerprints` | Values to compare against a copy on another device |
| `release-stamp TIME` | Stamps the upload time into the script and prints its release code |
| `verify-upstream` | Proves this script is byte-identical to the GitHub copy committed at that time |
| `verify-attest` | Checks a signed report and re-hashes every file |
| `pins show` | Lists the pins in use |
| `logs` | Follows the HTTP log |
| `selinux status\|permissive\|enforcing` | Android only. Permissive lowers device security, so set it back to `enforcing` afterward |
| `clean` | Stops servers, removes generated files (keeps ISOs, keys, pins) |

`./netboot-android.sh --help` lists every environment variable. There are a lot. They are all named in capital letters, because they are important, and they know it.

---

## When something goes wrong

- **"PIN MISMATCH"**: Either the site rotated its certificate (run `pins refresh HOST`), or someone is tampering with your connection. Do not download over that network. Do not argue with that network. Leave.
- **dnsmasq won't start**: Something else is using port 67 or 69. Check the hotspot, other DHCP/TFTP services, and SELinux.
- **"Network changed since configure"**: Your IP address moved. Run `configure` again.
- **"Script changed since self-sign"**: If you edited it, run `self-sign` again. If you didn't, someone else did. That is a different kind of problem.
- **Boot stops at `imgverify`**: The iPXE binaries were built with a different CA. Rebuild iPXE.
- **"TIME MISMATCH"**: The newest commit touching the script on GitHub wasn't made at `RELEASE_TIME`. Either someone pushed a newer version, or the release commit was made without the `GIT_*_DATE` variables.
- **"Upstream verification FAILED"**: Your copy is not the one uploaded at that time. Read the diff it prints. The diff is trying to help you.

---

## What it does not do

- **The very first file the PC loads is not checked.** The PC's firmware fetches iPXE over TFTP, which has no security at all, and Secure Boot is off. Someone on the network between the phone and the PC could hand it a fake iPXE that skips every check below it. So all the signing protects you only on a network you trust. A cable straight from the phone to the PC (`--mode direct`) is the safest setup.
- **The big root image is not checked on the client, for any distro.** That's the Ubuntu ISO, the Debian or Parrot squashfs, the Fedora squashfs, all downloaded after boot. Arch and SystemRescue run `checksum=y`, but the checksum file comes over the same plain HTTP, so it catches a damaged download, not a tampered one.
- **The signing key lives on the phone.** The chain protects against the network, not against someone who already controls the phone.
- **Quick mode turns all of the boot checks off.** It says so everywhere while it's on.
- Self-verification is tamper **evidence**, not tamper proof. Anyone who can edit the script can edit the check. Compare the `fingerprints` output against a copy kept on another device.
- The embedded pins and vendor data were collected on **2026-10-08**. Run `pins refresh` on your own device before first use.
- Test it on a machine you can afford to break.

Licensed under Apache-2.0. See `LICENSE`.

---

That is the end of the README. You can stop reading now. You are still reading. That's fine. The phone is still at work.
