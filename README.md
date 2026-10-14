# Netboot Android / Linux

Boot a supported operating system on a PC using files served by a Linux computer or a rooted Android phone. The script can also show a verified ISO to a PC as a read-only USB drive on supported Android devices.

This guide is written for people who have not set up a boot server before. Follow the steps in order. If a step does not match what you see, stop and read the error instead of guessing.

## What this does

The computer that runs this script is the **server**. The PC you want to start is the **target PC**. The server sends boot files to the target PC over a local network, or presents an ISO over USB.

This is not a Windows or macOS program. The server must be:

- A Linux computer with administrator access; or
- An Android device running Termux with root access and the needed USB/network features.

The PC is the target. Its built-in startup software must support starting from the network (PXE) or from USB. A script cannot add boot features that the PC or phone does not have.

The script chooses a writable storage folder based on the server's environment and available space. You do not need to set a personal folder path. It keeps separate ISO and verification records for each operating system and PC processor type. Only the selected system's boot files are active at one time.

## What it supports

The script contains these presets. The exact release numbers are set in the script and may change when the script is updated.

| Operating system | PC processor supported by the current preset |
|---|---|
| Ubuntu | x86-64 or ARM64 |
| Ubuntu 24.04 | x86-64 |
| Debian, Fedora, Arch Linux, SystemRescue | x86-64 |
| Parrot Security | x86-64 or ARM64 |
| Current Windows 11 ISO download and WIM-based Windows Setup | x86-64 |

Windows network boot is for **x86-64 PCs** and Windows installer ISOs that contain these WIM boot files:

- `boot/BCD`
- `boot/boot.sdi`
- `sources/boot.wim`

The script can check current Windows 11 x64 media against the SHA-256 values on Microsoft's download page. Older Windows releases and custom ISOs are not downloaded automatically; you must provide the ISO and a trusted SHA-256 value. Any ISO used for network setup must contain the three WIM boot files above. That does not guarantee every version or PC will work.

Windows Setup can start from the network boot files, but this script does not make Setup install Windows automatically from the streamed ISO. Setup may need a separate installation source. The USB-drive method presents the ISO itself to the PC as read-only media.

## Before you start

You need:

1. A supported server device listed above.
2. A separate PC that supports network boot or USB boot.
3. Internet access for setup tools and the operating system download.
4. Enough free storage for the ISO and extracted boot files. Windows media is large; plan for at least 12 GB free.
5. For Windows, an internet connection to Microsoft's current download page, or a Windows ISO you already downloaded. Older Windows releases also need a trusted SHA-256 value. See [Windows ISO safety](#windows-iso-safety) below.

For network boot, connect the server and PC to the same private network. A wired connection is usually more reliable. Guest Wi-Fi and networks that isolate devices can block boot traffic.

## First-time setup

### 1. Open a terminal in the script folder

A **terminal** is a window where you type commands. On Linux, open the Terminal app. On Android, open Termux. On the GitHub page you trust, choose **Code → Download ZIP**, save and unzip the folder on the server. Then open a terminal in the folder that contains `netboot-android.sh`. Many file managers have an **Open in Terminal** choice when you right-click a folder. The exact words vary.

If the file did not keep its run permission, set it once:

```sh
chmod +x netboot-android.sh
```

This lets the script file run as a program. Run it as your normal user. Do not add `sudo` to every command; the script asks for administrator permission when a step needs it. Administrator permission is called **root** on Linux and Android. On Android, the phone must already be rooted.

### 2. Choose how to get Windows media, if that is your target

For current Windows 11 x64, choose **Windows Setup** in the guide or run:

```sh
./netboot-android.sh windows-download
```

The script reads Microsoft's current language-specific SHA-256 table, asks which language you want, then requests the matching download link. If Microsoft's link service refuses an automated request, the script stops and shows Microsoft's official page. Download the ISO there, then give the script its path:

```sh
./netboot-android.sh --distro windows --iso "/full/path/to/Windows.iso" fetch
```

The file name can be anything. The script checks its bytes against the hashes on Microsoft's page; it does not trust a hash it calculated from the file itself. If the file is in a detected Downloads folder, choose its language in the prompt and the script adopts it only if its SHA-256 matches.

For an older Windows release, download the ISO from a Microsoft source you trust and use that exact file's independently published SHA-256:

```sh
./netboot-android.sh --distro windows --iso "/full/path/to/Windows.iso" --sha256 "64_HEX_CHARACTERS" fetch
```

