#!/bin/bash
#
# build-kismet-iso.sh — Repackages the official Ubuntu 24.04 live-server ISO
# into a custom installer that runs setup.sh as an early-command. setup.sh
# prompts the operator interactively for hostname, passwords, and an optional
# Ubuntu Pro token, then generates a complete autoinstall.yaml that subiquity
# picks up automatically on its second config read.

set -euo pipefail

WORK_DIR="iso-work"
DATESTAMP=$(date +%Y%m%d)
OUTPUT_ISO="ubuntu-24.04-kismet-${DATESTAMP}.iso"

# Remove the working directory and any partial output ISO on failure. Partial
# xorriso output files are treated as fixed-size media on the next run, causing
# xorriso to refuse writing an image larger than the stale file. Deleting them
# ensures a clean slate. The trap is removed on success so it does not fire.
cleanup() {
  echo "ERROR: build failed. Cleaning up..." >/dev/tty 2>&1 || true
  sudo rm -rf "${WORK_DIR}" 2>/dev/null || true
  rm -f "${OUTPUT_ISO}" 2>/dev/null || true
}
trap cleanup ERR

# xorriso extracts files preserving their ISO permission bits. Directories in
# Ubuntu ISOs are typically mode 555 (not writable by anyone). This function
# fixes ownership and directory permissions so subsequent operations do not
# require sudo for file I/O inside the working directory.
fix_permissions() {
  sudo chown -R "$(id -u):$(id -g)" "${WORK_DIR}"
  sudo find "${WORK_DIR}" -type d -exec chmod u+rwx {} +
}

echo "This script requires sudo. You may be prompted for your password."
sudo -v

echo "Installing build prerequisites..."
sudo apt-get update -qq
sudo apt-get install -y xorriso wget dialog whois dos2unix grub-pc-bin

# Locate the official Ubuntu 24.04 live-server ISO in the current directory,
# downloading it (with checksum verification) if not already present.
ISO_ORIGINAL=$(ls ubuntu-24.04*-live-server-amd64.iso 2>/dev/null | head -n1 || true)
if [[ -z "$ISO_ORIGINAL" ]]; then
  echo "=== OFFICIAL UBUNTU 24.04 LIVE-SERVER ISO NOT FOUND ==="
  echo "We need ubuntu-24.04.4-live-server-amd64.iso"
  read -rp "Download it now? (y/N): " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Downloading ISO..."
    wget -q --show-progress \
      https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso
    ISO_ORIGINAL="ubuntu-24.04.4-live-server-amd64.iso"

    echo "Verifying ISO integrity..."
    wget -q https://releases.ubuntu.com/24.04.4/SHA256SUMS
    wget -q https://releases.ubuntu.com/24.04.4/SHA256SUMS.gpg
    # Attempt GPG verification if the Ubuntu signing key is reachable. Skip
    # the signature check (with a warning) if the keyserver is unavailable,
    # as in air-gapped or restricted CI environments.
    if gpg --keyserver hkps://keyserver.ubuntu.com \
           --recv-keys 843938DF228D22F7B3742BC0D94AA3F0EFE21092 2>/dev/null; then
      gpg --verify SHA256SUMS.gpg SHA256SUMS \
        || { echo "ERROR: SHA256SUMS GPG signature invalid. Aborting."; exit 1; }
    else
      echo "WARNING: Ubuntu GPG key unavailable — skipping signature check."
    fi
    sha256sum -c SHA256SUMS --ignore-missing \
      || { echo "ERROR: ISO checksum mismatch. Download may be corrupt. Aborting."; exit 1; }
    echo "ISO checksum verified OK."
  else
    echo "Aborting."
    exit 1
  fi
fi

# Each build produces a datestamped output ISO (~3.2 GB). Previous builds
# accumulate silently and consume disk space; the cleanup trap only removes
# the current build's file, not older ones. Offer to delete them now so the
# disk-space preflight below sees accurate free space.
OLD_ISOS=$(ls ubuntu-24.04-kismet-*.iso 2>/dev/null \
           | grep -v "^${OUTPUT_ISO}$" || true)
