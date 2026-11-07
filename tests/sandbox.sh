#!/bin/sh
# SPEC.md 12 sandbox tests: a build can't reach the network, can't see /home or
# the host's processes, and leaves no mount or process behind.
set -u
cd "$(dirname "$0")/.."
T=tests/trees/sandbox
. tests/lib.sh

# Control: the probe must flag the host, or it checks nothing.
if sh tests/sandbox-probe.sh >/dev/null 2>&1; then
    echo "FAIL: the probe found nothing wrong on the host, so it proves nothing"; exit 1
fi

newtree "$T"
mkdemo "$T/src"
mkdir -p "$T/packages/probe/files"
sed "s|@HOSTHOME@|$HOME|" tests/sandbox-probe.sh > "$T/packages/probe/files/probe.sh"
cat > "$T/packages/probe/package.toml" <<EOF
name    = "probe"
version = "1"
release = 1
summary = "Test recipe: checks the sandbox from the inside"
license = "MIT"
options = ["!check"]

source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
]

build = '''
sleep 7777 &
sh \$pkgfiles/probe.sh
'''
install = '''
mkdir -p \$pkgdir/usr/share/probe
echo ok > \$pkgdir/usr/share/probe/ok
'''
EOF

OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg probe 2>&1) || { echo "$OUT" | tail -20; echo "FAIL: the build sandbox is not isolated"; exit 1; }

# Match on the command name, so this script's own command line can't match.
LEFT=$(ps -eo pid=,comm=,args= | awk '$2 == "sleep" && $3 == "sleep" && $4 == "7777" { print $1 }')
if [ -n "$LEFT" ]; then
    kill $LEFT; echo "FAIL: a process from the build outlived it"; exit 1
fi
if grep -q "trees/sandbox" /proc/mounts; then
    echo "FAIL: a mount from the build is still there"; exit 1
fi
echo "ok: no network, no /home, no host processes, uid 0 with a clean environment; nothing left behind"
