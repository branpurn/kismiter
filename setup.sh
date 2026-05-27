#!/bin/bash
#
# setup.sh — Kismet installer configuration script
#
# Invoked as an early-command by subiquity before the main installation pass.
# Subiquity runs early-commands then re-reads /autoinstall.yaml from the live
# writable filesystem before proceeding. This script collects configuration
# interactively from the operator via dialog, generates a complete and validated
# /autoinstall.yaml incorporating those inputs, then returns control to subiquity,
# which picks up the generated config automatically on its second read.

set -euo pipefail

# Subiquity detaches early-command stdio from the console. Redirect all I/O to
# /dev/tty1 so prompts and status messages appear on the physical display.
exec 0</dev/tty1 1>/dev/tty1 2>/dev/tty1
export TERM=linux
export DEBIAN_FRONTEND=noninteractive

# Tee all stdout to a persistent log file for post-install troubleshooting
# while keeping it visible on the console throughout the run.
LOG=/var/log/setup-sh.log
exec 1> >(tee -a "$LOG" >/dev/tty1) 2>&1

# ubuntu-advantage-tools ships systemd timers that fire ~28 seconds
# after boot regardless of installer activity. AppArmor blocks their
# profile transitions in the live environment, which is harmless when
# early-commands exits quickly but causes Subiquity to fail now that
# early-commands blocks on interactive dialog prompts. Disable them
# as the very first action before any other work begins.
systemctl disable --now \
  apt-news.service apt-news.timer \
  esm-cache.service esm-cache.timer \
  ua-timer.service ua-timer.timer \
  ubuntu-advantage.service 2>/dev/null || true

clear
echo ""
echo "================================================================"
echo "  Kismet — Interactive pre-install configuration"
echo "================================================================"
echo ""

# The live environment must reach the internet before we proceed: apt needs it
# to install dialog and mkpasswd, and late-commands need it for package
# downloads. Retry for up to 60 seconds to accommodate DHCP delays.
echo "Checking network connectivity..."
ATTEMPTS=0
until ping -c1 -W3 ubuntu.com >/dev/null 2>&1; do
  ATTEMPTS=$(( ATTEMPTS + 1 ))
  if [[ $ATTEMPTS -ge 20 ]]; then
    echo "ERROR: No network after 60 seconds. Check Ethernet. Aborting."
    exit 1
  fi
  echo "  No internet yet — retrying in 3s... (attempt ${ATTEMPTS}/20)"
  sleep 3
done
echo "Network OK."
echo ""

# dialog provides the interactive TUI prompts. whois provides mkpasswd for
# SHA-512 password hashing. Both must be installed before user input begins.
echo "Installing dialog and whois..."
apt-get update -qq
apt-get install -y -qq dialog whois
echo "Ready."
echo ""

# Branding string shown at the top of every dialog prompt via --backtitle.
# Persists across screen redraws; plain text only (no ANSI codes in backtitle).
BACKTITLE="Kismiter Installer"

# Wrapper around dialog that pins all file descriptors to /dev/tty1 and captures
# output via a temp file on fd 3. This avoids conflicts with the tee-based
# logging redirect established above, which would otherwise swallow dialog output.
dlg() {
  local TMP
  TMP=$(mktemp)
  dialog --backtitle "$BACKTITLE" --output-fd 3 "$@" 3>"$TMP" </dev/tty1 >/dev/tty1 2>/dev/tty1
  cat "$TMP"
  rm -f "$TMP"
}

# Collect all operator input before writing any configuration files.
HOSTNAME=$(dlg --inputbox "Enter hostname (default: kismet)" 10 60 "kismet")
: "${HOSTNAME:=kismet}"

