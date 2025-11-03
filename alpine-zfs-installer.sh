#!/bin/sh
# Alpine Linux automated installer: UEFI + ZFS (encrypted) root using ZFSBootMenu
# WARNING: This will DESTROY all data on the target disk.
# Tested with Alpine extended ISO and OpenZFS 2.x. Secure Boot must be disabled.

set -eu

# Defaults
POOL_NAME=${POOL_NAME:-zroot}
ROOT_BE_NAME=${ROOT_BE_NAME:-alpine}
EFI_LABEL=${EFI_LABEL:-EFI}
EFI_SIZE_MIB=${EFI_SIZE_MIB:-1024}
HOSTNAME=${HOSTNAME:-alpine}
TIMEZONE=${TIMEZONE:-UTC}
KERNEL_FLAVOR=${KERNEL_FLAVOR:-lts}
ZFS_COMPRESSION=${ZFS_COMPRESSION:-zstd-19}
ZFS_ENC_ALGO=${ZFS_ENC_ALGO:-aes-256-gcm}
ZFS_KEYFORMAT=${ZFS_KEYFORMAT:-passphrase}
ZFS_KEYLOCATION=${ZFS_KEYLOCATION:-prompt}
ZBM_EFI_URL=${ZBM_EFI_URL:-https://get.zfsbootmenu.org/efi}
ZBM_EFI_PATH=${ZBM_EFI_PATH:-\\EFI\\ZBM\\ZFSBootMenu.EFI}
TARGET_DISK=${TARGET_DISK:-}
USE_BY_ID=${USE_BY_ID:-1}
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
ROOT_PASSWORD=${ROOT_PASSWORD:-}
SSH_PUBKEY_FILE=${SSH_PUBKEY_FILE:-}

usage() {
  cat <<EOF
Usage: $0 -d <disk> [options]

Required:
  -d, --disk             Target disk device (e.g., /dev/nvme0n1)

Optional:
  -H, --hostname         System hostname (default: ${HOSTNAME})
  -p, --root-password    Root password (if empty, you'll set it later)
  -k, --ssh-pubkey       Path to SSH public key to add to /root/.ssh/authorized_keys
  --pool-name            ZFS pool name (default: ${POOL_NAME})
  --efi-size-mib         EFI System Partition size in MiB (default: ${EFI_SIZE_MIB})
  --kernel               Kernel flavor: lts|virt (default: ${KERNEL_FLAVOR})
  --non-interactive      Do not prompt except ZFS passphrase (default: ${NON_INTERACTIVE})
  --no-by-id             Use direct disk path instead of /dev/disk/by-id

Behavior:
  - Creates GPT with ~${EFI_SIZE_MIB}MiB EFI + rest ZFS
  - Creates encrypted ZFS pool (${ZFS_ENC_ALGO}, keyformat=${ZFS_KEYFORMAT}, keylocation=${ZFS_KEYLOCATION})
  - Sets compression=${ZFS_COMPRESSION}
  - Bootloader: installs ZFSBootMenu prebuilt EFI and registers with efibootmgr
  - Boot environments: creates ${POOL_NAME}/ROOT/${ROOT_BE_NAME}

Example:
  $0 -d /dev/nvme0n1 -H myhost --kernel lts
EOF
}

err() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[INFO] $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing command: $1 (apk add $2)"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--disk) TARGET_DISK="$2"; shift 2;;
      -H|--hostname) HOSTNAME="$2"; shift 2;;
      -p|--root-password) ROOT_PASSWORD="$2"; shift 2;;
      -k|--ssh-pubkey) SSH_PUBKEY_FILE="$2"; shift 2;;
      --pool-name) POOL_NAME="$2"; shift 2;;
      --efi-size-mib) EFI_SIZE_MIB="$2"; shift 2;;
      --kernel) KERNEL_FLAVOR="$2"; shift 2;;
      --non-interactive) NON_INTERACTIVE=1; shift;;
      --no-by-id) USE_BY_ID=0; shift;;
      -h|--help) usage; exit 0;;
      *) err "Unknown arg: $1";;
    esac
  done
  [ -n "$TARGET_DISK" ] || { usage; err "--disk is required"; }
}

confirm_destruction() {
  if [ "$NON_INTERACTIVE" -ne 1 ]; then
    echo "\nThis will WIPE $TARGET_DISK and install Alpine on encrypted ZFS."
    printf "Type 'WIPE' to continue: "
    read ans || true
    [ "$ans" = "WIPE" ] || err "Aborted"
  fi
}

