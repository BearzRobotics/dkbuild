#!/bin/sh
# Unit tests, the recipe check, then every end-to-end script. They build in the
# real sandbox on rootfs/dkrescue (`dkbuild bootstrap-root <dkrescue.iso>`) and
# sign their test packages with a key made for the run (lib.sh testkey); repo-install and
# musl build real recipes in test trees of their own. Host tools (Ubuntu): sudo apt install
# ca-certificates curl git tar xz-utils xorriso squashfs-tools util-linux openssl;
# `dkbuild doctor` checks them.
set -u
cd "$(dirname "$0")/.." || exit 1
# zig's own status decides; piping it into grep would report grep's, which succeeds whenever it prints a line
units=$(zig build test --summary all 2>&1) || { printf '%s\n' "$units"; echo "FAIL: unit tests"; exit 1; }
printf '%s\n' "$units" | grep "Build Summary"
zig build || exit 1
./zig-out/bin/dkbuild check || exit 1
python3 -B tests/upstream-rules.py > /dev/null || { python3 -B tests/upstream-rules.py | grep FAIL; exit 1; }
[ -d rootfs/dkrescue ] || { echo "no build machine: run 'dkbuild bootstrap-root <dkrescue.iso>' first"; exit 1; }
status=0
for t in forgotten-dep isolation sandbox signing vendor-layout fetch-cargo fetch-zig restore-store prune snapshot-deps snapshot-pins chain rebuild pins scripts repo-install musl import parallel; do
    ./tests/$t.sh || status=1
done
exit $status
