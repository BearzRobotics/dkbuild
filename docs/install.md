# Installing FenrirOS by hand

`dkinstaller` (on the base, rescue and dkde live ISOs) does this for you. This
page is the manual way: it is what the installer does step by step, with the
choices the installer does not offer yet (the boot loader, the root file system).
Use it when you want a different layout, when the installer is not on your
medium, or to understand what the installer does.

**This erases the disk you choose.** Check the device name twice (`lsblk`).

## Status of each part

| Part | Status |
|---|---|
| UEFI, GPT, ext4 root, systemd-boot, system unpacked from `fenriros.tar.zst` | done and tested (QEMU) |
| dklilo on BIOS or UEFI (what `dkinstaller` runs) | steps below are the installer's own; the installer is not yet verified end to end on hardware |
| GRUB on BIOS or UEFI | the steps are GRUB's standard ones; not yet run on FenrirOS |
| Copying the live medium's `rootfs.sfs` instead of a tar | the steps are the installer's own; not yet run by hand |
| btrfs or XFS as the root file system | **not available yet**: needs an initramfs for installed systems, or a kernel with them built in (see `docs/initramfs.md`) |

Where a step says "unverified", treat it as the plan and read the result.

## 0. What you need

- A live ISO (`images/base.toml`, `rescue.toml` or `dkde.toml`) written to a USB
  stick or a disc, booted in the firmware mode you want to install for (UEFI or
  BIOS/CSM). Secure Boot off.
- The system to install, either:
  - **a.** `out/fenriros/fenriros.tar.zst`, made on the build machine with
    `dkbuild image images/fenriros.toml` (copy it to a stick or fetch it over the
    network), or
  - **b.** the live medium itself: `/run/live/medium/live/rootfs.sfs`, the live
    system's file system image. This is what `dkinstaller` copies.
- The tools the live ISOs carry (`rescue-tools`): `sgdisk` or `sfdisk`, `mkfs.*`,
  `unsquashfs`, `blkid`, `chroot`, and a boot loader (`dklilo` on all of them;
  `grub` on the rescue ISO).

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

**btrfs and XFS** are modules in the current kernel, so a root on them cannot
mount without an initramfs, and installed systems do not have one yet. The plan
is in `docs/initramfs.md`. Until then, use ext4 for `/` and put btrfs or XFS on
other mounts (`/home`, `/data`), which can be mounted after boot (`modprobe
btrfs` happens automatically on first mount).

When it is available, a btrfs root will look like this (unverified; it needs the
initramfs and `rootflags=` on the kernel command line):

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
`/etc/passwd`) and create your own.

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
ls /boot                     # note the kernel name: vmlinuz-<version>-dkrescue
```

## 6. Install the boot loader

Pick one.

### 6a. dklilo (BIOS or UEFI)

`/boot/dklilo.conf` (this is what the installer writes; `root=` is the root
partition's PARTUUID, from `blkid -s PARTUUID -o value "$ROOT"`):

```
timeout = 50
default = fenriros

image = /boot/vmlinuz-<version>-dkrescue
    label = fenriros
    root = PARTUUID=<partuuid>
    append = "ro quiet"

image = /boot/vmlinuz-<version>-dkrescue
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
does not recognise. After a kernel update, edit the `image =` lines by hand (it
needs no re-install, only the new name in the config); there is no kernel hook
for dklilo yet.

### 6b. GRUB (BIOS or UEFI)

If the platform packages are not installed yet: `apk add grub grub-i386-pc`
(BIOS) or `apk add grub grub-x86_64-efi` (UEFI).

```sh
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
gen-systemd-boot                 # entries for the installed kernel(s)
```

Later kernels: installing the `linux` package runs `gen-systemd-boot`, which
rewrites the entries from the kernels in `/boot`. Extra kernel options go in
`/etc/default/systemd-boot` as `SD_BOOT_CMDLINE="..."`.

## 7. Reboot

```sh
exit                             # leave the chroot
umount -R /mnt
reboot
```

Log in on the console, then start the desktop with `dkde-session` (the default
desktop), or `Hyprland`. This image has no greetd; the dkde live ISO logs in
through greetd by itself.

## Packages after installing

There is no repository server; packages come on a **repository ISO** set (all
packages, signed), made with `dkbuild discs images/repo.toml`. Each disc has an
`import.sh` that copies a set into one directory. Mount it, or the USB stick it
is on, and add it:

```sh
mkdir -p /mnt/repo
mount -o ro,loop /path/to/fenriros-repo.iso /mnt/repo   # a file; for a disc or stick: mount -o ro /dev/sr0 /mnt/repo
echo /mnt/repo/apks/x86_64/Packages.adb >> /etc/apk/repositories   # or, on an image made by dkbuild image:
                                                                    # uncomment the #@cdrom line in /etc/apk/repositories
                                                                    # and mount the disc at /mnt/cdrom
apk update && apk add <package>
```

A newer disc and `apk upgrade` bring updates. The packages are signed with the
key in `/etc/apk/keys`, whatever they come from.
