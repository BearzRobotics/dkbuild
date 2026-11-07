#!/bin/sh
# Unit tests, the recipe check, then every end-to-end script. They build in the
# real sandbox on rootfs/dkrescue (`dkbuild bootstrap-root <dkrescue.iso>`) and
# sign with ~/.config/dkbuild/signing.rsa. Host tools (Ubuntu): sudo apt install
# ca-certificates curl git tar xz-utils xorriso squashfs-tools util-linux openssl;
# `dkbuild doctor` checks them.
set -u
cd "$(dirname "$0")/.."
zig build test --summary all 2>&1 | grep -E "Build Summary|error:" || exit 1
zig build || exit 1
./zig-out/bin/dkbuild check || exit 1
[ -d rootfs/dkrescue ] || { echo "no build machine: run 'dkbuild bootstrap-root <dkrescue.iso>' first"; exit 1; }
status=0
for t in forgotten-dep sandbox chain rebuild scripts repo-install musl import; do
    ./tests/$t.sh || status=1
done
exit $status