while true; do
  DEFENDER_PASS1=$(dlg --insecure --passwordbox "defender user password" 10 60)
  DEFENDER_PASS2=$(dlg --insecure --passwordbox "Confirm defender password" 10 60)
  [[ "$DEFENDER_PASS1" == "$DEFENDER_PASS2" ]] && break
  dialog --backtitle "$BACKTITLE" --msgbox "Passwords do not match. Try again." 8 50 \
    </dev/tty1 >/dev/tty1 2>/dev/tty1
done

while true; do
  LUKS_PASS1=$(dlg --insecure --passwordbox "LUKS full-disk encryption passphrase" 10 60)
  LUKS_PASS2=$(dlg --insecure --passwordbox "Confirm LUKS passphrase" 10 60)
  [[ "$LUKS_PASS1" == "$LUKS_PASS2" ]] && break
  dialog --backtitle "$BACKTITLE" --msgbox "Passphrases do not match. Try again." 8 50 \
    </dev/tty1 >/dev/tty1 2>/dev/tty1
done

PRO_TOKEN=$(dlg --inputbox \
"Ubuntu Pro token (leave blank or SKIP to omit STIG hardening).
Token can be reused immediately after detach on a new install.
Free accounts include 5 tokens." \
  14 70 "SKIP")
: "${PRO_TOKEN:=SKIP}"

if [ "${PRO_TOKEN}" != "SKIP" ]; then
  echo "Validating Ubuntu Pro token..."
  while true; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${PRO_TOKEN}" \
      "https://contracts.canonical.com/v1/contract")
    if [ "${HTTP}" = "200" ]; then
      echo "Token OK."
      break
    fi
    PRO_TOKEN=$(dlg --inputbox \
"Token rejected by Ubuntu Pro API (invalid or expired).
Check https://ubuntu.com/pro/dashboard for a valid token.

Re-enter token to retry, or leave blank to skip STIG hardening." \
      12 70 "SKIP")
    : "${PRO_TOKEN:=SKIP}"
    [ "${PRO_TOKEN}" = "SKIP" ] && break
  done
fi

clear
echo "Configuration collected. Generating autoinstall config..."

# Hash the defender password with SHA-512 for the identity stanza. printf is
# used instead of echo to prevent a leading '-' in the password from being
# interpreted as an echo flag.
echo "Hashing password..."
DEFENDER_HASH=$(printf '%s\n' "$DEFENDER_PASS1" | mkpasswd -m sha-512 -s)
unset DEFENDER_PASS1 DEFENDER_PASS2
echo "Done."

# The operator's LUKS passphrase never appears in the YAML. A random 64-char
# hex string (YAML-safe by construction) is used as the install-time LUKS key;
# both it and the real passphrase are written to tmpfs only. Late-commands add
# the real passphrase as a LUKS keyslot, remove the install key, and shred both
# files before the system first boots.
echo "Preparing LUKS key material..."
LUKS_INSTALL_KEY=$(openssl rand -hex 32)
printf '%s' "$LUKS_PASS1" > /run/luks-user-key
chmod 0600 /run/luks-user-key
printf '%s' "$LUKS_INSTALL_KEY" > /run/luks-install-key
chmod 0600 /run/luks-install-key
unset LUKS_PASS1 LUKS_PASS2
echo "Done."

# Select the target installation disk by finding the first block device whose
# RM (removable) flag is 0. RM=1 identifies USB sticks, SD cards, and other
# removable media — including the boot USB this ISO is running from. This
# reliably excludes the boot device regardless of disk type or kernel name.
echo "Detecting target disk..."
TARGET_DISK=$(lsblk -dno NAME,RM,TYPE | awk '$2=="0" && $3=="disk" {print "/dev/"$1}' | head -1)
if [ -z "$TARGET_DISK" ]; then
  echo "ERROR: No non-removable disk found. Check hardware and try again."
  exit 1
fi
echo "Target disk: ${TARGET_DISK}"
echo ""

# Pre-compute base64-encoded dconf configuration. The encoded values consist
# solely of alphanumeric characters plus +, /, and = — all safe as YAML plain
# scalar values with no quoting or escaping needed. Late-commands pipe them
# through base64 -d to write the original content to the installed system.
# This avoids heredoc-inside-heredoc and YAML indentation conflicts that arise
# when trying to embed multi-line content with single quotes in block scalars.
DCONF_PROFILE_B64=$(printf 'user-db:user\nsystem-db:local\n' | base64 -w0)
DCONF_CONTENT_B64=$(printf '%s\n' \
  '[org/gnome/desktop/background]' \
  "picture-uri='file:///usr/share/backgrounds/Greenish_by_EstebanMitnick.jpg'" \
  "picture-uri-dark='file:///usr/share/backgrounds/Greenish_by_EstebanMitnick.jpg'" \
  '' \
  '[org/gnome/desktop/interface]' \
  "icon-theme='Adwaita'" | base64 -w0)

# Write the main autoinstall config. Subiquity re-reads /autoinstall.yaml
# after early-commands complete; this file is on the live writable tmpfs.
cat > /autoinstall.yaml << YAML
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  network:
    network:
      version: 2
      ethernets:
        any:
          match:
            name: "en*"
          dhcp4: true
  storage:
    config:
      # Target disk selected at runtime based on removable flag — excludes the
      # boot USB regardless of device name (sda, nvme0n1, vda, etc.).
      - id: disk0
        type: disk
        ptable: gpt
        path: "${TARGET_DISK}"
        wipe: superblock-recursive
        preserve: false
      # EFI system partition. 512 MB is generous; it avoids space issues from
      # accumulating GRUB and shim updates on long-lived installations.
      - id: efi-part
        type: partition
        device: disk0
        size: 512M
        flag: boot
        grub_device: true
      - id: efi-format
        type: format
        volume: efi-part
        fstype: fat32
        label: EFI
      - id: efi-mount
        type: mount
        device: efi-format
        path: /boot/efi
      # Unencrypted /boot. GRUB must read this partition to load the kernel
      # and initramfs before the operator enters the LUKS passphrase.
      - id: boot-part
        type: partition
        device: disk0
        size: 1G
      - id: boot-format
        type: format
        volume: boot-part
        fstype: ext4
        label: boot
      - id: boot-mount
        type: mount
        device: boot-format
        path: /boot
      # Everything else lives inside a LUKS-encrypted LVM container. The key
      # written here is a random hex string generated above — the operator's
      # real passphrase is swapped in via late-commands after install completes.
      - id: lvm-part
        type: partition
        device: disk0
        size: -1
      - id: luks-root
        type: dm_crypt
        volume: lvm-part
        key: "${LUKS_INSTALL_KEY}"
      - id: vg0
        type: lvm_volgroup
        name: ubuntu-vg
        devices:
          - luks-root
      - id: lv-root
        type: lvm_partition
        volgroup: vg0
        size: 80G
        name: root
      - id: lv-root-format
        type: format
        volume: lv-root
        fstype: ext4
      - id: lv-root-mount
        type: mount
        device: lv-root-format
        path: /
      - id: lv-var
        type: lvm_partition
        volgroup: vg0
        size: 40G
        name: var
      - id: lv-var-format
        type: format
        volume: lv-var
        fstype: ext4
      - id: lv-var-mount
        type: mount
        device: lv-var-format
        path: /var
        options: "defaults,nosuid,nodev"
      - id: lv-varlog
        type: lvm_partition
        volgroup: vg0
        size: 20G
        name: varlog
      - id: lv-varlog-format
        type: format
        volume: lv-varlog
        fstype: ext4
      - id: lv-varlog-mount
        type: mount
        device: lv-varlog-format
        path: /var/log
        options: "defaults,noexec,nosuid,nodev"
      - id: lv-varlogaudit
        type: lvm_partition
        volgroup: vg0
        size: 10G
        name: varlogaudit
      - id: lv-varlogaudit-format
        type: format
        volume: lv-varlogaudit
        fstype: ext4
      - id: lv-varlogaudit-mount
        type: mount
        device: lv-varlogaudit-format
        path: /var/log/audit
        options: "defaults,noexec,nosuid,nodev"
      - id: lv-tmp
        type: lvm_partition
        volgroup: vg0
        size: 16G
        name: tmp
      - id: lv-tmp-format
        type: format
        volume: lv-tmp
        fstype: ext4
      - id: lv-tmp-mount
        type: mount
        device: lv-tmp-format
        path: /tmp
        options: "defaults,noexec,nosuid,nodev"
      - id: lv-home
        type: lvm_partition
        volgroup: vg0
        size: -1
        name: home
      - id: lv-home-format
        type: format
        volume: lv-home
        fstype: ext4
      - id: lv-home-mount
        type: mount
        device: lv-home-format
        path: /home
        options: "defaults,nosuid,nodev"
  identity:
    hostname: ${HOSTNAME}
    username: defender
    password: "${DEFENDER_HASH}"
    realname: defender
  ssh:
    install-server: true
    allow-pw: true
  late-commands:
    # Plymouth provides a graphical boot splash instead of kernel log output.
    # FRAMEBUFFER=y tells the initramfs to keep the framebuffer active so
    # Plymouth can paint over it. The bgrt theme uses the system OEM logo.
    - curtin in-target --target=/target -- apt-get install -y plymouth plymouth-themes
    - sh -c 'echo "FRAMEBUFFER=y" > /target/etc/initramfs-tools/conf.d/splash'
    - curtin in-target --target=/target -- sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
    - curtin in-target --target=/target -- update-alternatives --set default.plymouth /usr/share/plymouth/themes/bgrt/bgrt.plymouth || true

    # Full system update before installing additional packages ensures all
    # dependency resolution works against the latest available versions.
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- apt-get upgrade -y

    # Core desktop and tool packages. vanilla-gnome-desktop installs stock
    # GNOME without Ubuntu's customizations. gpsd and clients support GPS
    # receivers attached to the system for use with Kismet.
    - curtin in-target --target=/target -- apt-get install -y vanilla-gnome-desktop vanilla-gnome-default-settings network-manager nano openssh-server gpsd gpsd-tools gpsd-clients zstd

    # byobu is a terminal multiplexer pulled in as a dependency or suggestion
    # by some Ubuntu packages; it adds an unwanted session wrapper to the GNOME
    # terminal. gnome-console (kgx) is Ubuntu's alternative terminal that
    # duplicates gnome-terminal on vanilla GNOME — we only want one terminal.
    - curtin in-target --target=/target -- apt-get purge -y byobu gnome-console || true

    # NetworkManager handles network interfaces for the desktop session.
    # Masking systemd-networkd-wait-online prevents it from competing with
    # NetworkManager for interface control and adding unnecessary boot latency.
    - curtin in-target --target=/target -- systemctl enable NetworkManager
    - curtin in-target --target=/target -- systemctl mask systemd-networkd-wait-online.service

    # Firefox native .deb from Mozilla's apt repository rather than the Ubuntu
    # snap wrapper. The Ubuntu archive firefox package carries epoch 1: in its
    # version number, causing apt to treat the Mozilla deb as a downgrade.
    # Purging the wrapper package first avoids that version conflict.
    - curtin in-target --target=/target -- sh -c 'mkdir -p /etc/apt/keyrings'
    - curtin in-target --target=/target -- sh -c 'wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null'
    - curtin in-target --target=/target -- sh -c 'echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list'
    # "Package: *" would trigger a YAML alias scan if written as a plain scalar;
    # the literal block scalar (|) prevents that by making the content opaque.
    - |
      curtin in-target --target=/target -- sh -c 'printf "Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n" > /etc/apt/preferences.d/mozilla'
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- snap remove --purge firefox || true
    - curtin in-target --target=/target -- apt-get remove --purge -y firefox || true
    - curtin in-target --target=/target -- apt-get install -y firefox

    # Kismet wireless network detector and packet capture tool. The SUID install
    # allows Kismet to open raw packet capture interfaces without running the
    # entire application as root. The kismet group gates access to that binary.
    - curtin in-target --target=/target -- sh -c 'wget -qO- https://www.kismetwireless.net/repos/kismet-release.gpg.key | gpg --dearmor > /usr/share/keyrings/kismet-archive-keyring.gpg'
    - curtin in-target --target=/target -- sh -c 'echo "deb [signed-by=/usr/share/keyrings/kismet-archive-keyring.gpg] https://www.kismetwireless.net/repos/apt/release/noble noble main" > /etc/apt/sources.list.d/kismet.list'
    - curtin in-target --target=/target -- apt-get update
    - curtin in-target --target=/target -- sh -c 'echo "kismet kismet/install-suid boolean true" | debconf-set-selections'
    - curtin in-target --target=/target -- apt-get install -y kismet

    # Wireshark GUI and CLI packet analysis. The install-setuid selection allows
    # members of the wireshark group to open capture interfaces without sudo.
    - curtin in-target --target=/target -- sh -c 'echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections'
    - curtin in-target --target=/target -- apt-get install -y wireshark

    # Add defender to all groups that gate privileged hardware access:
    #   kismet    — raw packet capture via Kismet without sudo
    #   dialout   — serial and GPS device access
    #   wireshark — raw packet capture via Wireshark without sudo
    - curtin in-target --target=/target -- usermod -aG kismet,dialout,wireshark defender

    # Alfa AWUS036AXML (MediaTek MT7921AUN) firmware.
    # The mt7921u kernel module ships with Ubuntu 24.04's 6.8 kernel but the
    # firmware blobs for the USB-specific AUN variant may not be present in the
    # Ubuntu archive's linux-firmware package version. Reinstalling linux-firmware
    # pulls the latest packaged version; the upstream git fetch supplements with
    # files that may not yet have reached the Ubuntu package.
    # NOTE: adapter functionality with this firmware is unconfirmed — verify
    # after install that the adapter appears and associates correctly.
    - curtin in-target --target=/target -- apt-get install -y --reinstall linux-firmware
    # HWE kernel for contemporary hardware driver support. Must be installed
    # before firmware decompression steps below — the HWE linux-firmware
    # dependency pull may update the .zst blobs that need unpacking.
    - curtin in-target --target=/target -- apt-get install -y linux-generic-hwe-24.04
    # Ubuntu ships these MT7961 firmware blobs as .zst-compressed files but does
    # not decompress them automatically on install, leaving the kernel unable to
    # load the firmware at runtime. Fetch from upstream linux-firmware git first;
    # if wget fails or produces an empty file (e.g. GitHub connectivity issue),
    # fall back to decompressing the .zst blob shipped with the linux-firmware
    # package. The -s test guards against silent zero-byte wget results, which
    # previously overwrote correctly decompressed blobs and caused error -22
    # (EINVAL) at firmware load time.
    - |
      FWDIR=/target/lib/firmware/mediatek
      mkdir -p \$FWDIR
      BASE=https://github.com/linux-firmware/linux-firmware/raw/main/mediatek
      for FW in WIFI_MT7961_patch_mcu_1_2_hdr.bin WIFI_RAM_CODE_MT7961_1.bin; do
        wget -q -O \$FWDIR/\$FW \$BASE/\$FW || true
        if [ ! -s \$FWDIR/\$FW ]; then
          zstd -d \$FWDIR/\${FW}.zst -o \$FWDIR/\$FW --force || true
        fi
      done

    # cloud-init is not needed outside cloud environments and adds boot latency.
    # autoremove cleans up orphaned dependencies left behind by purged packages.
    - curtin in-target --target=/target -- apt-get purge -y cloud-init
    - curtin in-target --target=/target -- apt-get autoremove -y

YAML

# ── Ubuntu Pro + STIG section ─────────────────────────────────────────────────
#
# Ubuntu Pro attach strategy (confirmed against Subiquity 24.04.4):
#
# The ubuntu-pro: stanza is written into autoinstall.yaml and processed by
# Subiquity during its install pass. However, Subiquity 24.04.4 does NOT
# propagate this attach into /target — the chroot remains unattached. An
# explicit `pro attach` in-target is therefore required in late-commands.
# The stanza is kept as belt-and-suspenders in case future Subiquity versions
# do propagate it, and because it costs nothing to include.
#
# The ubuntu-pro: stanza is injected via Python rather than a heredoc so that
# indentation is handled programmatically and PRO_TOKEN quoting is clean.

if [ "${PRO_TOKEN}" = "SKIP" ]; then
  # No Pro token — append a GDM banner warning and skip all STIG steps.
  cat >> /autoinstall.yaml << 'YAML_SKIP'
    # Ubuntu Pro token was not provided — STIG hardening skipped.
    # Write a banner to the GDM greeter so the operator is notified at graphical
    # login. Uses \47 (octal single-quote) inside printf to embed the GVariant
    # string delimiters required by the dconf keyfile format without breaking the
    # surrounding shell quoting. The existing dconf update call in the
    # continuation YAML block below will compile this file into the binary dconf
    # database.
    - sh -c 'mkdir -p /target/etc/dconf/db/gdm.d'
    - sh -c 'printf "[org/gnome/login-screen]\nbanner-message-enable=true\nbanner-message-text=\47DISA STIG hardening was skipped during installation. If STIG compliance is required, controls must be manually applied.\47\n" > /target/etc/dconf/db/gdm.d/01-kismet-stig-banner'
YAML_SKIP
else
  # Valid Pro token — inject the ubuntu-pro: stanza so Subiquity records the
  # token in the installer's own attach path. This is a belt-and-suspenders
  # measure: Subiquity 24.04.4 does NOT propagate this attach into /target
  # (confirmed via crash log: UbuntuPro/apply_autoinstall_config succeeds but
  # the chroot remains unattached). The explicit in-target pro attach below is
  # therefore still required. The stanza is kept because future Subiquity
  # versions may change this behaviour, and it costs nothing to include.
  #
  # The stanza is inserted immediately before the late-commands: key via a
  # targeted string replacement. Python is used rather than sed to avoid
  # YAML-significant characters in the replacement string requiring escaping.
  python3 - << PYEOF
content = open('/autoinstall.yaml').read()
stanza = "  ubuntu-pro:\n    token: \"${PRO_TOKEN}\"\n"
# Replace only the first occurrence so storage config comments containing
# "late-commands" (theoretically) are not affected.
content = content.replace("  late-commands:", stanza + "  late-commands:", 1)
open('/autoinstall.yaml', 'w').write(content)
PYEOF
  echo "ubuntu-pro stanza injected into autoinstall.yaml."

  # YAML_PRO is intentionally UNQUOTED so ${PRO_TOKEN} expands to the literal
  # token value when setup.sh writes this block into autoinstall.yaml. Every
  # other heredoc in this file uses single-quotes to suppress expansion; this
  # one is the explicit exception because the token must be baked in at
  # YAML-generation time — it is not available as a shell variable at the point
  # late-commands execute inside the Subiquity runner.
  cat >> /autoinstall.yaml << YAML_PRO
    # Subiquity 24.04.4 does not propagate the ubuntu-pro: stanza attach into
    # /target. Attach explicitly inside the chroot so pro enable and usg can
    # run. --no-auto-enable prevents pro from attempting to load kernel modules
    # (Livepatch etc.) inside the chroot, where they cannot run.
    # No || true here — if attach fails we want a visible fatal error, not
    # silent STIG skip.
    - curtin in-target --target=/target -- pro attach "${PRO_TOKEN}" --no-auto-enable

    # Enable only the usg entitlement. Enabling individually avoids pulling in
    # ESM, Livepatch, and other services that are unnecessary on this host.
    - curtin in-target --target=/target -- pro enable usg --assume-yes
    - curtin in-target --target=/target -- apt-get install -y usg

    # usg fix applies all automatable DISA STIG controls. This step takes
    # 15-30 minutes. Some controls require a reboot or manual action and will
    # exit non-zero even on a fully successful run — || true prevents that from
    # aborting the installation.
    #
    # UBTU-24-600230 blacklists wireless kernel modules system-wide. This system
    # is a wireless analysis platform — disabling wireless would defeat its
    # purpose. A tailoring file is generated to deselect that rule before fix
    # runs. The same tailoring file is passed to audit so the intentionally
    # disabled rule is not flagged as a finding in the compliance report.
    #
    # usg generate-tailoring syntax (24.04.8): positional args only — profile
    # then output path. No flags. Confirmed from binary:
    #   usage: usg [-h] [-d] profile output
    # /tmp is used inside the chroot (visible from host as /target/tmp). A python3
    # script is written to /target/tmp and run in-target to patch the attribute
    # without any double-quote nesting in the YAML/shell quoting chain.
    - curtin in-target --target=/target -- usg generate-tailoring disa_stig /tmp/kismet-tailoring.xml
    - sh -c 'echo aW1wb3J0IHJlCmY9b3BlbigiL3RhcmdldC90bXAva2lzbWV0LXRhaWxvcmluZy54bWwiKQp0PWYucmVhZCgpCmYuY2xvc2UoKQp0PXJlLnN1YigiKHdpcmVsZXNzX2Rpc2FibGVfaW50ZXJmYWNlc1tePF0qc2VsZWN0ZWQ9KVwidHJ1ZVwiIiwiXFxnPDE+XCJmYWxzZVwiIix0KQpvcGVuKCIvdGFyZ2V0L3RtcC9raXNtZXQtdGFpbG9yaW5nLnhtbCIsInciKS53cml0ZSh0KQo= | base64 -d | python3'
    - curtin in-target --target=/target -- usg fix --tailoring-file /tmp/kismet-tailoring.xml || true
    - curtin in-target --target=/target -- usg audit --tailoring-file /tmp/kismet-tailoring.xml || true
    - sh -c 'mkdir -p /target/root/stig-results-final'
    - sh -c 'cp /target/tmp/kismet-tailoring.xml /target/root/stig-results-final/ || true'
    - sh -c 'cp -r /target/var/lib/usg/ /target/root/stig-results-final/ || true'

    # Detach the install-time token from the target so the deployed system
    # starts unattached. The operator re-attaches post-install with their own
    # token if ongoing Pro services (ESM, Livepatch, etc.) are wanted.
    # || true because a detach failure should not abort an otherwise complete
    # install — STIG hardening has already been applied at this point.
    - curtin in-target --target=/target -- pro detach --assume-yes || true

    # The DISA STIG enables smart card (PIV/CAC) authentication by inserting
    # pam_pkcs11 into the PAM stack. This system does not use smart cards;
    # leaving the module active causes every PAM authentication attempt to log
    # "Error 2308: No smart card found". Remove the pam_pkcs11 lines from all
    # affected PAM config files without uninstalling the module itself, so it
    # remains available if smart card auth is ever needed in future.
    - sh -c 'grep -rl pam_pkcs11 /target/etc/pam.d/ | xargs -r sed -i "/pam_pkcs11/d"'
YAML_PRO
fi

# ── Shared tail: LUKS key swap, dconf, initramfs, GRUB ───────────────────────
cat >> /autoinstall.yaml << YAML
    # Replace the random install-time LUKS key with the operator's real
    # passphrase. blkid finds the LUKS container dynamically so this works
    # regardless of the disk's kernel name. Both key files live only in tmpfs
    # (RAM); shredding them is belt-and-suspenders but correct practice.
    - sh -c 'LUKS_DEV=\$(blkid -t TYPE=crypto_LUKS -o device | head -1); cryptsetup luksAddKey \$LUKS_DEV /run/luks-user-key --key-file /run/luks-install-key'
    - sh -c 'LUKS_DEV=\$(blkid -t TYPE=crypto_LUKS -o device | head -1); cryptsetup luksRemoveKey \$LUKS_DEV --key-file /run/luks-install-key'
    - sh -c 'shred -u /run/luks-install-key /run/luks-user-key'

    # GNOME system-wide defaults via dconf. Writing to /etc/dconf/db/local.d/
    # sets defaults visible to all users without locking them — defender can
    # override these settings after first login via GNOME Settings. The dconf
    # profile file tells GNOME to layer the system-db over the per-user db.
    # dconf update compiles the keyfile directory into the binary database that
    # GNOME reads at session start; it does not require D-Bus and is safe in a
    # chroot. Content is base64-encoded above to avoid quoting and indentation
    # conflicts between the YAML block scalar and the outer heredoc.
    - sh -c 'mkdir -p /target/etc/dconf/profile /target/etc/dconf/db/local.d'
    - sh -c 'echo ${DCONF_PROFILE_B64} | base64 -d > /target/etc/dconf/profile/user'
    - sh -c 'echo ${DCONF_CONTENT_B64} | base64 -d > /target/etc/dconf/db/local.d/00-defaults'
    - curtin in-target --target=/target -- dconf update

    # Rebuild the initramfs for all installed kernels. Required after any change
    # affecting early boot: LUKS/cryptsetup config, firmware additions from the
    # MT7921AUN step, or kernel parameter changes written by usg fix.
    - curtin in-target --target=/target -- update-initramfs -u -k all
    # Regenerate GRUB config to pick up all changes made during late-commands:
    # quiet splash, USG kernel parameters (audit=1, apparmor, etc.), LUKS setup.
    - curtin in-target --target=/target -- update-grub
YAML

unset LUKS_INSTALL_KEY PRO_TOKEN HOSTNAME DEFENDER_HASH TARGET_DISK DCONF_PROFILE_B64 DCONF_CONTENT_B64

# Validate the generated YAML immediately. Catching a syntax error here produces
# a clear message pointing back to setup.sh; the same error caught by subiquity
# after early-commands return produces a cryptic traceback with no useful context.
echo "Validating /autoinstall.yaml..."
if python3 -c "import yaml; yaml.safe_load(open('/autoinstall.yaml'))" 2>&1; then
  echo "YAML OK."
else
  echo ""
  echo "ERROR: /autoinstall.yaml failed YAML validation — fix setup.sh and rebuild ISO."
  exit 1
fi

# casper-md5check verifies every file on the ISO against /md5sum.txt at boot.
# When setup.sh is replaced in the ISO during development without rebuilding
# the full manifest, its hash entry becomes stale and triggers a warning. Update
# the live tmpfs copy of md5sum.txt to silence the warning. This does not modify
# the ISO itself — the fix applies only to the current boot's in-memory copy.
if [ -f /md5sum.txt ] && [ -f /cdrom/casper/setup.sh ]; then
  NEW_HASH=$(md5sum /cdrom/casper/setup.sh | awk '{print $1}')
  if grep -q "casper/setup.sh" /md5sum.txt; then
    sed -i "s|.*casper/setup\.sh.*|${NEW_HASH}  ./casper/setup.sh|" /md5sum.txt
  else
    echo "${NEW_HASH}  ./casper/setup.sh" >> /md5sum.txt
  fi
  echo "md5sum.txt updated for casper/setup.sh."
fi

echo ""
echo "/autoinstall.yaml written. Returning to subiquity."
echo ""