#!/bin/sh
# What a command in the sandbox must not be able to do to the machine outside it. Uses the sandbox directly
# (`dkbuild sandbox-child`, as lib.sh's sbrun does), so no package is built.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
mkdir -p work
W=$(mktemp -d "$PWD/work/iso.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- a read-only bind stays read-only, even for root in the sandbox
mkdir "$W/ro"; echo original > "$W/ro/file"
OUT=$(sbrun --robind "$W/ro" /tmp/ro -- /usr/bin/sh -c '
    echo changed > /tmp/ro/file 2>/dev/null && echo WROTE-DIRECTLY
    mount -o remount,bind,rw /tmp/ro 2>/dev/null && echo REMOUNTED
    echo changed > /tmp/ro/file 2>/dev/null && echo WROTE-AFTER-REMOUNT
    umount /tmp/ro 2>/dev/null && echo UNMOUNTED
    echo RAN' 2>&1)
echo "$OUT" | grep -q '^RAN$' || { echo "$OUT"; fail "the read-only test did not run"; }
echo "$OUT" | grep -Eq '^(WROTE|REMOUNTED|UNMOUNTED)' && fail "a read-only bind could be changed: $OUT"
[ "$(cat "$W/ro/file")" = original ] || fail "the host file behind a read-only bind was changed"
# ... and the sandbox's root can still mount things of its own
OUT=$(sbrun -- /usr/bin/sh -c 'mkdir -p /tmp/m && mount -t tmpfs none /tmp/m && echo MOUNT-OK; id -u' 2>&1)
echo "$OUT" | grep -q '^MOUNT-OK$' || { echo "$OUT"; fail "root in the sandbox cannot mount its own tmpfs"; }

# --- the same with a whole range of ids mapped (`dkbuild image`), where the files of other users work
sub() { awk -F: -v u="$(id -un)" -v n="$(id -u)" '$1 == u || $1 == n { print $2, $3; exit }' "$1" 2>/dev/null; }
SU=$(sub /etc/subuid); SG=$(sub /etc/subgid)
if [ -n "$SU" ] && [ -n "$SG" ] && command -v newuidmap >/dev/null && command -v newgidmap >/dev/null; then
    # shellcheck disable=SC2086,SC2016  # SU and SG are "start count", two arguments each; the script expands inside
    OUT=$(sbrun --ids "$(command -v newuidmap)" "$(command -v newgidmap)" $SU $SG --robind "$W/ro" /tmp/ro -- /usr/bin/sh -c '
        mount -o remount,bind,rw /tmp/ro 2>/dev/null && echo REMOUNTED
        touch /tmp/f && chown 1000:1000 /tmp/f && echo "OWNER-$(stat -c %u:%g /tmp/f)"
        echo RAN' 2>&1)
    echo "$OUT" | grep -q '^RAN$' || { echo "$OUT"; fail "the id-range sandbox did not run"; }
    echo "$OUT" | grep -q '^REMOUNTED' && fail "with an id range, a read-only bind could be remounted"
    echo "$OUT" | grep -q '^OWNER-1000:1000$' || { echo "$OUT"; fail "with an id range, a file cannot be given to another user"; }
else
    echo "skipped: no sub-id range or newuidmap here, so the id-range sandbox was not checked"
fi

# --- signals stay inside: `kill 0` signals the caller's process group, and the sandbox must not be in ours.
# In a session of its own, so that a failure kills only this check.
cat > "$W/killer.sh" <<'EOK'
. tests/lib.sh
trap 'echo OUTSIDE-GOT-SIGNAL; exit 0' TERM
sbrun -- /usr/bin/sh -c 'kill -TERM 0'
echo OUTSIDE-UNTOUCHED
EOK
OUT=$(setsid -w sh "$W/killer.sh" 2>&1)
echo "$OUT" | grep -q '^OUTSIDE-UNTOUCHED$' || fail "a signal sent to its process group inside reached outside: $OUT"
# ... nor does it have the caller's terminal, and stopping dkbuild still stops what runs inside
# shellcheck disable=SC2016  # expands inside the sandbox
OUT=$(sbrun -- /usr/bin/sh -c 'read -r _ _ _ _ _ sid tty _ < /proc/self/stat; echo "SID-$sid TTY-$tty"' 2>&1)
echo "$OUT" | grep -q '^SID-1 TTY-0$' || fail "the command is not in a session of its own without a terminal: $OUT"
mkdir "$W/su" "$W/sw" "$W/sm" "$W/flag"
./zig-out/bin/dkbuild sandbox-child --lower "$PWD/rootfs/dkrescue" --upper "$W/su" --work "$W/sw" --merged "$W/sm" \
    --env PATH=/usr/bin:/bin --bind "$W/flag" /tmp/flag -- /usr/bin/sh -c 'touch /tmp/flag/started; sleep 3; touch /tmp/flag/survived' &
SB=$!
i=0; while [ ! -e "$W/flag/started" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -e "$W/flag/started" ] || fail "the long-running sandbox did not start"
kill "$SB"; wait "$SB" 2>/dev/null
sleep 4
[ ! -e "$W/flag/survived" ] || fail "killing dkbuild's sandbox process left the command running"
chmod -R u+rwx "$W/sw" 2>/dev/null

[ "$fails" -eq 0 ] || { echo "FAIL: $fails isolation check(s) failed"; exit 1; }
echo "ok: read-only binds stay read-only; signals and the terminal stay outside; killing the sandbox kills all in it"
