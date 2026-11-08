# Installing FenrirOS on a UEFI machine

There is no installer yet. This is the manual way: boot the DKRescue live ISO on
the target machine, partition the disk, unpack the image `dkbuild image` made,
and install systemd-boot. It takes about ten minutes.

**This erases the disk you choose.** Check the device name twice (`lsblk`).

## 0. What you need

- `out/fenriros/fenriros.tar.zst`, made on the build machine with
  `dkbuild image images/fenriros.toml` (copy it to a USB stick, or fetch it over
  the network from the live system).
- The DKRescue ISO written to a USB stick, and the machine set to boot it in
  **UEFI** mode (not CSM/legacy). Secure Boot off.

## 1. Partition

Two partitions on a GPT disk: an EFI system partition, which is also `/boot`
(the kernel lives there), and the root.

```sh
lsblk                                    # find the disk, e.g. /dev/nvme0n1
DISK=/dev/nvme0n1
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1G -t1:ef00 -c1:EFI "$DISK"
sgdisk -n2:0:0   -t2:8304 -c2:root "$DISK"   # 8304 = Linux x86-64 root
mkfs.vfat -F32 -n EFI "${DISK}p1"
mkfs.ext4 -L fenriros "${DISK}p2"
```

The root is ext4 because the kernel has ext4 and NVMe built in, so it boots
without an initramfs. (btrfs and XFS are modules and would need one; not yet.)

## 2. Unpack

```sh
mount "${DISK}p2" /mnt
mkdir -p /mnt/boot && mount "${DISK}p1" /mnt/boot
zstd -dc fenriros.tar.zst | tar -C /mnt --numeric-owner -xpf -
```

tar may warn that it cannot set owners or permissions on files under `/boot`:
the ESP is FAT, which has neither. That is expected.

## 3. Configure, inside the new system

```sh
cat >> /mnt/etc/fstab <<EOF
UUID=$(blkid -s UUID -o value "${DISK}p2")  /      ext4  defaults    1 1
UUID=$(blkid -s UUID -o value "${DISK}p1")  /boot  vfat  umask=0077  0 2
EOF
for d in dev proc sys sys/firmware/efi/efivars run; do mount --rbind /$d /mnt/$d; done
chroot /mnt /bin/sh -l
```

In the chroot:

```sh
bootctl install                  # systemd-boot onto the ESP, and a UEFI boot entry
gen-systemd-boot                 # entries for the installed kernel(s)
passwd dakota                    # the image's user starts locked
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime   # your zone
exit
```

`root` stays locked; the user is in `wheel`, so `sudo` works.

## 4. Reboot

```sh
umount -R /mnt
reboot
```

systemd-boot shows FenrirOS and a recovery entry. Log in on the console, then
start the desktop with `Hyprland`.

## Packages after installing

Until there is a repository server, packages come on a **repository ISO** (all
packages, signed; planned, SPEC.md 8). Mount it, or the USB stick it is on, and
add it:

```sh
mount -o ro /path/to/fenriros-repo.iso /mnt/repo      # or the stick's partition
echo /mnt/repo/apks/x86_64/Packages.adb >> /etc/apk/repositories
apk update && apk add <package>
```

A newer disc and `apk upgrade` bring updates. The packages are signed with the
key in `/etc/apk/keys`, whatever they come from.

## Later kernels

Installing or upgrading the `linux` package runs `gen-systemd-boot`, which
rewrites the entries from the kernels in `/boot`. Extra kernel options go in
`/etc/default/systemd-boot` as `SD_BOOT_CMDLINE="..."`.
