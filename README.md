# Alpine ZFS Auto-Installer (UEFI + Encrypted ZFS Root)

This repo provides a single script to install Alpine Linux onto a single disk using:

- UEFI boot with ZFSBootMenu
- ~1 GiB EFI System Partition
- Encrypted ZFS root (native ZFS encryption, AES-256-GCM)
- zstd-19 compression (forced)
- Reasonable ZFS defaults (ashift=12, autotrim=on, xattr=sa, acltype=posixacl, atime=off)

It creates a boot environment `zroot/ROOT/alpine` and uses a prebuilt ZFSBootMenu UEFI binary.

> WARNING: This will wipe the target disk completely.

## Requirements

- Boot the Alpine extended ISO (UEFI) and login as root
- Secure Boot must be disabled
- Internet access (to install packages and download ZFSBootMenu EFI)

## What gets installed

- Disk layout: GPT with
  - Partition 1: EFI System Partition (FAT32, ~1024 MiB)
  - Partition 2: ZFS for the rest of the disk
- ZFS pool: `zroot` with native encryption (passphrase prompt at boot)
- Bootloader: ZFSBootMenu installed to the EFI System Partition and registered via `efibootmgr`
- Alpine base system with `linux-lts`, ZFS userspace, and initramfs including ZFS support
- OpenRC services: `zfs-import`, `zfs-load-key`, `zfs-mount` enabled

## Usage

From the live ISO shell:

```fish

Install packages:
apk add curl lsblk dhcpcd

# FIRST: Configure networking (required for downloads and package installation)

setup-interfaces -r
udhcpc -i "NAME OF YOUR INTEFRACE"
 # At this point notebook connects to internet with wifi.

If network works - skip to install.

ip link set <interface> up

udhcpc -i "NAME OF YOUR INTEFRACE"


echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Get the script onto the ISO (choose one method):

# Method 1: Download directly (requires internet setup above)
apk add curl
curl -LO https://raw.githubusercontent.com/master-of-zen/alpine-autoinstall/refs/heads/main/alpine-zfs-installer.sh


# Method 2: Copy from USB/network share
# Mount your USB drive or network share containing the script, then:
# mount /dev/sdb1 /mnt
# cp /mnt/alpine-zfs-installer.sh /root/
# chmod +x /root/alpine-zfs-installer.sh

# Method 3: Paste the script manually
# vi alpine-zfs-installer.sh
# (paste content, save)
# chmod +x alpine-zfs-installer.sh

# List disks to identify your target
lsblk -o NAME,SIZE,TYPE,MODEL

# Run the installer (DESTROYS the disk)
./alpine-zfs-installer.sh -d /dev/nvme0n1 -H myhost
```

Options:

- `-d, --disk`: target disk (required)
- `-H, --hostname`: set hostname (default: alpine)
- `-p, --root-password`: set root password (optional)
- `-k, --ssh-pubkey`: path to a public key to add to `/root/.ssh/authorized_keys`
- `--pool-name`: change zpool name (default: zroot)
- `--efi-size-mib`: EFI partition size in MiB (default: 1024)
- `--kernel`: kernel flavor `lts|virt` (default: lts)
- `--non-interactive`: skip confirmation prompt (still prompts for ZFS passphrase)
- `--no-by-id`: do not resolve disk to `/dev/disk/by-id` path

The script will prompt for your ZFS passphrase while creating the pool.

When done, it exports the pool; reboot and choose the "ZFSBootMenu" entry in your firmware boot menu.

## Notes

- Compression: `zstd-19` is quite CPU-intensive. If you prefer lighter compression, change `ZFS_COMPRESSION`.
- Keys: The pool uses `keylocation=prompt`, so ZFSBootMenu will ask for your passphrase at boot.
- EFI mount: The target system will mount the ESP at `/efi` (configured in `/etc/fstab`).
- Boot environments: You can snapshot and clone `zroot/ROOT/alpine` to create new environments; ZFSBootMenu will discover them.

## Troubleshooting

- If you see "no kernels found" in ZFSBootMenu, ensure `/boot` in your root dataset contains `vmlinuz-lts` and `initramfs-lts` (mkinitfs step).
- If ZFS isn’t included in initramfs, re-run inside the installed system:

```sh
echo 'features="base keymap kms nvme scsi virtio zfs"' | tee /etc/mkinitfs/mkinitfs.conf
mkinitfs -c /etc/mkinitfs/mkinitfs.conf $(ls /lib/modules)
```

- If UEFI boot entry didn’t register, boot from firmware’s file browser and select: `EFI/ZBM/ZFSBootMenu.EFI`, then add a permanent entry from within firmware setup.

## Security

- Encryption uses native ZFS (`aes-256-gcm`, `keyformat=passphrase`, `keylocation=prompt`). You’ll be prompted at boot.
- Keep backups of critical data and consider enabling periodic `zpool scrub` and `autotrim`.

## Uninstall / Reinstall

Re-running the script will re-partition and destroy existing data on the target disk.
