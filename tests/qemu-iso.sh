#!/bin/sh
# Boots a live ISO made by `dkbuild image` in QEMU, headless, and passes when
# the system reaches a login prompt on the serial console (the ttyS0 getty from
# dinit-services). Firmware: bios (SeaBIOS) or uefi (OVMF), both through dklilo.
# Then it logs in as USER (default: live; the image's passwordless user) and
# checks what the installer needs: the live medium at /run/live/medium, and
# the root's size in it.
#
#   tests/qemu-iso.sh out/base/base.iso uefi [seconds] [user]
#
# Needs qemu-system-x86_64, and OVMF for uefi (Ubuntu: apt install qemu-system-x86
# ovmf). Uses KVM when /dev/kvm is usable. The serial log is kept in
# work/qemu-<name>-<firmware>.log.
set -u
iso=${1:?usage: qemu-iso.sh ISO bios|uefi [seconds]}
fw=${2:?usage: qemu-iso.sh ISO bios|uefi [seconds]}
limit=${3:-240}
user=${4:-live}
cd "$(dirname "$0")/.."
[ -f "$iso" ] || { echo "FAIL: no ISO at $iso"; exit 1; }
mkdir -p work
name=$(basename "$iso" .iso)
log=work/qemu-$name-$fw.log
: > "$log"

accel="-accel tcg"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && accel="-accel kvm -cpu host"
case $fw in
    bios) firmware="" ;;
    uefi)
        code=/usr/share/OVMF/OVMF_CODE_4M.fd
        vars=/usr/share/OVMF/OVMF_VARS_4M.fd
        [ -f "$code" ] || { echo "FAIL: no OVMF ($code); apt install ovmf"; exit 1; }
        cp "$vars" "work/qemu-$name-vars.fd"
        firmware="-drive if=pflash,format=raw,readonly=on,file=$code -drive if=pflash,format=raw,file=work/qemu-$name-vars.fd"
        ;;
    *) echo "FAIL: firmware is bios or uefi"; exit 1 ;;
esac

# The serial console through FIFOs: QEMU reads $fifo.in and writes $fifo.out.
fifo=work/qemu-$name-serial
rm -f "$fifo.in" "$fifo.out"; mkfifo "$fifo.in" "$fifo.out"
cat "$fifo.out" >> "$log" &
reader=$!
exec 3<>"$fifo.in"

# shellcheck disable=SC2086
qemu-system-x86_64 $accel -m 4096 -smp 4 $firmware \
    -cdrom "$iso" -boot d \
    -display none -serial "pipe:$fifo" -monitor none -no-reboot &
pid=$!

# Waits until the log has $1 (a basic regex); fails on timeout or exit.
t=0
result=ok
wait_for() {
    while [ $t -lt "$limit" ]; do
        grep -q -- "$1" "$log" 2>/dev/null && return 0
        kill -0 $pid 2>/dev/null || { result="qemu exited waiting for '$1'"; return 1; }
        sleep 2; t=$((t + 2))
    done
    result="timeout waiting for '$1'"; return 1
}

if wait_for "login:"; then
    booted=$t
    sleep 2
    printf '%s\r' "$user" >&3
    sleep 3
    printf '%s\r' 'echo "CHECK-$(id -un)"; test -f /run/live/medium/live/rootfs.sfs && test -s /run/live/medium/live/rootfs.size && echo LIVE-MEDIUM-OK; echo CHECK-END' >&3
    if wait_for "^CHECK-END"; then
        grep -q "^CHECK-$user" "$log" || result="could not log in as $user"
        [ "$result" = ok ] && { grep -q "^LIVE-MEDIUM-OK" "$log" || result="/run/live/medium has no live/rootfs.sfs and rootfs.size"; }
    fi
fi
kill $pid 2>/dev/null; wait $pid 2>/dev/null
exec 3>&-
kill $reader 2>/dev/null; wait $reader 2>/dev/null
rm -f "$fifo.in" "$fifo.out"

case $result in
    ok) echo "ok: $name boots to a login prompt ($fw, ${booted}s), logs in as $user, sees the live medium" ;;
    *)  tail -25 "$log"; echo "FAIL: $name ($fw): $result after ${t}s; log: $log"; exit 1 ;;
esac