if [[ -n "$OLD_ISOS" ]]; then
  echo ""
  echo "=== Old Kismet ISO(s) found ==="
  du -sh $OLD_ISOS
  read -rp "Delete them to free disk space before building? (Y/n): " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Nn] ]]; then
    rm -f $OLD_ISOS
    echo "Deleted."
  else
    echo "Keeping old ISOs. Build may fail if disk space is insufficient."
  fi
  echo ""
fi

# Verify sufficient free disk space before beginning. The build requires
# roughly 2× the source ISO size: once for the extracted working directory
# and once for the output ISO, plus 10% headroom.
ISO_BYTES=$(stat -c%s "${ISO_ORIGINAL}")
REQUIRED_BYTES=$(( ISO_BYTES * 2 + ISO_BYTES / 10 ))
AVAILABLE_BYTES=$(df --output=avail -B1 . | tail -1)

ISO_MB=$(( ISO_BYTES      / 1024 / 1024 ))
REQ_MB=$(( REQUIRED_BYTES / 1024 / 1024 ))
AVL_MB=$(( AVAILABLE_BYTES / 1024 / 1024 ))

echo "Disk space check:"
echo "  Source ISO:  ${ISO_MB} MB"
echo "  Required:    ${REQ_MB} MB  (2.1× source ISO)"
echo "  Available:   ${AVL_MB} MB"

if (( AVAILABLE_BYTES < REQUIRED_BYTES )); then
  echo ""
  echo "ERROR: Insufficient disk space."
  echo "  Need ${REQ_MB} MB, have ${AVL_MB} MB."
  echo "  Free at least $(( (REQUIRED_BYTES - AVAILABLE_BYTES) / 1024 / 1024 )) MB and retry."
  echo "  Tip: old Kismet ISOs in this directory are the most likely culprit."
  exit 1
fi
echo "  Disk space OK."
echo ""

echo "Building ${OUTPUT_ISO} ..."
sudo rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

echo "Extracting ISO with xorriso..."
xorriso -osirrox on -indev "${ISO_ORIGINAL}" -extract / "${WORK_DIR}"
fix_permissions

# Detect the BIOS El Torito boot image. The file name varies across Ubuntu
# 24.04 point releases, so we probe known locations rather than hardcoding.
echo "=== Detecting boot images in extracted ISO ==="

BIOS_IMG=""
for candidate in \
    "${WORK_DIR}/boot/grub/i386-pc/eltorito.img" \
    "${WORK_DIR}/boot/grub/bios.img" \
    "${WORK_DIR}/boot/grub/i386-pc/core.img"; do
  if [[ -f "$candidate" ]]; then
    BIOS_IMG="${candidate#${WORK_DIR}/}"
    echo "  Found BIOS boot image: ${BIOS_IMG}"
    break
  fi
done
if [[ -z "$BIOS_IMG" ]]; then
  echo "ERROR: No BIOS El Torito boot image found in extracted ISO."
  echo "  Searched: boot/grub/i386-pc/eltorito.img, boot/grub/bios.img"
  exit 1
fi

# Detect the EFI system partition image. Ubuntu 24.04 live-server does not
# store the EFI image as a regular file in the ISO 9660 filesystem; it is
# written as a raw appended partition at the end of the ISO. xorriso's El
# Torito report exposes it as an --interval: reference with start/size values
# that must be extracted via dd with the correct sector arithmetic:
#   start: S × 2048 bytes (ISO 2048-byte sectors)
#   size:  N × 512 bytes  (appended partition 512-byte sectors)
EFI_IMG=""

for candidate in \
    "${WORK_DIR}/boot/grub/efi.img" \
    "${WORK_DIR}/EFI/efiboot.img" \
    "${WORK_DIR}/EFI/boot/efiboot.img" \
    "${WORK_DIR}/boot/grub/x86_64-efi/efi.img" \
    "${WORK_DIR}/isolinux/efiboot.img" \
    "${WORK_DIR}/efi.img"; do
  if [[ -f "$candidate" ]]; then
    EFI_IMG="${candidate#${WORK_DIR}/}"
    echo "  Found EFI partition image (file): ${EFI_IMG}"
    break
  fi
done

