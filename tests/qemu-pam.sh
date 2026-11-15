#!/bin/sh
# Boots a live ISO in QEMU (headless, serial console) and exercises PAM by hand-like
# steps: console login, sudo, useradd/chpasswd, su with a right and a wrong password,
# sudo refused for a user outside wheel, and an ssh login with a right and a wrong password.
# Everything is typed on the serial console; the transcript is kept in
# work/qemu-pam-<name>-<firmware>.log and the result of each check is printed.
#
#   tests/qemu-pam.sh out/base/base.iso uefi
#
# Needs qemu-system-x86_64 (and OVMF for uefi), like tests/qemu-iso.sh.
# SC2016: the single-quoted commands are typed into the VM, where they expand, not here
# shellcheck disable=SC2016
set -u
iso=${1:?usage: qemu-pam.sh ISO bios|uefi}
fw=${2:?usage: qemu-pam.sh ISO bios|uefi}
cd "$(dirname "$0")/.." || exit 1
[ -f "$iso" ] || { echo "FAIL: no ISO at $iso"; exit 1; }
mkdir -p work
name=$(basename "$iso" .iso)
log=work/qemu-pam-$name-$fw.log
: > "$log"

accel="-accel tcg"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && accel="-accel kvm -cpu host"
case $fw in
    bios) firmware="" ;;
    uefi)
        code=/usr/share/OVMF/OVMF_CODE_4M.fd
        vars=/usr/share/OVMF/OVMF_VARS_4M.fd
        [ -f "$code" ] || { echo "FAIL: no OVMF ($code)"; exit 1; }
        cp "$vars" "work/qemu-pam-$name-vars.fd"
        firmware="-drive if=pflash,format=raw,readonly=on,file=$code -drive if=pflash,format=raw,file=work/qemu-pam-$name-vars.fd"
        ;;
    *) echo "FAIL: firmware is bios or uefi"; exit 1 ;;
esac

fifo=work/qemu-pam-$name-serial
rm -f "$fifo.in" "$fifo.out"; mkfifo "$fifo.in" "$fifo.out"
cat "$fifo.out" >> "$log" &
reader=$!
exec 3<>"$fifo.in"

# shellcheck disable=SC2086
qemu-system-x86_64 $accel -m 4096 -smp 4 $firmware \
    -cdrom "$iso" -boot d \
    -display none -serial "pipe:$fifo" -monitor none -no-reboot &
pid=$!

fails=0
n=0
send() { printf '%s\r' "$1" >&3; }

# wait_new PATTERN SECONDS: PATTERN (basic regex) in what the console printed after the
# last mark; fails on timeout.
mark=0
mark_now() { mark=$(wc -c < "$log"); }
wait_new() {
    w=0
    while [ "$w" -lt "$2" ]; do
        tail -c "+$((mark + 1))" "$log" | grep -q -- "$1" && return 0
        kill -0 $pid 2>/dev/null || return 1
        sleep 1; w=$((w + 1))
    done
    return 1
}

# check LABEL PATTERN SECONDS COMMAND: types COMMAND, waits for PATTERN, reports.
check() {
    n=$((n + 1))
    mark_now
    send "$4"
    if wait_new "$2" "$3"; then
        echo "ok:   $1"
    else
        echo "FAIL: $1 (wanted '$2' after: $4)"
        fails=$((fails + 1))
    fi
}

# answer PATTERN TEXT: waits for PATTERN since the last command, then types TEXT.
answer() {
    wait_new "$1" 20 || { echo "FAIL: no '$1' prompt"; fails=$((fails + 1)); return 1; }
    mark_now
    send "$2"
}

# --- boot and log in as live (empty password)
w=0
while [ $w -lt 240 ] && ! grep -q "login:" "$log" 2>/dev/null; do
    kill -0 $pid 2>/dev/null || break
    sleep 2; w=$((w + 2))
