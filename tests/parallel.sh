#!/bin/sh
# Several builds at once (-P): independent recipes overlap, a recipe waits for
# what it builds against, a heavy recipe (jobs:N) runs alone, the index lists
# every package, and with --keep-going a failure skips only what needs it.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
DK=${DKBUILD:-./zig-out/bin/dkbuild}
T=tests/trees/parallel
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
user_recipe "$T" usedemo dkdemo-devel
user_recipe "$T" usedemo-static dkdemo-static static
fail() { echo "$OUT" | tail -30; echo "FAIL: $1"; exit 1; }

# slow NAME [OPTIONS] [BUILD]: a recipe that takes a few seconds and depends on nothing.
slow() {
    _opts=${2:-'["!check"]'}
    _deps=""
    [ -n "${4:-}" ] && _deps="builddeps = [\"$4\"]"
    mkdir -p "$T/packages/$(printf %.1s "$1")/$1"
    cat > "$T/packages/$(printf %.1s "$1")/$1/package.toml" <<EOF
name    = "$1"
version = "1"
release = 1
summary = "Test package"
license = "MIT"
$_deps
options = $_opts

source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
]

build = '''
${3:-sleep 3}
'''
install = '''
mkdir -p \$pkgdir/usr/share/$1
echo $1 > \$pkgdir/usr/share/$1/file
'''
EOF
}
slow slow-a
slow slow-b
slow heavy '["jobs:2", "!check"]' 'sleep 1'

OUT=$($DK --tree "$T" pkg -P 3 usedemo usedemo-static slow-a slow-b heavy 2>&1) || fail "parallel build"
for p in dkdemo usedemo usedemo-static slow-a slow-b heavy; do
    [ -e "$T/repo/x86_64/$p-1-r1.apk" ] || fail "$p was not built"
done
echo "$OUT" | grep -Eq '^--> .*\(([2-9]) running\)$' || fail "no two builds ran at once"
echo "$OUT" | grep -q '^--> heavy-1-r1: started, alone (1 running)$' || fail "the heavy build did not run alone"
# usedemo starts only after dkdemo is built.
b=$(echo "$OUT" | grep -n 'built dkdemo-1-r1' | cut -d: -f1)
s=$(echo "$OUT" | grep -n '^--> usedemo-1-r1: started' | cut -d: -f1)
[ -n "$b" ] && [ -n "$s" ] && [ "$b" -lt "$s" ] || fail "usedemo started before dkdemo was built"
ls "$T/repo/x86_64" | grep -q '\.part$' && fail "a .part file was left in repo/"
IDX=$(sbrun --robind "$PWD/$T/repo/x86_64" /tmp/repo -- /usr/bin/apk adbdump /tmp/repo/Packages.adb 2>&1)
for p in dkdemo usedemo usedemo-static slow-a slow-b heavy; do
    echo "$IDX" | grep -q "name: $p\$" || { OUT=$IDX; fail "the index does not list $p"; }
done

# A failure skips what needs it and nothing else.
slow broken '["!check"]' 'exit 1'
slow needs-broken '["!check"]' 'true' broken
slow slow-c
OUT=$($DK --tree "$T" world -P 3 --keep-going 2>&1) && fail "world succeeded with a broken recipe"
echo "$OUT" | grep -q '^1 failed: broken$' || fail "broken was not the one failure"
echo "$OUT" | grep -q '^1 skipped: needs-broken$' || fail "needs-broken was not skipped"
[ -e "$T/repo/x86_64/slow-c-1-r1.apk" ] || fail "slow-c was not built beside the failure"
echo "$OUT" | grep -q 'dkdemo-1-r1: up to date' || fail "dkdemo was rebuilt"

echo "ok: independent builds overlap; dependencies first; heavy alone; index complete; a failure skips only its dependents"