ensure_packages() {
  # Live ISO environment packages
  need_cmd apk apk
  apk update || true
  apk add --no-cache zfs eudev parted util-linux dosfstools curl efibootmgr e2fsprogs sgdisk || apk add --no-cache zfs eudev parted util-linux dosfstools curl efibootmgr e2fsprogs gdisk
  modprobe zfs || true
  mdev -s || true
}

by_id_path() {
  disk="$1"
  if [ "$USE_BY_ID" -eq 1 ] && [ -d /dev/disk/by-id ]; then
    for id in /dev/disk/by-id/*; do
      [ "$(readlink -f "$id")" = "$disk" ] && { echo "$id"; return; }
    done
  fi
  echo "$disk"
}

partition_disk() {
  disk="$1"
  log "Partitioning $disk (EFI ${EFI_SIZE_MIB}MiB + ZFS)"
  # Zap and create GPT
  sgdisk --zap-all "$disk" || true
  partprobe "$disk" || true
  # Create partitions: 1MiB alignment
  # 1: EFI from 1MiB to (1MiB + EFI_SIZE_MIB)
  # 2: ZFS rest
  sgdisk -n1:1MiB:+${EFI_SIZE_MIB}MiB -t1:EF00 -c1:"EFI System" "$disk"
  sgdisk -n2:0:0 -t2:BF01 -c2:"ZFS" "$disk"
  partprobe "$disk"
}

part_path() {
  # Return partition device path for N-th partition on given disk
  disk="$1"; partnum="$2"
  if printf %s "$disk" | grep -q '^/dev/disk/'; then
    # by-id/by-path style
    echo "${disk}-part${partnum}"
  else
    case "$disk" in
      *nvme*|*mmcblk*) echo "${disk}p${partnum}";;
      *) echo "${disk}${partnum}";;
    esac
  fi
}

format_esp() {
  esp_dev="$1"
  log "Formatting EFI System Partition on $esp_dev"
  mkfs.vfat -F32 -n "$EFI_LABEL" "$esp_dev"
}

create_pool() {
  zdev="$1"
  log "Creating encrypted ZFS pool $POOL_NAME on $zdev"
  # Prompt for passphrase interactively
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O xattr=sa \
    -O atime=off \
    -O relatime=on \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=none \
    -O compression="${ZFS_COMPRESSION}" \
    -O encryption="${ZFS_ENC_ALGO}" \
    -O keyformat="${ZFS_KEYFORMAT}" \
    -O keylocation="${ZFS_KEYLOCATION}" \
    -R /mnt \
    "$POOL_NAME" "$zdev"
}

create_datasets() {
  log "Creating datasets"
  zfs create -o mountpoint=none "$POOL_NAME/ROOT"
  zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/ROOT/$ROOT_BE_NAME"
  zfs mount "$POOL_NAME/ROOT/$ROOT_BE_NAME"
  # Common layout
  zfs create -o mountpoint=/home "$POOL_NAME/home"
  zfs create -o mountpoint=/var "$POOL_NAME/var"
  zfs create -o mountpoint=/var/log "$POOL_NAME/var/log"
  zfs create -o mountpoint=/var/tmp -o setuid=off "$POOL_NAME/var/tmp"
  zfs create -o mountpoint=/tmp -o devices=off -o setuid=off "$POOL_NAME/tmp"
  chmod 1777 /mnt/tmp
}

bootstrap_alpine() {
  log "Bootstrapping Alpine into /mnt"
  # Mount EFI at /mnt/efi (ZBM docs prefer /efi)
  mkdir -p /mnt/efi
  mount -t vfat -o fmask=0077,dmask=0077,iocharset=iso8859-1 "$ESP_DEV" /mnt/efi

  export BOOTLOADER=none
  need_cmd setup-disk alpine-conf
  # Ensure repos are configured in live env so setup-disk can fetch packages
  if [ ! -s /etc/apk/repositories ]; then
    setup-apkrepos -f || true
  fi
  setup-disk -k "$KERNEL_FLAVOR" -v /mnt

  # Install ZFS into target
  cp -f /etc/apk/repositories /mnt/etc/apk/repositories || true
  chroot /mnt apk update || true
  chroot /mnt apk add --no-cache zfs zfs-$KERNEL_FLAVOR eudev

  # Enable ZFS services
  chroot /mnt rc-update add zfs-import boot || true
  chroot /mnt rc-update add zfs-load-key boot || true
  chroot /mnt rc-update add zfs-mount boot || true
}

configure_system() {
  log "Configuring system"
  # Hostname
  echo "$HOSTNAME" > /mnt/etc/hostname

  # mkinitfs with zfs feature
  mkdir -p /mnt/etc/mkinitfs
  if grep -q '^features=' /mnt/etc/mkinitfs/mkinitfs.conf 2>/dev/null; then
    sed -i 's/^features=.*/features="base keymap kms nvme scsi virtio zfs"/' /mnt/etc/mkinitfs/mkinitfs.conf
  else
    echo 'features="base keymap kms nvme scsi virtio zfs"' >> /mnt/etc/mkinitfs/mkinitfs.conf
  fi
  chroot /mnt /bin/sh -lc 'mkinitfs -c /etc/mkinitfs/mkinitfs.conf $(ls /lib/modules | head -n1)'

  # fstab: mount EFI at /efi
  PARTUUID=$(blkid -s PARTUUID -o value "$ESP_DEV")
  mkdir -p /mnt/efi
  if ! grep -q '/efi' /mnt/etc/fstab 2>/dev/null; then
    printf 'PARTUUID=%s /efi vfat noatime,fmask=0077,dmask=0077,iocharset=iso8859-1 0 2\n' "$PARTUUID" >> /mnt/etc/fstab
  fi

  # Root password / SSH key
  if [ -n "$ROOT_PASSWORD" ]; then
    chroot /mnt /bin/sh -lc "echo root:'$ROOT_PASSWORD' | chpasswd"
  fi
  if [ -n "$SSH_PUBKEY_FILE" ] && [ -f "$SSH_PUBKEY_FILE" ]; then
    mkdir -p /mnt/root/.ssh
    cat "$SSH_PUBKEY_FILE" >> /mnt/root/.ssh/authorized_keys
    chmod 600 /mnt/root/.ssh/authorized_keys
    chmod 700 /mnt/root/.ssh
  fi
}

