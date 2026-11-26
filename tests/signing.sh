#!/bin/sh
# What a build leaves in its writable layer is never run with the signing key. The recipe here replaces the build
# root's apk, as a hostile upstream build could, with one that notes the key it is handed.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/signing
newtree "$T"
mkdemo "$T/src"
mkdir -p "$T/packages/t/trap"
cat > "$T/packages/t/trap/package.toml" <<EOR
name    = "trap"
version = "1"
release = 1
summary = "Test recipe: replaces apk in the build root"
license = "MIT"
options = ["!check"]

source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
]

build = '''
mv /usr/bin/apk /usr/bin/apk.real
cat > /usr/bin/apk <<'FAKE'
#!/usr/bin/sh
[ -e /tmp/key ] && [ -d /tmp/out ] && cp /tmp/key /tmp/out/TAKEN
exec /usr/bin/apk.real "\$@"
FAKE
chmod 755 /usr/bin/apk
'''
install = '''
mkdir -p \$pkgdir/usr/share/trap
echo ok > \$pkgdir/usr/share/trap/ok
'''
EOR
OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" trap 2>&1) || { echo "$OUT" | tail -15; echo "FAIL: the test package did not build"; exit 1; }
[ ! -e "$T/repo/x86_64/TAKEN" ] || { echo "FAIL: the build's own apk ran with the signing key and copied it into repo/"; exit 1; }
# the package and the index are properly signed all the same
[ -e "$T/repo/x86_64/trap-1-r1.apk" ] && [ -e "$T/repo/x86_64/Packages.adb" ] || { echo "FAIL: no package or index"; exit 1; }
sbrun --robind "$PWD/$T/repo/x86_64" /tmp/repo --robind "$PWD/$T/keys" /tmp/keys -- /usr/bin/apk --keys-dir /tmp/keys verify \
    /tmp/repo/trap-1-r1.apk /tmp/repo/Packages.adb >/dev/null 2>&1 || { echo "FAIL: the package or index is not signed with the tree's key"; exit 1; }
echo "ok: packaging and signing run in a layer the build never wrote to"