done
if ! grep -q "login:" "$log"; then
    tail -20 "$log"; echo "FAIL: no login prompt"; kill $pid 2>/dev/null; exit 1
fi
sleep 2
mark_now
send live
sleep 3
check "console login as live" "^USER-live" 15 'echo "USER-$(id -un)"'
check "live is in wheel" "^GROUPS-.*wheel" 10 'echo "GROUPS-$(id -Gn)"'
check "base tools present: grep sed find xargs awk edit" "^TOOLS-none" 15 'm=; for t in grep sed find xargs awk edit; do command -v $t >/dev/null || m="$m $t"; done; echo "TOOLS-${m:-none}"'
check "PAM service files installed" "^PAMDIR-.*sshd" 10 'echo "PAMDIR-$(ls /usr/lib/pam.d | tr "\n" " ")"'

# --- sudo for a wheel user (the live user has an empty password)
mark_now
send 'sudo id -un; echo SUDO1-END'
if wait_new "assword" 6; then mark_now; send ''; fi
if wait_new "^root" 10; then echo "ok:   sudo as live gives root"; else echo "FAIL: sudo as live"; fails=$((fails + 1)); fi

# --- an ordinary account with a password
check "useradd" "^USERADD-OK" 15 'sudo useradd -m tester && echo USERADD-OK'
check "chpasswd (PAM, as root)" "^CHPASSWD-OK" 15 'printf "tester:Pw-123456\n" | sudo chpasswd && echo CHPASSWD-OK'

# --- su with the right and a wrong password
mark_now; send 'su tester'
answer "assword" 'Pw-123456' || true
sleep 2
check "su tester (right password)" "^SU-tester" 15 'echo "SU-$(id -un)"'
mark_now; send 'exit'
sleep 2
check "back with exit" "^EXIT-live" 15 'echo "EXIT-$(id -un)"'
mark_now; send 'su tester'
answer "assword" 'wrong-password' || true
if wait_new "uthentication failure\|incorrect password\|Sorry" 15; then echo "ok:   su with a wrong password refused"; else echo "FAIL: su wrong password not refused"; fails=$((fails + 1)); fi
sleep 3

# --- sudo for a user that is not in wheel: refused
mark_now; send 'su tester'
answer "assword" 'Pw-123456' || true
sleep 2
mark_now; send 'sudo id -un'
answer "assword" 'Pw-123456' || true
if wait_new "not in the sudoers\|not allowed" 15; then echo "ok:   sudo refused outside wheel"; else echo "FAIL: sudo not refused for tester"; fails=$((fails + 1)); fi
mark_now; send 'exit'
sleep 2

# --- ssh to localhost, right and wrong password
check "start sshd" "^SSHD-START-DONE" 40 'sudo dinitctl start sshd; echo SSHD-START-DONE'
sleep 3
mark_now; send 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 id -un'
answer "assword" 'Pw-123456' || true
if wait_new "^tester" 20; then echo "ok:   ssh login with the right password"; else echo "FAIL: ssh login"; fails=$((fails + 1)); fi
mark_now; send 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 tester@127.0.0.1 id -un'
answer "assword" 'wrong-password' || true
if wait_new "ermission denied" 20; then echo "ok:   ssh with a wrong password refused"; else echo "FAIL: ssh wrong password not refused"; fails=$((fails + 1)); fi

# --- su and sudo are setuid root
check "su and sudo are setuid" "^SUID-4755 4755" 15 'echo "SUID-$(stat -c %a /usr/bin/su) $(stat -c %a /usr/bin/sudo)"'

kill $pid 2>/dev/null; wait $pid 2>/dev/null
exec 3>&-
kill $reader 2>/dev/null; wait $reader 2>/dev/null
rm -f "$fifo.in" "$fifo.out"

if [ "$fails" -eq 0 ]; then
    echo "ok: PAM checks passed on $name ($fw); transcript: $log"
else
    echo "FAIL: $fails PAM check(s) failed on $name ($fw); transcript: $log"
    exit 1
fi