install_zbm() {
  log "Installing ZFSBootMenu EFI"
  mkdir -p /mnt/efi/EFI/ZBM
  curl -L "$ZBM_EFI_URL" -o /mnt/efi/EFI/ZBM/ZFSBootMenu.EFI
  sync
  # Register UEFI boot entry
  need_cmd efibootmgr efibootmgr
  # Ensure UEFI variables are available
  if [ -d /sys/firmware/efi/efivars ]; then
    mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
  fi
  if [ ! -d /sys/firmware/efi ]; then
    log "WARNING: System not booted in UEFI mode; efibootmgr may fail."
  fi
  # Determine partition number of ESP
  ESP_NUM=$(lsblk -no PARTN "$ESP_DEV" | head -n1)
  [ -n "$ESP_NUM" ] || err "Failed to determine EFI partition number for $ESP_DEV"
  efibootmgr -c -d "$BASE_DISK" -p "$ESP_NUM" -L "ZFSBootMenu" -l "$ZBM_EFI_PATH"

  # ZBM kernel command line property (optional)
  zfs set org.zfsbootmenu:commandline="quiet loglevel=3" "$POOL_NAME/ROOT/$ROOT_BE_NAME" || true
}

finalize() {
  log "Setting pool bootfs and unmounting"
  zpool set bootfs="$POOL_NAME/ROOT/$ROOT_BE_NAME" "$POOL_NAME"
  umount -Rl /mnt || true
  zpool export "$POOL_NAME"
  log "Done. You can now reboot into ZFSBootMenu."
}

main() {
  [ "$(id -u)" -eq 0 ] || err "Run as root"
  parse_args "$@"
  confirm_destruction
  ensure_packages

  BASE_DISK=$(by_id_path "$TARGET_DISK")
  partition_disk "$BASE_DISK"

  ESP_DEV=$(part_path "$BASE_DISK" 1)
  ZFS_DEV=$(part_path "$BASE_DISK" 2)

  format_esp "$ESP_DEV"
  create_pool "$ZFS_DEV"
  create_datasets
  bootstrap_alpine
  configure_system
  install_zbm
  finalize

  log "Installation complete."
}

main "$@"
