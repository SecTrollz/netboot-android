# netboot-android

This is a README. You are reading it. Good. That is how it works.

`netboot-android.sh` is one bash script. It turns a rooted Android phone (in Termux), or any Linux machine, into a **verified PXE boot server**. A PC on the same network boots a live Linux system straight off the phone. No USB stick. No disc. Just the phone, sitting there, being a server. It does not know it is a server. Please do not tell it.

---

## What happens

1. The PC wakes up and asks the network for something to boot. It asks politely. It has never been told no.
2. The phone answers and hands it **iPXE** over TFTP.
3. iPXE fetches the kernel, the initrd and the root image from the phone over HTTP.
4. Linux boots.

That is the entire plot. There is no twist. The phone does not turn out to be the PC's father.

---

## Why you can trust it

Every step is checked. The script has trust issues, and they are healthy ones.

1. **Vendor keys.** The real signing key fingerprints for each distro are written into the script. Each key is downloaded from at least two independent places, and both places must agree. If they disagree, the script leaves.
2. **Vendor signatures.** An ISO is accepted only if a signature from that vendor key checks out.
3. **TLS pinning.** Download servers are pinned by their public keys, which are checked against Certificate Transparency logs. If a server shows a key that isn't in those logs, someone is in the middle, and the script says so out loud.
4. **Your own keys.** It makes a GPG key and a small code-signing CA on your device. They are yours. They will not be shared with a man named Greg.
5. **iPXE built from source** at a pinned commit, with your CA baked in. It refuses to run the boot script, the kernel, or the initrd unless their signatures check out.
6. **Integrity gate.** Before the servers start, every served file is hashed again and compared with the list.
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

## Backups of the working folder

`serve` and `clean` take a restorable archive of `~/netboot` (keys, attestation, pins, state, TFTP files, configs) into `~/netboot-backups`, with a SHA-256 sidecar, **only when something actually changed since the last backup**. Logs, locks, the big downloads and extracted files do not count, so a normal run costs nothing. A backup is a safety net, never a gate: if it cannot finish, the script says so and carries on.

```sh
./netboot-android.sh backup            # take one now (always runs)
./netboot-android.sh backup-list       # newest first
./netboot-android.sh restore FILE      # verify checksum, save current state, restore
./netboot-android.sh backup-auto off   # never back up automatically (on turns it back on)
./netboot-android.sh --no-backup go    # skip it for this one run
```

Extracted `http/`, `src/`, and `run/` are skipped because they rebuild. `downloads/` (the ISOs) is skipped unless `BACKUP_DL=1`. The newest 5 are kept (`BACKUP_KEEP`).

