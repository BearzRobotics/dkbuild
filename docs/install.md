# Installing FenrirOS by hand

`dkinstaller` (`sudo dkinstall`, on the base, rescue, dkde, dkde-devel and
hyprland live ISOs) does this for you. This page is the manual way: it follows
what the installer does, step by step, but is not an exact copy of it. Since
0.0.6 the installer also lets you choose the root file system (ext4, ext3, ext2,
btrfs or XFS; XFS not with dklilo) and the boot loader (dklilo, GRUB or
systemd-boot), as far as the live disc has the tools. Use this page when you want
something the installer does not offer, when the installer is not on your
medium, or to understand what the installer does.

**This erases the disk you choose.** Check the device name twice (`lsblk`).

## Status of each part

| Part | Status |
|---|---|
| UEFI, GPT, ext4 root, systemd-boot, system unpacked from `fenriros.tar.zst` | recorded earlier as tested (QEMU). The `root=PARTUUID` setting in 6c was added to this page later and is not tested by hand |
| dklilo on BIOS or UEFI (the installer's default) | steps below follow the installer's; the installer is not yet verified end to end on hardware, and installing to a disk was not tested with the 2026-11-24 `dkde-devel` ISO |
| GRUB on BIOS or UEFI | these steps are not tested by hand. A GRUB built with Clang (r3) installed in QEMU but did not boot; r6 (built with GCC) has no recorded boot test |
| Copying the live medium's `rootfs.sfs` instead of a tar | the steps are the installer's own; not yet run by hand |
| btrfs or XFS as the root file system | built into the kernel from linux r4 and linux-lts r4 (both built); with an older kernel they are modules and need an initramfs (`docs/initramfs.md`). XFS needs a separate `/boot` for dklilo. These steps are not tested |
| ZFS as the root file system | needs the installed-system initramfs with ZFS: not available yet |

Where a step says "unverified", treat it as the plan and read the result.

## 0. What you need

- A live ISO (`images/base.toml`, `rescue.toml`, `dkde.toml` or
  `dkde-devel.toml`) written to a USB stick or a disc, booted in the firmware mode
  you want to install for (UEFI or BIOS/CSM). Secure Boot off. How to log in is
  below.
- The system to install, either:
  - **a.** `out/fenriros/fenriros.tar.zst`, made on the build machine with
    `dkbuild image images/fenriros.toml` (copy it to a stick or fetch it over the
    network), or
  - **b.** the live medium itself: `/run/live/medium/live/rootfs.sfs`, the live
    system's file system image. This is what `dkinstaller` copies.
- The tools. All of these ISOs have `sfdisk`, `blkid`, `mkfs.ext4`, `mkfs.vfat`,
  `unsquashfs`, `zstd`, `chroot` and `dklilo`. The rest differs:

  | Tool | `base` | `rescue` | `dkde` | `dkde-devel` |
  |---|---|---|---|---|
  | `sgdisk` (in `rescue-tools`) | no | yes | no | yes |
  | `mkfs.btrfs`, `mkfs.xfs` | no | yes | yes | yes |
  | `grub` | no | yes, without the platform modules | no | yes, with `grub-i386-pc` (BIOS) only |

  Without `sgdisk`, make the same layout with `sfdisk` or another partitioning
  tool. None of these four has `grub-x86_64-efi` or `systemd-boot`.

### Logging in to the live system

On each of these the live user has no password (press Enter if asked), is in
`wheel`, and uses `sudo` for root (press Enter at its password prompt too). The
images set no root password: root is locked.

| Image | User | How it starts |
|---|---|---|
| `base` | `live` | text console; logged in by itself on tty1 |
| `rescue` | `rescue` | logged in by itself on tty1, which starts the DKDE desktop; tty2-tty6 and serial give a text login |
| `dkde` | `live` | greetd starts the DKDE desktop as `live`; after a logout, the greeter accepts the empty password; text consoles on tty1-tty6, greetd on tty7 |
| `dkde-devel` | `live` | as `dkde` (with elogind instead of seatd); the text consoles say how to log in, and which logs to read if the desktop or login screen did not start: `~/.local/state/dkde/session.log`, `/tmp/dkde-greeter-*.log`, `sudo dinitctl status greetd` |
| `hyprland` | `live` | greetd starts `ml4w-session` (Hyprland) |

This table is what the image files ask for. Of the current live images, only the
`dkde-devel` ISO of 2026-11-24 has a recorded desktop test: in QEMU (BIOS, the
disc's boot loader, standard VGA and virtio) the desktop, the login screen, an
X11 sign-in (the login screen preselects "dkde (X11, dkde-wm)") and polkit
worked. VirtualBox, real hardware, installing to a disk and GRUB were not tested.

## 1. Choose firmware and boot loader

| Firmware | Partition table | Boot loader options |
|---|---|---|
| **UEFI** | GPT with an EFI system partition (ESP) | dklilo, GRUB or systemd-boot |
| **BIOS** | GPT with a 1 MiB BIOS boot partition, or MBR | dklilo or GRUB |

What each one is, and what it can read:

- **dklilo** is FenrirOS's own boot loader (a modern LILO, in Zig). It boots on
  BIOS and UEFI, reads ext2/3/4, btrfs (including subvolumes and zstd) and FAT
  itself at boot, so kernel updates need no re-install. Its config is one small
  file, `/boot/dklilo.conf`. It does **not** read XFS, LUKS or LVM, so `/boot`
  must be ext4, btrfs or FAT. This is what `dkinstaller` uses.
- **GRUB** reads many more file systems (XFS included) and is the familiar
  choice. The `grub` package comes with `update-grub` and a kernel hook that
  rewrites `/boot/grub/grub.cfg` when a kernel is installed. The firmware
  parts are separate packages: `grub-i386-pc` (BIOS), `grub-x86_64-efi`,
  `grub-i386-efi`.
- **systemd-boot** is UEFI only and boots kernels that are on the ESP, so the
  ESP is mounted at `/boot`. The `linux` package runs `gen-systemd-boot` after
  installing a kernel.

## 2. Partition

Examples use `DISK=/dev/sda`. For NVMe the partitions are `${DISK}p1` and so on.

### UEFI, GPT

```sh
DISK=/dev/sda
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1G -t1:ef00 -c1:EFI  "$DISK"
sgdisk -n2:0:0   -t2:8304 -c2:root "$DISK"      # 8304 = Linux x86-64 root
mkfs.vfat -F32 -n EFI "${DISK}1"
```

The ESP is 1 GiB here because with systemd-boot it also holds the kernels
(`/boot`). With dklilo or GRUB it can be 512 MiB (`dkinstaller` uses 512 MiB, at
`/boot/efi`).

### BIOS, GPT

```sh
DISK=/dev/sda
sgdisk --zap-all "$DISK"
sgdisk -n1:2048:+1M -t1:ef02 -c1:BIOSboot "$DISK"   # no file system on this one
sgdisk -n2:0:0      -t2:8304 -c2:root     "$DISK"
```

The 1 MiB BIOS boot partition at sector 2048 is where the loader's second stage
lives (both dklilo and GRUB use it).

### BIOS, MBR

```sh
DISK=/dev/sda
sfdisk "$DISK" <<EOF
label: dos
start=2048, type=83, bootable
EOF
```

Leave the gap before sector 2048 empty (the loader is written there). dklilo
refuses to install if that gap is not free.

## 3. Root file system

```sh
ROOT=${DISK}2                       # ${DISK}p2 on NVMe; ${DISK}1 on an MBR disk
mkfs.ext4 -L fenriros "$ROOT"
```

**ext4** is the root that works today, because the kernel has ext4, NVMe, SATA
(AHCI), USB storage and virtio built in, so it boots with no initramfs.

**btrfs and XFS** are built into the kernel from linux r4 (and linux-lts r4), so
a single-disk root on either boots with no initramfs, like ext4. On a kernel from
before that they are modules and cannot be the root: check
`grep -E 'CONFIG_(BTRFS|XFS)_FS=' /boot/config-*` (`=y` is built in). Multi-device
btrfs, LUKS, LVM, RAID and ZFS roots need the initramfs in `docs/initramfs.md`.

**XFS** is a special case for the boot loader: **dklilo cannot read XFS**, so with
an XFS root `/boot` must be a separate partition (ext4 or FAT, 1 GiB) that holds
the kernel; GRUB can read XFS. Tools for each file system on the live disc:
ext2/3/4 `mkfs.ext{2,3,4}` (e2fsprogs), btrfs `mkfs.btrfs` (btrfs-progs), XFS
`mkfs.xfs` (xfsprogs), FAT (the ESP) `mkfs.vfat` (dosfstools).

A btrfs root with subvolumes looks like this (unverified on FenrirOS):

```sh
mkfs.btrfs -L fenriros "$ROOT"
mount "$ROOT" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@,compress=zstd,noatime "$ROOT" /mnt
```

## 4. Copy the system in

```sh
mount "$ROOT" /mnt            # or the mount line above for btrfs
mkdir -p /mnt/boot
```

Mount the ESP where your boot loader wants it:

```sh
mount "${DISK}1" /mnt/boot        # systemd-boot: the ESP is /boot
# or, for dklilo or GRUB on UEFI:
mkdir -p /mnt/boot/efi && mount "${DISK}1" /mnt/boot/efi
```

Then either **a. from the tar** (the image `dkbuild image` made):

```sh
zstd -dc fenriros.tar.zst | tar -C /mnt --numeric-owner -xpf -
```

tar may warn that it cannot set owners or permissions on files on the ESP: FAT
has neither. That is expected.

or **b. from the live medium** (what `dkinstaller` does):

```sh
unsquashfs -f -d /mnt /run/live/medium/live/rootfs.sfs
```

This copies the *live* system, so it has the live user and live settings that
the tar does not. After the chroot step below, remove the live user
(`userdel -r <name>`, the first login with uid 1000 or more; check
`/etc/passwd`) and create your own (`useradd -m -G wheel,video,render
-s /bin/bash <name>`). Also remove the live login settings, whichever are there:

- `--autologin <name>` on the `command =` line of `/etc/dinit.d/tty1`;
- the `[initial_session]` block at the end of `/etc/greetd/config.toml`;
- ` nullok` on the `auth` line of `/etc/pam.d/greetd`;
- the live login text in `/etc/issue`;
- on `rescue`, check `/etc/skel/.profile` (copied into new users' homes): its
  last lines start the desktop on tty1.

## 5. Configure, inside the new system

```sh
cat >> /mnt/etc/fstab <<EOF
UUID=$(blkid -s UUID -o value "$ROOT")   /      ext4   defaults    1 1
EOF
# with an ESP mounted at /boot or /boot/efi, one more line:
echo "UUID=$(blkid -s UUID -o value ${DISK}1)  /boot/efi  vfat  umask=0077  0 2" >> /mnt/etc/fstab
#   (use /boot instead of /boot/efi for systemd-boot)

for d in dev proc sys run; do mount --rbind /$d /mnt/$d; done
mount --rbind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars 2>/dev/null   # UEFI only
chroot /mnt /bin/sh -l
```

(The live ISO's fstab and the image's `fstab` are not reused: write your own as
above. If you used the live medium's `rootfs.sfs`, check that `/etc/fstab` has
no live-only lines.)

In the chroot:

```sh
passwd <user>                # the image's user starts locked; root stays locked
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime     # your zone
ls /boot                     # note the kernel name: vmlinuz-<series>-FenrirOS (for example 7.3)
```

## 6. Install the boot loader

Pick one.

Installed systems have no initramfs, so the kernel finds its root only by
`root=/dev/...` or `root=PARTUUID=...`, not `root=UUID=...`. Get the root
partition's PARTUUID with `blkid -s PARTUUID -o value <root partition>` (outside
the chroot, where `$ROOT` is set).

The `fenriros` image has `systemd-boot` but neither `dklilo` nor `grub`: for 6a
or 6b on it, add the package first (see "Packages after installing").

### 6a. dklilo (BIOS or UEFI)

`/boot/dklilo.conf` (modelled on what the installer writes, which names its
entries `dkrescue` and `dkrescue-safe`; `root=` is the root partition's
PARTUUID):

```
timeout = 50
default = fenriros

image = /boot/vmlinuz-<series>-FenrirOS
    label = fenriros
    root = PARTUUID=<partuuid>
    append = "ro quiet"

image = /boot/vmlinuz-<series>-FenrirOS
    label = fenriros-safe
    root = PARTUUID=<partuuid>
    append = "ro nomodeset"
```

Then:

```sh
dklilo check /boot/dklilo.conf
dklilo install-bios --yes "$DISK"                  # BIOS
dklilo install-uefi --yes /boot/efi                # UEFI, ESP mounted at /boot/efi
dklilo install-uefi --yes --removable /boot/efi    # if the firmware's boot list is not writable
                                                   # (efivars), or as a fallback loader
```

dklilo shows every write first and refuses to overwrite a boot loader or data it
does not recognise. A kernel update within the same series keeps the file name.
When the name changes (a new series), edit the `image =` lines by hand (dklilo
needs no re-install, only the new name in the config); there is no kernel hook
for dklilo yet.

### 6b. GRUB (BIOS or UEFI)

If the platform packages are not installed yet: `apk add grub grub-i386-pc`
(BIOS) or `apk add grub grub-x86_64-efi` (UEFI).

```sh
# no initramfs: boot by PARTUUID (the installer writes the same two settings)
mkdir -p /etc/default/grub.d
printf 'GRUB_DISABLE_LINUX_UUID=true\nGRUB_DISABLE_LINUX_PARTUUID=false\n' \
    > /etc/default/grub.d/50-partuuid.cfg

# BIOS (GPT with the BIOS boot partition, or MBR):
grub-install --target=i386-pc "$DISK"

# UEFI (ESP at /boot/efi):
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=FenrirOS
#   add --removable if the firmware's boot list is not writable

update-grub          # writes /boot/grub/grub.cfg
```

After this, installing or upgrading a kernel re-runs `update-grub` through the
kernel hook (`/usr/lib/kernel.d/99-grub.sh`, which only acts when `/boot/grub`
exists). Kernel options go in `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`.

### 6c. systemd-boot (UEFI only; the ESP is mounted at /boot)

```sh
bootctl install                  # systemd-boot onto the ESP, and a UEFI boot entry
# gen-systemd-boot writes root=UUID=..., which needs an initramfs; the last root= wins
echo 'SD_BOOT_CMDLINE="root=PARTUUID=<partuuid>"' > /etc/default/systemd-boot
gen-systemd-boot                 # entries for the installed kernel(s)
```

Later kernels: installing the `linux` package runs `gen-systemd-boot`, which
rewrites the entries from the kernels in `/boot`. Extra kernel options go in
`SD_BOOT_CMDLINE="..."` in `/etc/default/systemd-boot`, after the `root=`.

## 7. Reboot

```sh
exit                             # leave the chroot
umount -R /mnt
reboot
```

For a system from the `fenriros` tar: log in on the console, then start the
desktop with `dkde-session` (the default desktop), or `Hyprland`. greetd is
installed (it comes with the desktop) but the image does not enable its service.
A system copied from a live medium keeps that medium's services.

## Packages after installing

There is no repository server; packages come on a **repository ISO** set (all
packages, signed), made with `dkbuild discs images/repo.toml`. Each disc has an
`import.sh` that copies a set into one directory. Mount it, or the USB stick it
is on, and add it. On a disc or a one-disc image the repository is under
`data/apks/`; in a directory filled by `import.sh` it is under `apks/`:

```sh
mkdir -p /mnt/repo
mount -o ro,loop /path/to/fenriros-repo.iso /mnt/repo   # a file; for a disc or stick: mount -o ro /dev/sr0 /mnt/repo
echo /mnt/repo/data/apks/x86_64/Packages.adb >> /etc/apk/repositories
apk update && apk add <package>
```

An image made by `dkbuild image` has a commented-out `#@cdrom` line in
`/etc/apk/repositories`. To use it, mount the disc at `/mnt/cdrom`, uncomment
it and check its path (a disc needs `/mnt/cdrom/data/apks/x86_64/Packages.adb`;
the line as written has no `data/`). With the `@cdrom` tag, packages are added as
`apk add <package>@cdrom`.

A newer disc and `apk upgrade` bring updates. The packages are signed with the
key in `/etc/apk/keys`, whatever they come from.
