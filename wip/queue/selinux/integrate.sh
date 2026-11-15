#!/bin/sh
# Turns SELinux on in the packages of the main tree that can use it: run it once, in the repository
# root, when the SELinux packages (packages/{libselinux,policycoreutils,selinux-policy-targeted...}) have built
# and a QEMU boot has been tried. Not run yet (2026-11-15): every package it touches gets a release bump
# and is rebuilt, and a mistake in a PAM stack locks users out (docs/pam-qemu-test.md: run tests/qemu-pam.sh
# after it, on an image made with the new packages).
#
#   wip/queue/selinux/integrate.sh [ROOT]        (ROOT: the repository, default the current directory)
#
# What it does:
#  - linux-pam: -Dselinux=enabled (pam_selinux), libselinux-devel
#  - linux-pam-base: system-login opens and closes the SELinux session (`pam_selinux.so close` first and `open`
#    after pam_keyinit, as Red Hat's login stack orders them; harmless when SELinux is off)
#  - shadow (login, su ...), openssh (sshd), cronie, sudo: built with SELinux (libselinux, shadow also libsemanage)
#  - NetworkManager: -Dselinux=true
#  - coreutils, findutils, tar, util-linux: libselinux-devel is added to builddeps (their configure scripts use it
#    when it is found: ls -Z, cp -a, install -Z, find -context, tar --selinux, mount, login labels) and
#    `ls -Z` is checked after the build
#  - every package it changes: release + 1
# The kernels already have SELinux built in (CONFIG_SECURITY_SELINUX=y, LSM list with selinux, default
# SELinux); the live squashfs has no xattrs (CONFIG_SQUASHFS_XATTR is not set: labels cannot be stored on it;
# an installed system on ext4/btrfs/xfs can).
set -eu
root=${1:-.}
cd "$root"

recipe() { printf '%s\n' "$(ls packages/*/"$1"/package.toml)"; }

# release N -> N+1 in a recipe
bump() {
    f=$1
    n=$(sed -n 's/^release = \([0-9][0-9]*\)$/\1/p' "$f")
    [ -n "$n" ] || { echo "integrate: no release in $f" >&2; exit 1; }
    sed -i "s/^release = $n\$/release = $((n + 1))/" "$f"
}

# add "libselinux-devel" (and more) to builddeps, creating the line when there is none
adddeps() {
    f=$1; shift
    list=
    for d in "$@"; do list="$list\"$d\", "; done
    if grep -q '^builddeps = \[' "$f"; then
        sed -i "s/^builddeps = \[/builddeps = [${list}/" "$f"
    else
        sed -i "/^homepage = /a builddeps = [${list%, }]" "$f"
    fi
}

# replace a string in a recipe and make sure it was there
swap() {
    f=$1; from=$2; to=$3
    grep -qF -- "$from" "$f" || { echo "integrate: '$from' not in $f" >&2; exit 1; }
    sed -i "s|$from|$to|" "$f"
}

f=$(recipe linux-pam)
swap "$f" '-Dselinux=disabled' '-Dselinux=enabled'
adddeps "$f" libselinux-devel
bump "$f"

f=$(dirname "$(recipe linux-pam-base)")/files/system-login
grep -q pam_selinux "$f" || {
    sed -i '/^session optional pam_loginuid.so$/i session required pam_selinux.so close' "$f"
    sed -i '/^session optional pam_keyinit.so force revoke$/a session required pam_selinux.so open' "$f"
}
grep -q 'pam_selinux.so close' "$f" && grep -q 'pam_selinux.so open' "$f"
bump "$(recipe linux-pam-base)"

f=$(recipe shadow)
swap "$f" '--without-selinux' '--with-selinux'
adddeps "$f" libselinux-devel libsemanage-devel
bump "$f"

f=$(recipe openssh)
swap "$f" '--without-selinux' '--with-selinux'
adddeps "$f" libselinux-devel
bump "$f"

f=$(recipe cronie)
swap "$f" '--without-selinux' '--with-selinux'
adddeps "$f" libselinux-devel
bump "$f"

f=$(recipe sudo)
swap "$f" '--with-pam' '--with-pam --with-selinux'
adddeps "$f" libselinux-devel
bump "$f"

f=$(recipe networkmanager)
swap "$f" '-Dselinux=false' '-Dselinux=true'
adddeps "$f" libselinux-devel
bump "$f"

for n in coreutils findutils tar util-linux; do
    f=$(recipe "$n")
    adddeps "$f" libselinux-devel
    bump "$f"
done

echo "integrate: done. Next: dkbuild check; build the touched packages; make an image; tests/qemu-pam.sh; boot with selinux=1 enforcing=0."