**Offsite copy to Terabox.** Terabox has no official API, so this uses the unofficial open-source CLI [fcr--/tbc](https://github.com/fcr--/tbc) (MIT, Go), pinned to one commit. It contacts only `www.terabox.com` and logs in with your `ndus` cookie, so treat that cookie like a password and keep it in a `chmod 600` file. Unofficial tools can break when Terabox changes its site.

```sh
./netboot-android.sh terabox-install                      # needs git and Go 1.24+
export TERABOX_COOKIE_FILE=~/.terabox-cookie              # contains: ndus=...
export BACKUP_GPG_PASSFILE=~/.nb-pass                     # archive passphrase
./netboot-android.sh serve                                # backs up, encrypts, uploads to /netboot-backups
```

The archive holds your signing keys, so it is AES256-encrypted first and never uploaded without the passphrase file. A failed upload only warns; the local backup stays. To restore from Terabox, fetch the `.gpg` file with `tbc get`, decrypt it with `gpg -d FILE.gpg > FILE`, and then run `restore FILE` after putting the matching `.sha256` next to it (or unpack it with `tar -xzf`). For any other uploader, set `BACKUP_UPLOAD_CMD` instead.

**Offsite copy to Google One storage.** Google One storage is your Google Drive space, and rclone has an official Drive backend. Install rclone (`pkg install rclone` in Termux), run `rclone config` once and create a remote of type `drive` (pick the `drive.file` scope so it only sees files it creates), then:

```sh
export GDRIVE_REMOTE=gdrive:netboot-backups
export BACKUP_GPG_PASSFILE=~/.nb-pass
./netboot-android.sh serve        # backs up, encrypts, uploads
```

Terabox, Google Drive, and `BACKUP_UPLOAD_CMD` can all be on at once; each gets the same encrypted file. To restore, `rclone copy gdrive:netboot-backups/FILE.gpg .`, then `gpg -d`, as above. On a phone with no browser for rclone's login, run `rclone authorize drive` on another machine and paste the token.

This is a file-level archive, not a Clonezilla or Shadow Copy block image. To image the whole phone or disk, do that separately. Editing the script changes its hash, so run `self-sign` again after pulling this change.

---

## Start here (the whole thing in three lines)

```sh
./netboot-android.sh
```

1. Press **Enter**. The first time, it asks one plain question (rescue a PC, try Ubuntu, or something else) and then sets everything up, about 20 to 40 minutes, mostly downloading.
2. Every time after that, the same command shows **READY**. Press **Enter** and boot your PC from the network. Press Ctrl+C when you are done.
3. If something is wrong, it says so in plain words and offers to fix it. Press Enter to accept.

When the server starts, a box tells you what to press on the PC (boot-menu keys for Dell, HP, Lenovo, Asus, Acer, and Surface, and what to turn on in firmware).

**One tap on Android.** Run `./netboot-android.sh shortcut`, then add the free Termux:Widget app to your home screen. A **Boot-a-PC** button starts serving with your saved settings. It never starts by itself.

`--yes` accepts the suggested answers for scripts. It will never trust a script that has changed since you signed it; only you can say yes to that.

---

## The guided setup, in detail

```sh
./netboot-android.sh
```

Run `./netboot-android.sh guide` (or choose **1, GUIDED SETUP** in `./netboot-android.sh menu`). It goes one small step at a time, says in plain words what each step does, and asks before it does anything. Press Enter to accept the suggested answer, type `q` to stop safely at any question. Steps you already finished are noticed and offered as "do it again?" with the answer No. If a step fails, you get retry, skip, or quit instead of a crash. The guide also covers the optional Google One and Terabox cloud backups. Run just that part with `./netboot-android.sh backup-setup`, or the guide alone with `./netboot-android.sh guide`.

---

## Running inside a "Linux on your phone" (proot)? Read this

If your prompt shows a Linux such as Ubuntu or Debian started with `proot-distro`, that environment **cannot serve a PC**: it cannot see the phone's Wi-Fi and cannot open the DHCP/TFTP ports. Serve from **Termux itself** (rooted). The script detects this and says so.

A proot Linux is, however, a good place to **build the loader**, because `apt` can install an x86_64 cross-compiler there. Run `./netboot-android.sh proot-build` inside it and follow the on-screen steps: copy only your **public** `ca.crt` from Termux into the proot, build, then copy `ipxe.efi` and `undionly.kpxe` back and run `import-ipxe`. Do not use keys created inside the proot: the loader must contain the certificate of the install that serves.

---

## Phone and PC have different CPUs? One safe GitHub build, then pinned

A phone is arm64 and most PCs are x86_64. The network loader (iPXE) must be compiled for the PC's CPU, and it decides what your PC will boot. The guide's default for a phone is a **one-time build on GitHub that the script then pins forever**:

```sh
./netboot-android.sh ipxe-cloud
```

1. It prints a page address and copies your **public** certificate. On that page tap **Run workflow**, paste, pick the PC's CPU, run (about 5 minutes, free). GitHub only shows *Run workflow* for workflows on your default branch, so merge this branch to `main` first.
2. Back in the terminal press Enter. The script downloads the build and checks, in this order:
   - the checksums match;
   - the build ran **exactly the workflow file you can read** in `.github/workflows/build-ipxe.yml` (its SHA-256 is baked into the script, and the script also fetches that file at the tagged commit and hashes it itself);
   - the loader contains **your** certificate;
   - **GitHub's signed build provenance** verifies, when the GitHub CLI is set up (`pkg install gh && gh auth login`). Without it the check is skipped and the default answer to the approval question becomes **No**.
3. You approve once. From then on the script **pins those exact bytes** (a signed record in `~/netboot/state`). Every later run, `heal`, restore, or new distro reuses that same file, restores it automatically if it goes missing, and refuses any different file. `ipxe-fetch new` is the only way to replace it, and it asks.

The workflow itself is hardened: actions are pinned to commit hashes (never movable tags), the iPXE source is pinned by hash, the release is tied to the building commit, inputs never reach a shell, and a pasted private key is rejected.

**What this does not remove:** for that one run you still trust GitHub's build servers, and the first approval is trust-on-first-use of that file. A loader built on a computer you control has no such gap (`ipxe-phone` builds it on the phone itself with a Debian cross-compiler; or build on an x86_64 Linux computer and `import-ipxe DIR`). If you never want the GitHub route, delete the workflow file. `status` shows whether the pinned loader's provenance was verified.

Anyone can double-check a pinned build from any computer with `gh attestation verify ipxe.efi --repo OWNER/REPO`.

---

## It finds your earlier downloads

Before downloading anything, `fetch` looks for an image you already have: in `~/netboot`, `~/netboot/downloads`, your home folder, `Download`/`Downloads`, `~/storage/downloads` (after `termux-setup-storage`), `/sdcard/Download`, and any folders in `EXTRA_ISO_DIRS` (colon separated). A complete file of the right size is re-used (hard link, or a copy if needed), an unfinished `NAME.part` is resumed from where it stopped, and anything of the wrong size is ignored. Whatever it finds is still fully verified against the vendor's signed checksum, and your original file is never changed or deleted. To point at a file yourself: `./netboot-android.sh --iso /path/to/file.iso fetch`.

---

## A download is never thrown away over a key or network problem

The vendor signing key is checked **before** the big download starts, so a problem shows up in seconds, not after 6 GB. Ubuntu's key is confirmed by two independent places (Ubuntu's keyserver and the `ubuntu-keyring` package from Ubuntu's own archive; `keys.openpgp.org` does not carry that key). If verification cannot finish for any reason other than the image really not matching its signed checksum, the finished download is **kept** and the next `fetch` only re-verifies it. Only a real checksum or signature mismatch discards the image (after one clean retry if it was a resumed download). A mirror that cannot resume makes the script start the file over instead of retrying forever. `KEY_MIN_SOURCES=1` accepts a key from one source (its fingerprint is built into the script), if you choose to.

---

## Daily use and emergencies

Once set up, you only need three commands:

```sh
./netboot-android.sh go        # fix small problems, then start serving with your last settings
./netboot-android.sh status    # one screen: what is ready, what needs attention, and the fix for each
./netboot-android.sh heal      # repair leftovers from a crash, power loss, or an address change
```

**Emergency card.** Phone in hand, PC needs rescuing:

1. Connect the phone to the same Wi-Fi (or cable it to the PC).
2. Run `./netboot-android.sh go`. It needs no internet.
3. Boot the PC from the network. Press Ctrl+C when done.

What it does for you while it runs:

- **Never half-writes.** Downloads, extractions, manifests, and your settings are written to a temporary name and renamed only when complete. If it is killed mid-way, the old files are still good and `heal` removes the leftovers.
- **Undoes its own changes.** The IP address, routing rules, and Wi-Fi power mode it changes are recorded first. If the script dies, the next run puts them back.
- **One at a time.** A lock stops two runs from corrupting each other. A lock left by a dead run clears itself.
- **Starts in seconds.** Small boot files are always fully re-hashed. The multi-GB root image is checked by a signed fingerprint, then fully re-hashed in the background at low priority while it serves. If it ever changed, the servers stop with a red message. `./netboot-android.sh verify deep` (or `DEEP_VERIFY=1`) checks everything first instead.
- **Watches itself.** A crashed HTTP server or dnsmasq is restarted (up to 5 times in 5 minutes, then it stops and tells you). If the phone's Wi-Fi address changes, it re-signs the boot files and carries on.
- **Resumable file server.** Clients can resume downloads (HTTP Range), the server caps simultaneous connections, and it blocks path tricks.
- **Plain errors.** Failures say what went wrong and the next command to run. Details go to `~/netboot/state/netboot.log`.
- **Stays alive on Android.** On a rooted phone the servers are marked as important to the low-memory killer; keep Termux on unrestricted battery.

Honest limits: the fast check trusts a file's size, time, and inode for a few minutes until the background check finishes, so someone with root who forges those could briefly serve a changed root image (the kernel and initrd are signed and always fully checked). The root image is unsigned on the client for most distros; see the header of the script. Android features (root, `oom_score_adj`, Wi-Fi power mode) can only be proven on a real phone.

Tests: `tests/run.sh` runs 85 checks (fault injection and the easy-mode screens) (kill mid-extract, tampered files, stale locks, address change, crashed servers, backup and restore) with no network.

---

## How to run it

The first time, do these in this order. The order matters. Do not do them in alphabetical order. Someone did once. We don't talk about it.

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

Run it with no arguments and you get a menu. The menu has numbers. You press a number. A thing happens. This is called technology.

---

## Network modes

- **`--mode proxy`**: Your router keeps handing out addresses. The phone just adds the boot information, quietly, like someone adding a tip. Guest Wi-Fi and "client isolation" block this.
- **`--mode direct`**: A cable (USB Ethernet) goes straight from the phone to the PC. The phone handles DHCP itself. The router is not invited.
- **`--mode auto`**: The script picks. It usually picks correctly. It once picked a fight with a toaster, but that was a different script.

The phone's own hotspot is unreliable, because Android's DHCP server may already be sitting on port 67. It got there first. It is not moving.

---

## When the phone is arm64 and the PC is x86_64

Most phones are arm64. Most PCs are x86_64. The phone cannot build the PC's iPXE by itself. It tried. It got very quiet.

Copy `~/netboot/attest/ca.crt` and the script to any x86_64 Linux machine and run:

```sh
TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
```

Bring `ipxe.efi` and `undionly.kpxe` back to the phone and run:

```sh
./netboot-android.sh import-ipxe DIR
```

---

## Proving nobody touched the keys

The vendor fingerprints, the TLS pins and the iPXE commit are written into the script. Here is how you prove, later, that they are exactly what you uploaded.

**1. Before uploading, choose the exact upload time:**

```sh
./netboot-android.sh release-stamp 2026-10-09T18:00:00Z
```

This writes the time into the script as `RELEASE_TIME`, and re-signs the script if you have attestation set up. It prints a **release code**: an HMAC-SHA256 of the whole script, keyed by that exact time. **Write the code down somewhere that is not the phone.** A notebook. A different device. The inside of a cereal box you will definitely keep.

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

- The large root image that the initrd downloads **after** boot (the Ubuntu ISO, the Debian or Parrot squashfs, the Fedora squashfs) is **not** signature-checked on the client. Arch and SystemRescue do check theirs.
- Self-verification is tamper **evidence**, not tamper proof. Anyone who can edit the script can edit the check. Compare the `fingerprints` output against a copy kept on another device.
- The embedded pins and vendor data were collected on **2026-10-08**. Run `pins refresh` on your own device before first use.
- Test it on a machine you can afford to break.

Licensed under Apache-2.0. See `LICENSE`.

---

That is the end of the README. You can stop reading now. You are still reading. That's fine. The phone is still at work.
