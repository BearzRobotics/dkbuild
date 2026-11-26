#!/bin/sh
# Wait for a running world pass, then run `world --keep-going` passes (prune first) until one has no failures.
# Start it as its own systemd user service, from the top of the tree:
#     systemd-run --user --unit=dkworld --collect -p OOMPolicy=continue --working-directory="$PWD" \
#         --setenv=PATH="$PATH" "$PWD/contrib/worldloop.sh"
# (stop: systemctl --user stop dkworld). Not setsid/nohup: that stays in the terminal's cgroup, and when the kernel's
# OOM killer took one rustc (2026-11-25), systemd stopped the whole terminal tab with the loop and everything else in
# it. With OOMPolicy=continue only the compiler dies, and that one package fails.
# Logs: work/world<n>.log, work/prune<n>.log, one summary line per pass in work/worldloop.log.
# DKBUILD_FAST_WORK (build roots on a faster disk) is taken from the environment; unset, they go in work/.
cd "$(dirname "$0")/.." || exit 1
export DKBUILD_FAST_WORK="${DKBUILD_FAST_WORK-}"
# repo/x86_64 may be a link to another disk: do not start when it leads nowhere
[ -d repo/x86_64/ ] || { echo "repo/x86_64 is missing (disk not mounted?)" > work/worldloop.err; exit 1; }
# Wait for whatever builds or prunes in this tree: dkbuild holds this lock while it does. (A search of the process
# list matched other trees and mere mentions of the words, and missed pkg and 'dkbuild --tree DIR world'.) A running
# fetch is left alone: prune refuses to run beside one.
mkdir -p work
if ! flock -n work/dkbuild.lock true; then
    echo "waiting for the dkbuild that is working in this tree" >> work/worldloop.log
    flock work/dkbuild.lock true
fi
# continue the numbering, so that earlier pass logs are kept
# (after the highest number, not the first free one: a gap would lead into later logs and overwrite them)
n=1
for f in work/world[0-9]*.log; do
    i=${f#work/world}
    i=${i%.log}
    case $i in *[!0-9]*) continue ;; esac
    [ "$i" -ge "$n" ] && n=$((i+1))
done
last=$((n+16))
while [ "$n" -le "$last" ]; do
    ./zig-out/bin/dkbuild prune > "work/prune$n.log" 2>&1
    ./zig-out/bin/dkbuild world --keep-going --color=always > "work/world$n.log" 2>&1
    rc=$?
    echo "pass $n exit=$rc failed=$(grep -ac BuildFailed "work/world$n.log")" >> work/worldloop.log
    [ "$rc" -eq 0 ] && break
    n=$((n+1))
done
echo "loop ended after pass $n" >> work/worldloop.log
