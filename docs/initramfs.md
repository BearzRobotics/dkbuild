# The initramfs for installed systems

Status: **design, not implemented** (2026-11-20). btrfs and XFS are built into the kernel from linux r4 / linux-lts r4 (decided 2026-11-20; takes effect with the next kernel build), so a single-disk btrfs or XFS root already boots without it; the initramfs is for what has to be assembled first. The live ISOs already have an
initramfs (`live-initramfs`); installed systems have none, and boot because the
kernel has ext4, NVMe, SATA (AHCI), USB storage and virtio built in.

## Why

The kernel's file system and storage drivers are a mix of built in (`=y`) and
modules (`=m`). In the current config (`packages/l/linux/files/config`):

| Built in | Modules |
|---|---|
| ext4, vfat, exFAT, NTFS3, ISO 9660, squashfs, overlayfs, UDF | **btrfs, XFS, f2fs** |
| device-mapper core, MD core | **dm-crypt**, dm-thin, **MD RAID1/4/5/6** |
| NVMe, AHCI, USB storage, virtio-blk, loop | |
| AES, XTS, zstd initramfs decompression, CPU microcode support | the kernel crypto user API |

A root file system on a module cannot be mounted by the kernel before init runs,
so btrfs, XFS, f2fs, LUKS, LVM and RAID roots need an initramfs that loads the
module, assembles the devices and mounts the root. The kernel also cannot turn
`root=UUID=...` or `root=LABEL=...` into a device without help (only
`root=/dev/...` and `root=PARTUUID=...` work), which an initramfs fixes too.

## Two ways, and we want both

1. **Built in** (done in linux r4 and linux-lts r4: `CONFIG_BTRFS_FS=y`, `CONFIG_XFS_FS=y`, with XFS quota and POSIX ACL;
   a few hundred kilobytes each). A single-disk btrfs or XFS root then boots with no
   initramfs, like ext4 does today. Cheap, and the simple case stays simple.
   Costs a kernel rebuild (it can wait for the next world run).
2. **An initramfs for installed systems**, for everything that has to be
   assembled first (LUKS, LVM, RAID, multi-device btrfs), for `root=UUID=` and
   `root=LABEL=`, and so for dklilo's `root=PARTUUID=` too.

## Design

- **Generated on the target, at kernel install.** A kernel hook
  (`/usr/lib/kernel.d/NN-initramfs.sh`, the mechanism `99-grub.sh` already uses)
  runs a generator (`dkinitramfs`, a POSIX shell script on BusyBox) that writes
  `/boot/initrd.img-<version>`. That name is already what `gen-systemd-boot`
  looks for (it adds an `initrd` line when the file exists) and what GRUB's
  `grub-mkconfig` finds. dklilo needs an `initrd =` line in its config.
- **What goes in:** a static BusyBox, the modules the system needs and their
  dependencies (`modules.dep`), and static helper programs; no shared libraries
  from the root. Compressed with zstd (the kernel already has `RD_ZSTD`).
- **Two modes:** *host-only* (default: reads `/etc/fstab`, `/etc/crypttab` and the
  devices under `/`, and includes only the modules those need; small) and
  *generic* (every storage and file system module; for moving the disk to
  another machine, and for the rescue image).
- **Deterministic output:** files added in sorted order, timestamps set from
  `SOURCE_DATE_EPOCH`, so the same inputs give the same image.
- **Kernel command line:** `root=` (`/dev/...`, `UUID=`, `LABEL=`, `PARTUUID=`),
  `rootfstype=`, `rootflags=` (`subvol=@` for btrfs), `ro`/`rw`, `init=`,
  `resume=`, `rd.break=<stage>`, `rd.shell`, `rd.luks.uuid=` / `rd.luks.name=`,
  `rd.lvm`, `rd.md`.
- **Hooks:** `pre-mount` and `post-mount` directories in the image, so a feature
  is a small script plus the tools it needs, and a missing tool is a build error
  of the image, not a boot failure.
- **When it fails:** drop to a shell (BusyBox `sh` on the console) with the
  reason printed, never a silent hang.

