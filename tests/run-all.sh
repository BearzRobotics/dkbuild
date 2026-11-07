#!/bin/sh
# Unit tests, recipe check, then the end-to-end tests once for each build base
# that is present: rootfs/dkrescue (the DKRescue image from `dkbuild
# bootstrap-root`) and rootfs/chimera (the old prototype base). Needs the signing
# key in ~/.config/dkbuild. Host tools (Ubuntu): sudo apt install ca-certificates curl
# git tar xz-utils xorriso squashfs-tools util-linux openssl; `dkbuild doctor` checks them.
set -u
cd "$(dirname "$0")/.."
zig build test --summary all 2>&1 | grep -E "Build Summary|error:" || exit 1
zig build || exit 1
./zig-out/bin/dkbuild check || exit 1
status=0
ran=0
for base in dkrescue chimera; do
    [ -d "rootfs/$base" ] || continue
    ran=1
    echo "===== base: $base"
    for t in forgotten-dep sandbox chain rebuild repo-install; do
        DKBUILD_BASE=$base ./tests/$t.sh || status=1
    done
    # musl.sh drives the Chimera toolchain itself.
    if [ "$base" = chimera ]; then ./tests/musl.sh || status=1; fi
done
[ "$ran" = 1 ] || { echo "no build base: run 'dkbuild bootstrap-root <dkrescue.iso>' first"; exit 1; }
exit $status
