#!/bin/sh
# A build's packages reach repo/ all together or not at all: when one cannot be made, none of them may appear (the
# index would not match, `prune` would drop the old ones, and the next run could call the half-made set up to date).
# And a rebuild at the same version leaves no file of a subpackage it no longer makes.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/publish
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
R=$T/packages/d/dkdemo/package.toml
cat >> "$R" <<'EOR'

[subpackages.extra]
summary = "An extra, empty one"
empty = true
EOR
build() { ./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" "$@" dkdemo 2>&1; }
fail() { echo "$OUT" | tail -8; echo "FAIL: $1"; exit 1; }
OUT=$(build) || fail "first build"
[ -e "$T/repo/x86_64/dkdemo-extra-1-r1.apk" ] || fail "no -extra package"

# release 2, where the last package cannot be made
sed -i -e 's/^release = 1$/release = 2/' -e 's/^empty = true$/&\ndepends = ["not a dependency >>>"]/' "$R"
OUT=$(build) && fail "the build with an impossible dependency succeeded"
LEFT=$(find "$T/repo/x86_64" -name '*-r2.apk' -o -name '*.part')
[ -z "$LEFT" ] || { echo "$LEFT"; fail "a failed publish left some of the new packages in repo/"; }
[ -e "$T/repo/x86_64/dkdemo-1-r1.apk" ] || fail "the old package is gone"

# the same version built again without the subpackage: its file goes
sed -i -e 's/^release = 2$/release = 1/' -e '/^depends = \["not a dependency >>>"\]$/d' "$R"
sed -i '/^\[subpackages.extra\]$/,/^empty = true$/d' "$R"
OUT=$(build --force) || fail "rebuild without -extra"
[ ! -e "$T/repo/x86_64/dkdemo-extra-1-r1.apk" ] || fail "the file of a subpackage that is no longer made stayed in repo/"
[ -e "$T/repo/x86_64/dkdemo-1-r1.apk" ] && [ -e "$T/repo/x86_64/dkdemo-devel-1-r1.apk" ] || fail "packages that are made are gone"
echo "ok: all of a build's packages are published or none; dropped subpackages go"