Do not use a hash copied from the same ISO file as proof of origin. After the file matches, the script saves that explicitly supplied value in a locally signed record for later runs. The local signature remembers what you approved; it does not verify where the hash came from. Keep the quotes around paths that contain spaces.

### 3. Start the guided setup

Run:

```sh
./netboot-android.sh guide
```

On a new setup, choose **Windows Setup** for the current Windows 11 x64 installer. Choose **Something else** to see the other operating systems. Windows network boot supports x86-64 PCs only.

If the guide shows a previously saved system, answer **no** when it asks whether to keep that choice, then select **3) Windows Setup**. The first **Ready to begin?** prompt accepts only yes or no; choose the operating system at the next prompt.

The guide checks the server, offers to install required tools, creates local signing keys, checks download-server identities, builds the iPXE boot program, and prepares the selected system. Read each prompt. Installing tools changes the server by adding packages through its normal software installer, called a package manager. Cloud backup is optional; skip it unless you choose to set it up.

If you already used the guide and it remembers a different system, run:

```sh
./netboot-android.sh guide --redo
```

Then answer **yes** when it asks whether to change the saved target.

### 4. Choose how the PC connects

The guide offers these network choices:

- **Auto:** let the script choose.
- **Proxy:** use the same router network as the PC. The router continues assigning network addresses. This is usually the right choice on a normal home network.
- **Direct:** connect the server to the PC with an Ethernet cable. The script becomes the only address server on that link. Use this only on a direct or isolated connection, never on a shared network that already has another address server.
- **USB:** use Android USB RNDIS networking. This is Android-only, pauses the phone's current USB function (including ADB), and works only when the phone's kernel and the PC's firmware support it.

The script saves your choices. At the end, it leaves the server stopped unless you answer **yes** to the start question. Press **Ctrl+C** in the server terminal when you are done. The easy screen also requires you to press **b** to start; pressing Enter there does nothing.

### 5. Start the PC from the network

While the server is running:

1. Connect the PC to the same network as the server. For network boot, use Ethernet if possible.
2. Restart the PC and open its one-time boot menu. The key depends on the PC; F12, Esc, or F9 are common. The PC maker's support page gives the exact key.
3. Choose **Network Boot**, **PXE**, or a similar option.
4. Follow the instructions shown by the script.

Windows and most systems using the custom iPXE route generally need **Secure Boot** turned off in the PC's firmware. Secure Boot checks boot programs before they run. Turning it off lowers protection while it is off. Ubuntu has a separate signed boot route on supported PCs. Follow the script's instructions; do not change this setting by guesswork.

## Windows ISO safety

For current Windows 11 x64, the script fetches Microsoft's official download page over HTTPS and checks the page's server key against Certificate Transparency records. It reads the page's language-specific SHA-256 table. It does **not** calculate a file's hash and then treat that result as proof that the file is genuine.

The ISO is hashed and compared with Microsoft's listed value before the script accepts it. The expected hash and language are saved in a record signed by the script's local GPG key. On later runs, the script checks that signature and hashes the ISO again. Before the HTTP server starts, the script checks the ISO again as part of the integrity checks.

If Microsoft's automated link service refuses a request, nothing is accepted or marked ready. Download from the official page shown by the script and run `fetch` with `--iso PATH`; the same Microsoft hash comparison is used. For older versions not on the current page, give the script a SHA-256 published by an independent Microsoft source. A user-provided hash is only as trustworthy as the source it came from.

A matching hash proves that the file matches the value Microsoft published for that product and language. It does **not** prove that the ISO has no security flaws, that Windows is risk-free, or that a computer will work with it. No software check can make those guarantees.

For Linux images, the script uses the signing keys and checksum/signature files configured for each preset. Checks protect the boot files, but they are not identical for every system. Ubuntu, Debian, Fedora, and Parrot fetch a large operating-system image after boot. This script does not check that later download on the target PC. Arch and SystemRescue use a checksum step for their large image.

## USB method (no network boot)

The USB method needs a rooted Android device with USB mass-storage support. It temporarily changes the phone's USB mode and presents the verified ISO as read-only media.

After the ISO has been verified, run:

```sh
./netboot-android.sh usb-boot
```

The Windows checksum is remembered in the local signed state record. If that record or the local signing key is missing or invalid, the script stops and requires a fresh Microsoft-page check or a new trusted SHA-256.

Connect the phone to the target PC and select its USB drive in the PC's boot menu. Press **Ctrl+C** to stop. If a previous run was interrupted, run:

