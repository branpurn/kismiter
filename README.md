# Kismiter 

Tool for baking install ISO of single-purpose, largely *STIG-compliant Kismet workstation/platform on Ubuntu Server 24.04 LTS (x86_64) (*Security Technical Implementation Guidelines)

## Components:
| File                          | Description                                                                                 |
|-------------------------------|---------------------------------------------------------------------------------------------|
| `sbom/kismiter-sbom.spdx`     | Software Bill of Materials (Ubuntu 24.04 LTS + limited additions)                          |
| `build-kismet-iso.sh`         | Builds custom Ubuntu Server 24.04 LTS ISO with Ubuntu Subiquity automations                |
| `setup.sh`                    | Orchestrates most Kismiter customizations applied during Subiquity installer               |
| `README.md`                   | The document you are currently reading                                                     |
| `LICENSE`                     | GNU General Public License 3.0                                                             |

## Prerequisites: 
- A modern Debian-based system recommended, to generate the Kismiter ISO
- Internet connection capable of downloading the Ubuntu Server ISO 
- Ubuntu Pro token (required for Ubuntu's official STIG tooling; free) 
- Wired Ethernet Internet connection for the system being imaged with the ISO 

## Usage: 
- Download `build-kismet-iso.sh` and `setup.sh`, placing them in the same folder 
- Run the `build-kismet-iso.sh` script to create the ISO:
```
chmod +x build-kismet-iso.sh
./build-kismet-iso.sh
```
- Burn the resulting ISO to a bootable media/USB thumb drive with sufficient free space
```
sudo dd if=ubuntu-24.04-kismet-YYYYMMDD.iso of=/dev/sdb bs=4M status=progress oflag=sync conv=fsync
```
- Boot the media 
- Prompt for new hostname if desired
- Prompt for password for the default user
- Prompt for a LUKS drive encryption passphrase
- Prompt for Ubuntu Pro token (skip to omit STIGs)
- Walk away, return to completed install (LUKS prompt to decrypt)

## Primary Tools:
- `kismet` for wireless collection and analysis
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
- Adds important quality-of-life tooling (ex., `wireshark`, `nano`, non-snap `firefox`, Google Earth, etc.) 
- Adds default user to all the necessary groups (`kismet`, `wireshark`, `dialout`, etc.)
- Wired Ethernet DHCP assumed during setup to K.I.S.S. (drop to another TTY to enable WiFi)
- Install pulls latest from official vetted repos versus baking offline install into media 
- Customizations for commonality with other internal tooling

### Notes:
- Ubuntu Pro `usg` is used for STIG application to limit additional tooling added to SBOM
- Ubuntu Pro tokens are attached for STIG application then immediately detached (returned to account) 
- The shell scripts are separated for simplicity because `setup.sh` is baked into the ISO for Subiquity 

