#!/bin/sh

set -e

if [ "$1" = start ]; then

    PATH=/usr/bin:/usr/sbin:/bin:/sbin

    # Must have sysfs mounted for udevtrigger to function.
    mount -n -t sysfs -o nosuid,nodev,noexec sysfs /sys

    # UEFI variables, for efibootmgr. Absent on BIOS machines.
    if [ -d /sys/firmware/efi/efivars ]; then
        mount -n -t efivarfs -o nosuid,nodev,noexec efivarfs /sys/firmware/efi/efivars
    fi
    
    # Ideally devtmpfs will be mounted by kernel, we can mount here anyway:
    mount -n -t devtmpfs tmpfs /dev
    mkdir -p /dev/pts /dev/shm
    mount -n -t tmpfs -o nodev,nosuid tmpfs /dev/shm
    mount -n -t devpts -o gid=5 devpts /dev/pts

    # /run, and various directories within it
    # A live system already has /run, moved in by the initramfs with /run/live
    # (the disc) in it: mounting another would hide that.
    mountpoint -q /run || mount -n -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run
    mkdir /run/lock /run/udev
    
    # /proc without hidepid: polkitd runs as its own user and reads /proc/<pid> of the process asking for an action; with
    # hidepid=1 every check failed ("Failed to open file /proc/<pid>/status: Operation not permitted")
    mount -n -t proc -o nosuid,nodev,noexec proc /proc



fi
