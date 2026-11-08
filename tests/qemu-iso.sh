#!/bin/sh
# Boots a live ISO made by `dkbuild image` in QEMU, headless, and passes when
# the system reaches a login prompt on the serial console (the ttyS0 getty from
# dinit-services). Firmware: bios (SeaBIOS) or uefi (OVMF), both through dklilo.
#
#   tests/qemu-iso.sh out/base/base.iso uefi [seconds]
#
# Needs qemu-system-x86_64, and OVMF for uefi (Ubuntu: apt install qemu-system-x86
# ovmf). Uses KVM when /dev/kvm is usable. The serial log is kept in
# work/qemu-<name>-<firmware>.log.
set -u
iso=${1:?usage: qemu-iso.sh ISO bios|uefi [seconds]}
fw=${2:?usage: qemu-iso.sh ISO bios|uefi [seconds]}
limit=${3:-240}
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

# shellcheck disable=SC2086
qemu-system-x86_64 $accel -m 4096 -smp 4 $firmware \
    -cdrom "$iso" -boot d \
    -display none -serial "file:$log" -monitor none -no-reboot &
pid=$!

t=0
result=timeout
while [ $t -lt "$limit" ]; do
    if grep -q "login:" "$log" 2>/dev/null; then result=ok; break; fi
    kill -0 $pid 2>/dev/null || { result=exited; break; }
    sleep 2; t=$((t + 2))
done
kill $pid 2>/dev/null; wait $pid 2>/dev/null

case $result in
    ok) echo "ok: $name boots to a login prompt ($fw, ${t}s)" ;;
    *)  tail -25 "$log"; echo "FAIL: $name did not reach a login prompt ($fw: $result after ${t}s); log: $log"; exit 1 ;;
esac
