#!/bin/sh
# Wait for a running world pass, then run `world --keep-going` passes (prune first) until one has no failures.
# Start it detached, so that it outlives the terminal or editor session:
#     setsid nohup contrib/worldloop.sh >/dev/null 2>&1 &
# Logs: work/world<n>.log, work/prune<n>.log, one summary line per pass in work/worldloop.log.
# DKBUILD_FAST_WORK (build roots on a faster disk) is taken from the environment; unset, they go in work/.
cd "$(dirname "$0")/.." || exit 1
export DKBUILD_FAST_WORK="${DKBUILD_FAST_WORK-}"
# repo/x86_64 may be a link to another disk: do not start when it leads nowhere
[ -d repo/x86_64/ ] || { echo "repo/x86_64 is missing (disk not mounted?)" > work/worldloop.err; exit 1; }
while pgrep -f "dkbuild world" >/dev/null; do sleep 30; done
# continue the numbering, so that earlier pass logs are kept
n=1
while [ -e "work/world$n.log" ]; do n=$((n+1)); done
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