if [[ -z "$EFI_IMG" ]]; then
  echo "  No EFI image file found — extracting from ISO El Torito catalog..."
  EFI_IMG_PATH="${WORK_DIR}/boot/grub/efi.img"

  EFI_ELTORITO_PATH=$(
    xorriso -indev "${ISO_ORIGINAL}" \
            -report_el_torito as_mkisofs 2>/dev/null \
    | grep -- '-e ' \
    | tail -n1 \
    | sed "s/.*-e '\\?//; s/'\\?\$//"
  )

  echo "  El Torito reports EFI entry: ${EFI_ELTORITO_PATH}"

  if [[ -z "$EFI_ELTORITO_PATH" ]]; then
    echo "  WARNING: xorriso reported no -e entries in El Torito catalog."

  elif [[ "$EFI_ELTORITO_PATH" == --interval:appended_partition_* ]]; then
    # Parse start and size from the xorriso NOTE line (authoritative), with
    # fallback to parsing the interval string itself.
    XORRISO_NOTE=$(
      xorriso -indev "${ISO_ORIGINAL}" \
              -report_el_torito as_mkisofs 2>&1 \
      | grep 'EFI image start and size:' || true
    )

    START_2K=$(echo "$XORRISO_NOTE" \
      | grep -oP 'EFI image start and size:\s+\K[0-9]+' || true)
    SIZE_512=$(echo "$XORRISO_NOTE" \
      | grep -oP '\*\s*2048\s*,\s*\K[0-9]+(?=\s*\*\s*512)' || true)

    if [[ -z "$START_2K" ]]; then
      START_2K=$(echo "$EFI_ELTORITO_PATH" \
        | grep -oP 'start_\K[0-9]+(?=s)' || true)
    fi
    if [[ -z "$SIZE_512" ]]; then
      SIZE_512=$(echo "$EFI_ELTORITO_PATH" \
        | grep -oP 'size_\K[0-9]+(?=d)' || true)
    fi

    if [[ -z "$START_2K" || -z "$SIZE_512" ]]; then
      echo "ERROR: Could not determine EFI partition start/size."
      echo "  EFI_ELTORITO_PATH=${EFI_ELTORITO_PATH}"
      echo "  START_2K=${START_2K:-unset}  SIZE_512=${SIZE_512:-unset}"
      exit 1
    fi

    # Convert the 2048-byte sector start offset to 512-byte units for dd.
    START_512=$(( START_2K * 4 ))
    echo "  dd: start=${START_2K}×2048 = ${START_512}×512, size=${SIZE_512}×512"

    # Write to /tmp first (always user-writable), then move into WORK_DIR.
    TMP_EFI=$(mktemp /tmp/efi_img.XXXXXX)
    dd if="${ISO_ORIGINAL}" \
       bs=512 \
       skip="${START_512}" \
       count="${SIZE_512}" \
       of="${TMP_EFI}" \
       status=progress \
      || { echo "ERROR: dd extraction of EFI partition failed."; rm -f "${TMP_EFI}"; exit 1; }

    sudo mkdir -p "$(dirname "${EFI_IMG_PATH}")"
    sudo cp "${TMP_EFI}" "${EFI_IMG_PATH}"
    sudo chown "$(id -u):$(id -g)" "${EFI_IMG_PATH}"
    rm -f "${TMP_EFI}"
    fix_permissions

  else
    echo "  Extracting EFI image from ISO filesystem: ${EFI_ELTORITO_PATH}"
    xorriso -osirrox on -indev "${ISO_ORIGINAL}" \
      -extract "${EFI_ELTORITO_PATH}" "${EFI_IMG_PATH}" 2>/dev/null \
      || true
    fix_permissions
  fi

  if [[ -f "${EFI_IMG_PATH}" && -s "${EFI_IMG_PATH}" ]]; then
    EFI_IMG="boot/grub/efi.img"
    echo "  EFI partition image ready: ${EFI_IMG} ($(du -sh "${EFI_IMG_PATH}" | cut -f1))"
  else
    echo "  Extraction failed — scanning extracted tree for any *.img..."
    FOUND=$(find "${WORK_DIR}" -type f -name "*.img" \
      ! -name "bios.img" ! -name "core.img" ! -name "eltorito.img" \
      2>/dev/null | head -n1 || true)
    if [[ -n "$FOUND" ]]; then
      EFI_IMG="${FOUND#${WORK_DIR}/}"
      echo "  Found EFI image via filesystem scan: ${EFI_IMG}"
    fi
  fi
