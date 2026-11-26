#!/bin/sh
# A subpackage that depends on `name=@built` (zfs's modules on their kernel) must always name the version in repo/:
# when the pinned package gets a new release, it is built again, and published with the new pin even though its
# files come out the same.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/pins
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
user_recipe "$T" usedemo dkdemo-devel
cat >> "$T/packages/u/usedemo/package.toml" <<'EOR'

[subpackages.mod]
summary = "Pinned to the dkdemo it was built with"
empty = true
depends = ["dkdemo=@built"]
EOR
run() { ./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" usedemo 2>&1; }
fail() { echo "$OUT" | tail -8; echo "FAIL: $1"; exit 1; }
pin_of() { # the dependency recorded in usedemo-mod's newest package
    sbrun --robind "$PWD/$T/repo/x86_64" /tmp/repo -- /usr/bin/sh -c "apk adbdump /tmp/repo/usedemo-mod-1-r$1.apk" 2>/dev/null | grep -o 'dkdemo=1-r[0-9]*' | head -n 1
}
OUT=$(run) || fail "first build"
[ "$(pin_of 1)" = dkdemo=1-r1 ] || fail "usedemo-mod is not pinned to dkdemo-1-r1: $(pin_of 1)"
OUT=$(run) || fail "second run"
echo "$OUT" | grep -q 'usedemo-1-r1: up to date' || fail "usedemo was not up to date when nothing had changed"

# a new release of dkdemo with the same files
sed -i 's/^release = 1$/release = 2/' "$T/packages/d/dkdemo/package.toml"
OUT=$(run) || fail "build after dkdemo's new release"
[ -e "$T/repo/x86_64/usedemo-mod-1-r2.apk" ] || fail "usedemo was not published again: its package still names dkdemo-1-r1"
[ "$(pin_of 2)" = dkdemo=1-r2 ] || fail "the new usedemo-mod does not name dkdemo-1-r2: $(pin_of 2)"
OUT=$(run) || fail "run after that"
echo "$OUT" | grep -q 'usedemo-1-r2: up to date' || fail "usedemo r2 was not up to date on the next run"
echo "ok: a pinned dependency's new release republishes the pinning package, once"
