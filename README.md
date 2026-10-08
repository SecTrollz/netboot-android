# netboot-android

*Writ by a feller from Planet Enu, where we all talk English and ain't none of us got more than half a brain between us.*

Well howdy, ya'll. Ol' Cletus Bubba-Quark here from Planet Enu. Folks say I'm a dumbshit head, and I ain't gonna argue, cuz I once tried to boot a computer by yellin' at it. But I finally figgered out sumthin' useful, so listen up.

## What in tarnation is this?

It's a bash script called `netboot-android.sh`. You run it on a rooted Android phone (in Termux) or on any ol' Linux box. It turns that thing into a **PXE boot server**. Then you tell your PC to boot off the network, and the PC grabs a Linux live system from yer phone. No USB stick. No burnin' discs. We ain't got no discs on Enu, the cows ate 'em.

How it works, as best my skull can hold it:

1. PC asks the network "hey, I need to boot, who's got somethin'?"
2. Yer phone says "me!" and hands over **iPXE** through TFTP.
3. iPXE grabs the kernel, the initrd, and the big ol' root image over HTTP.
4. Linux comes up. Hot damn.

## Why ain't it just dumb?

On Enu, we trust nobody, not even our own mamas. So this script checks everything before it serves it up:

- **Vendor keys.** It knows the signin' key fingerprints for each distro and grabs each key from at least two different places. If they don't match up, it quits.
- **Vendor signatures.** It only takes an ISO if the signature checks out against that key.
- **TLS pinnin'.** It pins the public keys of the download servers and checks 'em against Certificate Transparency logs. If a server shows a key that ain't in CT, that smells like somebody snoopin' on ya, and it hollers.
- **Yer own signin' keys.** It makes a GPG key and a little code-signin' CA right on yer device.
- **iPXE built from source** at a pinned commit, with your CA baked in. It flat out refuses to run the boot script, kernel, or initrd unless the signature checks out.
- **Integrity gate.** Before it serves nothin', it re-hashes every file against a list.
- **Signed reports** that tie it all together so you can check later that nobody messed with it.

### The stuff it AIN'T checkin' (be honest now)

- The big root image the initrd downloads **after** boot (Ubuntu ISO, Debian/Parrot squashfs, Fedora squashfs) ain't signature-checked on the PC. Arch and SystemRescue do check theirs.
- If somebody can edit the script, they can edit the checkin' too. Write down the `fingerprints` output on **another device** and compare. That's the real protection, ya dingus.
- The pins and vendor data baked in were collected 2026-10-08. Run `pins refresh` on yer own device before ya trust 'em.

## What it can boot

| `--distro`     | What it is                    | CPU            | PC RAM needed |
|----------------|-------------------------------|----------------|---------------|
| `ubuntu`       | Ubuntu 26.04.1 desktop        | x86_64, arm64  | ~10 GB (arm64 ~7) |
| `ubuntu24`     | Ubuntu 24.04.5.1 desktop      | x86_64         | ~10 GB |
| `debian`       | Debian 13.7 live standard     | x86_64         | ~4 GB |
| `fedora`       | Fedora Workstation 44 live    | x86_64         | ~6 GB |
| `arch`         | Arch Linux (latest)           | x86_64         | ~4 GB |
| `systemrescue` | SystemRescue 13.02            | x86_64         | ~4 GB |
| `parrot`       | Parrot Security 7.4           | x86_64, arm64  | ~12 GB |

`--arch` is the CPU of the **PC that's bootin'**, not yer phone. Don't mix 'em up like I did.

## What ya need

- A rooted Android phone with Termux (Magisk or KernelSU, give Termux root), **or** a Linux machine with sudo.
- Enough free storage (the script's `check` tells ya, it's anywhere from 3 GB to 17 GB dependin' on the distro).
- The PC on the same network as the phone, or a cable straight to it.
- On the PC: turn on network (PXE) boot and **turn off Secure Boot**.

## How to run it

First time, in this order:

```sh
./netboot-android.sh check          # is everything here?
./netboot-android.sh deps           # install packages
./netboot-android.sh attest-init    # make yer keys and CA
./netboot-android.sh self-sign      # sign the script's own hash
./netboot-android.sh pins refresh   # check pins against CT
./netboot-android.sh build-ipxe     # build iPXE (or import-ipxe DIR)
./netboot-android.sh fetch          # download + verify the ISO
./netboot-android.sh extract        # pull out kernel, initrd, rootfs
./netboot-android.sh configure      # sign boot files, write dnsmasq conf
./netboot-android.sh attest         # signed report
./netboot-android.sh serve          # start the servers
```

Too lazy for all that? (Me too.)

```sh
./netboot-android.sh --distro debian all
```

Run it with no arguments and you get a menu you can poke at.

### Pickin' a network mode

- `--mode proxy` : yer router keeps handin' out addresses, and the phone just adds the boot info. Both on the same Wi-Fi or LAN. Guest Wi-Fi and "client isolation" will wreck this.
- `--mode direct` : cable from the phone (USB Ethernet) straight to the PC. The phone does DHCP itself.
- `--mode auto` : it guesses. It's smarter than me.

Phone hotspot ain't reliable, cuz Android's own DHCP server likes to sit on port 67.

### The "phone can't build x86 iPXE" problem

Most phones are arm64 and most PCs are x86_64, so yer phone can't build the PC's iPXE by itself. Copy `~/netboot/attest/ca.crt` and the script to an x86_64 Linux box and run:

```sh
TRUST_CA=ca.crt FALLBACK_SERVER=<phone IP> ./netboot-android.sh --arch x86_64 build-ipxe
```

Copy the `ipxe.efi` and `undionly.kpxe` it spits out back to the phone, then:

```sh
./netboot-android.sh import-ipxe DIR
```

## Other commands

| Command | What it does |
|---|---|
| `fingerprints` | Prints the values ya compare on another device |
| `verify-attest` | Checks a signed report and re-hashes every file |
| `pins show` | Lists the pins in use |
| `logs` | Follows the HTTP log |
| `selinux status\|permissive\|enforcing` | Android only. Permissive makes yer phone less safe, so put it back to `enforcing` after |
| `clean` | Stops servers, removes generated files (keeps ISOs, keys, pins) |

Run `./netboot-android.sh --help` for every env variable (`DISTRO`, `HTTP_PORT`, `IFACE`, `BOOT_ARGS`, `VERIFIED_BOOT`, and a pile more).

## When it breaks (and it will)

- **"PIN MISMATCH"**: either the site rotated its cert (run `pins refresh HOST`) or somebody's tamperin' with yer connection. Don't download over that network.
- **dnsmasq won't start**: somethin' else has ports 67 or 69. Check yer hotspot, other DHCP/TFTP services, or SELinux.
- **"Network changed since configure"**: yer IP moved. Run `configure` again.
- **Script says it changed since self-sign**: if you edited it, run `self-sign` again. If ya didn't edit it... well, now ya got a problem.
- **Boot fails closed at `imgverify`**: the iPXE on the phone was built with a different CA than the one signin' the files. Rebuild iPXE.

## Last words from Planet Enu

This thing does boot stuff, and it checks its work better than anybody I know back home. But I'm still a dumbshit head, so test it on a machine ya can afford to break. If it blows up, that ain't on me, I blame the cows.

Licensed under Apache-2.0, see `LICENSE`. Now go boot sumthin'. Yeehaw.
