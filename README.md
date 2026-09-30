# Kismiter

Tool for baking install ISO of single-purpose, largely *STIG-compliant Kismet workstation/platform on Ubuntu Server 24.04 LTS (x86_64) 
(*Security Technical Implementation Guidelines)

## Components:


| File                      | Description                                                                  |
| ------------------------- | ---------------------------------------------------------------------------- |
| `sbom/kismiter-sbom.spdx` | Software Bill of Materials (Ubuntu 24.04 LTS + limited additions)            |
| `build-kismiter-iso.sh`     | Builds custom Ubuntu Server 24.04 LTS ISO with Ubuntu Subiquity automations  |
| `setup.sh`                | Orchestrates most Kismiter customizations applied during Subiquity installer |
| `README.md`               | The document you are currently reading                                       |
| `LICENSE`                 | GNU General Public License 3.0                                               |


## Prerequisites:

- A modern Debian-based system recommended, to generate the Kismiter ISO
- Internet connection capable of downloading the Ubuntu Server ISO 
- Ubuntu Pro token (required for Ubuntu's official STIG tooling; free) 
- Wired Ethernet Internet connection (DHCP) for the system being imaged with the ISO; the installer needs working **HTTP** (port 80/443) to the Ubuntu archives (`archive.ubuntu.com`). ICMP ping may be blocked and is not required

## Usage:

- Download `build-kismiter-iso.sh` and `setup.sh`, placing them in the same folder 
- Run the `build-kismiter-iso.sh` script to create the ISO:

```
chmod +x build-kismiter-iso.sh
./build-kismiter-iso.sh
```

- Burn the resulting ISO to a bootable media/USB thumb drive with sufficient free space

```
sudo dd if=ubuntu-24.04-kismiter-YYYYMMDD.iso of=/dev/sdb bs=4M status=progress oflag=sync conv=fsync
```

- Boot the media 
- Prompt for new hostname if desired
- Prompt for password for the default user
- Prompt for a LUKS drive encryption passphrase (twice; a blank passphrase is rejected)
- Prompt for Ubuntu Pro token (skip to omit STIGs)
- Walk away, return to completed install (LUKS prompt to decrypt, then the graphical GNOME login)

## Primary Tools:

- `kismet` for wireless collection and analysis (compiled from upstream git at install time)
- `wireshark` for viewing Kismet PCAPNG output
- `google-earth-pro-stable` for viewing Kismet KML map output
- `firefox` for viewing Kismet GUI and opening Kismet JSON files
- Misc. from `vanilla-gnome-desktop` (ex., Libreoffice for viewing CSV)
- Misc. from Ubuntu Server 24.04 LTS (standard GNU tools, `tmux`, etc.)

## What/Why?:

- Rapidly image multiple single-purpose systems for Kismet wireless analysis
- Ubuntu Server 24.04 LTS for nexus of maximized stability, and Kismet and STIG compatibility
- Minimizing attack surface (Ubuntu Server minimal install, add specific desired components)
- Providing analyst graphical environment for analysis versus headless with remote connection need
- STIGs pre-applied, SBOM generated, for best-effort compliance (user must manage their own risk)
- Removes unneeded Ubuntu junk  (`cloud-init`, `systemd-networkd-wait-online`, Yaru, etc.)
- Adds minimal required Kismet hardware support (ex., `gpsd`, `linux-generic-hwe-24.04` for drivers)
- Adds important quality-of-life tooling (ex., `wireshark`, non-snap `firefox`, Google Earth, etc.) 
- Builds Kismet from upstream git (latest) before STIG hardening — STIGs break compiling. `./configure` enables every Linux-applicable feature; install aborts if any are omitted
- Adds default user to all the necessary groups (`kismet`, `wireshark`, `dialout`, etc.)
- Wired Ethernet DHCP assumed during setup to K.I.S.S. (drop to another TTY to enable WiFi)
- Install pulls latest from official vetted repos versus baking offline install into media; Kismet is compiled from upstream git (not the distribution package) 
- Customizations for commonality with other internal tooling

### Disk encryption (LUKS):

- LUKS full-disk encryption is always enabled. Leaving the passphrase blank does **not** disable it; a blank passphrase is rejected and you must enter a non-empty passphrase twice
- The installer first encrypts the disk with a random install-time key. Your passphrase is never written to `/autoinstall.yaml`; it lives only in RAM (`/run/luks-user-key`) on the live installer
- The key swap (add your passphrase, remove the install-time key, shred both key files) is the **first** late-command, so a later failure (package, Kismet build, STIG) cannot leave the disk with only the install-time key. It never removes the install-time key unless your passphrase was added and verified first
- After a **successful** install, first-boot unlock uses the passphrase you entered in the dialog
- If the install dies before the key swap, the disk unlocks only with the install-time key, which exists solely in `/run/luks-install-key` on the live installer session (lost on reboot). Re-run the install rather than trying to recover that disk
- Passphrases and key file contents are never echoed to `/var/log/setup-sh.log` or the Subiquity logs

### Installer behavior:

- Package updates are applied by Subiquity (`updates: all`); there is no `apt-get upgrade` late-command. `console-setup`, `console-setup-linux`, `keyboard-configuration` and `fwupd` are held during install because `console-setup` cannot configure in the installer chroot (no console) and would fail the install
- The network check is an HTTP fetch from `archive.ubuntu.com`, not ICMP ping
- Wired DHCP is assumed; Wi-Fi is a separate task (drop to another TTY and configure Netplan/NetworkManager)
- The installed system boots to `graphical.target` with `gdm3` enabled (GNOME login on first boot)

### Notes:

- Ubuntu Pro `usg` is used for STIG application to limit additional tooling added to SBOM
- Ubuntu Pro tokens are attached for STIG application then immediately detached (returned to account) 
- The shell scripts are separated for simplicity because `setup.sh` is baked into the ISO for Subiquity