## What to expand it with, in priority order

1. **btrfs, XFS and f2fs roots**, with `root=UUID=` / `LABEL=`, btrfs
   `rootflags=subvol=@`, and `btrfs device scan` for multi-device btrfs. Needs the
   modules and `btrfs` (from btrfs-progs) built static.
2. **LUKS (dm-crypt) root.** The most asked for after btrfs. Needs
   `cryptsetup` static (with its argon2 and the AES/XTS already in the kernel),
   a passphrase prompt on the console (so the console keymap must be in the
   image), and `/etc/crypttab`. Note dklilo cannot read an encrypted `/boot`, so
   `/boot` stays unencrypted, or use GRUB.
3. **Early CPU microcode.** An uncompressed cpio with the Intel or AMD microcode
   prepended to the initramfs (the kernel has `CONFIG_MICROCODE=y`); the
   microcode comes from the firmware packages.
4. **Resume from hibernation:** `resume=` and, for a swap *file* (btrfs), the
   offset.
5. **LVM (including thin) and mdadm RAID roots.**
6. **fsck before mounting** the root (`e2fsck` for ext4), and the emergency shell
   and `rd.*` debug options above.
7. **Later:** ZFS root (ZFS is prebuilt per kernel flavor in the tree), unlocking
   LUKS with a TPM 2.0 or FIDO2 key, network roots (NFS, iSCSI), and unified
   kernel images (kernel + initramfs + command line in one signed file, which
   systemd-boot boots directly and helps Secure Boot).

## ZFS root

Yes, the initramfs is where a ZFS root belongs: ZFS is not in the kernel (its
licence), so it is an out-of-tree module that is prebuilt per kernel flavor
(the `zfs` packages, for linux-lts only today) and has to be loaded, and the pool
imported, before the root can mount. The initramfs needs:

- the **`zfs` module for exactly that kernel** (and `spl`/dependencies) and the
  `zpool` and `zfs` programs, static or with their libraries copied in;
- a `zfs` hook: parse `root=ZFS=<pool>/<dataset>` (or `root=zfs:<dataset>`), then
  `zpool import -N -d /dev/disk/by-id <pool>` (using `/etc/zfs/zpool.cache` or a
  scan), `zfs load-key` for native encryption (the same passphrase prompt as
  LUKS), mount the dataset, and export or leave imported cleanly;
- **the hostid**: ZFS refuses a pool last used by another host, so `/etc/hostid`
  is copied into the image and must match the installed system's;
- **regeneration** whenever the kernel *or* the `zfs` package is upgraded, because
  the module is tied to the kernel version: the kernel hook runs on a `linux-lts`
  upgrade and a `zfs` package hook runs it again.

Limits: dklilo cannot read ZFS, so `/boot` is a separate partition (ext4 or
FAT); GRUB can read a pool only if it was made with `-o compatibility=grub2`
(and not with newer feature flags). The live disc must run linux-lts with the
module to create the pool. ZFS is therefore the last in the priority list below,
after the pieces it shares with LUKS (prompts, keymap) exist.

## Also needed outside the initramfs

- **The installer** (`dkinstaller`) only made an ext4 root: since 0.0.6 it
  offers ext2/3/4, btrfs and XFS and shows each one's missing tools or reason
  (dkinstaller SPEC 5.3.4); ZFS is listed but unavailable until this initramfs
  exists. Still to do there: a btrfs subvolume layout (`@`, `@home`) with
  `rootflags=subvol=@` in the loader config.
- **dklilo** reads btrfs but not XFS: with an XFS root, `/boot` must be a
  separate ext4 or FAT partition (or use GRUB).
- **The default `/etc/default/grub`** said `GRUB_DISTRIBUTOR="Chimera"` and
  `quiet splash` (copied from Chimera's package); it now says FenrirOS and no
  splash.
- **The live initramfs** stays separate (it only uses the kernel's built-in
  drivers and mounts a squashfs under a RAM overlay); the installed one shares
  BusyBox and the generator's helper scripts with it where that is simple.