fi

if [[ -z "$EFI_IMG" ]]; then
  echo "ERROR: Could not locate the EFI system partition image."
  echo "  Run this to inspect what's available in the extracted ISO:"
  echo "    find ${WORK_DIR} -name '*.img' | sort"
  echo "  And check what El Torito reports:"
  echo "    xorriso -indev ${ISO_ORIGINAL} -report_el_torito as_mkisofs"
  exit 1
fi

# grub-pc-bin provides boot_hybrid.img, which enables the ISO to boot from
# both legacy BIOS (via MBR) and UEFI (via the EFI partition) on the same image.
HYBRID_MBR="/usr/lib/grub/i386-pc/boot_hybrid.img"
if [[ ! -f "$HYBRID_MBR" ]]; then
  echo "ERROR: ${HYBRID_MBR} not found. Ensure grub-pc-bin is installed."
  exit 1
fi

if [[ ! -f setup.sh ]]; then
  echo "ERROR: setup.sh is missing from the current directory."
  exit 1
fi

# Normalize line endings before embedding. Windows-style CRLF endings in
# shell scripts cause subtle failures (the CR appears as part of the command).
dos2unix setup.sh
sudo cp setup.sh "${WORK_DIR}/casper/"
sudo chmod +x "${WORK_DIR}/casper/setup.sh"
sudo chown "$(id -u):$(id -g)" "${WORK_DIR}/casper/setup.sh"

# The nocloud datasource provides a minimal autoinstall seed that subiquity
# reads before early-commands run. It contains only the early-commands stanza
# pointing to setup.sh. setup.sh then generates the full /autoinstall.yaml
# and subiquity re-reads it after early-commands complete.
sudo mkdir -p "${WORK_DIR}/nocloud"
sudo chown "$(id -u):$(id -g)" "${WORK_DIR}/nocloud"

cat > "${WORK_DIR}/nocloud/user-data" << 'USERDATA'
#cloud-config
autoinstall:
  version: 1
  early-commands:
    - /cdrom/casper/setup.sh
USERDATA

touch "${WORK_DIR}/nocloud/meta-data"

# GRUB menu with two entries: the automated installer (default, 5-second
# timeout) and a manual fallback that drops into the standard Ubuntu installer.
sudo tee "${WORK_DIR}/boot/grub/grub.cfg" > /dev/null << 'GRUB'
set timeout=5

menuentry "Kismet installer (automated)" {
  set gfxpayload=keep
  linux /casper/vmlinuz quiet splash autoinstall ds=nocloud\;s=/cdrom/nocloud/ ---
  initrd /casper/initrd
}

menuentry "Try or Install Ubuntu Server (manual)" {
  set gfxpayload=keep
  linux /casper/vmlinuz quiet splash ---
  initrd /casper/initrd
}
GRUB

echo "Repacking into ${OUTPUT_ISO} ..."
# Remove any pre-existing output file before writing. xorriso treats an
# existing file as fixed-size overwriteable media, so a stale partial file
# from a previous failed build would cause xorriso to refuse writing a larger
# image into it.
rm -f "${OUTPUT_ISO}"
xorriso -as mkisofs -r -V "Ubuntu 24.04 Kismet STIG" \
  -J -l \
  -o "${OUTPUT_ISO}" \
  -b "${BIOS_IMG}" \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  --grub2-boot-info --grub2-mbr "${HYBRID_MBR}" \
  -eltorito-alt-boot -e "${EFI_IMG}" -no-emul-boot \
  -isohybrid-mbr "${HYBRID_MBR}" \
  -isohybrid-gpt-basdat \
  "${WORK_DIR}"

trap - ERR
sudo rm -rf "${WORK_DIR}"

echo ""
echo "SUCCESS: ${OUTPUT_ISO} created."
ls -lh "${OUTPUT_ISO}"
