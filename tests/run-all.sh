#!/bin/sh
# Unit tests, recipe check, then every end-to-end test. Needs rootfs/chimera, the
# signing key in ~/.config/dkbuild and network (for the Chimera packages).
set -u
cd "$(dirname "$0")/.."
zig build test --summary all 2>&1 | grep -E "Build Summary|error:" || exit 1
zig build || exit 1
./zig-out/bin/dkbuild check || exit 1
status=0
for t in forgotten-dep sandbox chain rebuild repo-install musl; do
    ./tests/$t.sh || status=1
done
exit $status
