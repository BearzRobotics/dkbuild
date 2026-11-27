#!/bin/sh

set -e

if [ "$1" = start ]; then

    PATH=/usr/bin:/usr/sbin:/bin:/sbin

    # Each is mounted only if nothing is there yet: the kernel mounts /dev itself on a system without an initramfs
    # (CONFIG_DEVTMPFS_MOUNT), and a live system's initramfs moves its /proc, /sys, /dev and /run over. Mounting
    # again stacks a second one on top, hiding what is below. The source names are /etc/fstab's, so that the later
    # `mount -a` (filesystems.sh) sees these as mounted: it compares source and mount point.
    once() { # once TYPE OPTIONS SOURCE TARGET
        mountpoint -q "$4" || mount -n -t "$1" -o "$2" "$3" "$4"
    }

    # /proc first: mountpoint(1) reads the list of mounts from it. Without hidepid: polkitd runs as its own user and
    # reads /proc/<pid> of the process asking for an action; with hidepid=1 every check failed ("Failed to open file
    # /proc/<pid>/status: Operation not permitted")
    once proc nosuid,nodev,noexec proc /proc

    # Must have sysfs mounted for udevtrigger to function.
    once sysfs nosuid,nodev,noexec sysfs /sys

    # UEFI variables, for efibootmgr. Absent on BIOS machines.
    if [ -d /sys/firmware/efi/efivars ]; then
        once efivarfs nosuid,nodev,noexec efivarfs /sys/firmware/efi/efivars
    fi

    once devtmpfs mode=0755,nosuid devtmpfs /dev
    mkdir -p /dev/pts /dev/shm
    once tmpfs nodev,nosuid tmpfs /dev/shm
    once devpts gid=5,mode=620 devpts /dev/pts

    # /run, and various directories within it
    # A live system already has /run, moved in by the initramfs with /run/live
    # (the disc) in it: mounting another would hide that.
    once tmpfs mode=0755,nosuid,nodev tmpfs /run
    mkdir -p /run/lock /run/udev

fi