```sh
./netboot-android.sh usb-boot stop
```

The PC's firmware must support booting from USB media. Not every phone kernel supports this feature.

Do not confuse `usb-boot` with `--mode usb`. `usb-boot` presents a USB drive. `--mode usb` creates a USB network connection (RNDIS) for PXE boot.

## Security and changes the script makes

- **`deps` installs packages** from the server's configured software sources. The guided setup offers this step. It does not silently install Windows on the server.
- **`serve` starts network services** for DHCP/PXE, TFTP, and HTTP. These services are not encrypted or password-protected. Other devices on the same network may be able to download the listed boot files and ISO. Use a private network you trust, and never forward these ports to the public internet.
- **USB modes change the phone's USB settings temporarily.** The script records recovery steps and tries to restore the previous settings when it stops. If recovery is needed, run `./netboot-android.sh heal`.
- **`clean` removes generated boot files and settings** after stopping the server. It keeps the ISOs, keys, and pins. Do not run it unless you want to remove the prepared files.
- The default verified boot mode signs boot files with a key created on the server. For Windows, Microsoft-page hashes help verify the ISO's publisher-listed bytes; the ISO is not itself digitally signed by this script.
- Self-signing the script can detect later edits to that same file. It cannot prove that the first copy you downloaded was safe. Compare the script's fingerprint with a copy you trust on another device.
- An imported iPXE program is still code that will run on the target PC. The script checks for its embedded certificate, but that check alone does not prove who built the program or what it does. Only import a build you trust.

For normal use, leave security settings at their defaults. Do not set `ALLOW_UNPINNED=1`, `ALLOW_UNVERIFIED=1`, `VERIFIED_BOOT=0`, `IPXE_ALLOW_UNATTESTED=1`, or `ACCEPT_SCRIPT_CHANGE=1` unless you understand the protection you are turning off. Windows remains blocked unless the ISO matches Microsoft's published SHA-256 or you explicitly supply a hash from another trusted source.

No script can promise that every download, computer, firmware version, software source, or ISO is free of malicious code. This script adds checks and stops when several checks fail. You still need to trust the script, the ISO, the expected hash, and the server's software sources.

## Useful commands

Run these from the script folder:

```sh
./netboot-android.sh status       # See what is ready
./netboot-android.sh doctor       # See problems and suggested fixes
./netboot-android.sh verify deep # Re-hash all prepared boot files
./netboot-android.sh heal         # Try to restore saved network/USB state
./netboot-android.sh windows-download # Get or verify a Windows 11 x64 ISO
./netboot-android.sh clean        # Stop and remove generated boot files
```

For day-to-day use after setup, `./netboot-android.sh go` checks the saved setup and starts the server. It uses the saved target, and re-checks the Windows ISO against its locally signed Microsoft checksum record. To change back to Windows after choosing another system, select **Windows: download or verify an official ISO** in the menu.

For a non-interactive current Windows 11 download, choose the language explicitly:

```sh
./netboot-android.sh --windows-language en-us windows-download
```

You can use a Microsoft language name instead, such as `English`. The script does not pick a language on its own. If Microsoft's direct-link service is blocked on your network, use the official browser page and provide the ISO path.

## Plain-language terms

- **ISO:** One large file that contains an operating system installer or live system.
- **SHA-256:** A long fingerprint calculated from a file. If one byte changes, the fingerprint should change. It proves a match to a known value, not who created the file.
- **Certificate Transparency:** Public records of website certificates. The script uses these records as an extra check of Microsoft's HTTPS identity.
- **GPG signature:** A check made with a key. The script uses its local key to detect changes to saved trust records; it does not make a user-supplied hash trustworthy.
- **x86-64 / ARM64:** Two different types of processor. Most Intel- or AMD-based PCs use x86-64. Some newer PCs use ARM64.
- **PXE / network boot:** Starting a PC by asking another computer on the local network for boot files.
- **DHCP:** The service that gives devices their network addresses. Direct mode must not compete with another DHCP server.
- **Firmware / UEFI:** Built-in startup software that runs before Windows or Linux and shows the PC's boot options.
- **Secure Boot:** A firmware feature that checks whether boot programs have signatures trusted by the PC.
- **iPXE:** A program that lets a PC start using files sent over the network.
- **HTTP / TFTP:** Ways computers send and receive files over a network. The script uses them to send boot files to the PC.
- **RNDIS:** A way for some Android phones to act like a USB network adapter.
- **WIM:** A Windows file format used for boot and installation images.
