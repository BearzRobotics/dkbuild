#!/bin/sh
# SPEC.md 12 sandbox tests: a build can't reach the network, can't see /home or
# the host's processes, and leaves no mount or process behind.
set -u
cd "$(dirname "$0")/.."
T=tests/trees/sandbox
. tests/lib.sh

# a variable that must not reach a build
export DKTEST_LEAK=1

# Control: on the host, each check must fire by itself. (That the probe merely fails there proves nothing about
# the others: for an ordinary user the uid check alone does that.) The connection attempt is not required, as
# the host may be offline.
CONTROL=$(sh tests/sandbox-probe.sh 2>&1)
for want in 'network interface' 'home directory' 'processes visible' 'not uid 0' 'HOME is' 'environment leaked'; do
    [ "$want" = 'not uid 0' ] && [ "$(id -u)" = 0 ] && continue
    echo "$CONTROL" | grep -q "VIOLATION: .*$want" || { echo "$CONTROL"; echo "FAIL: on the host the probe's '$want' check did not fire, so it proves nothing"; exit 1; }
done

newtree "$T"
mkdemo "$T/src"
mkdir -p "$T/packages/p/probe/files"
sed "s|@HOSTHOME@|$HOME|" tests/sandbox-probe.sh > "$T/packages/p/probe/files/probe.sh"
cat > "$T/packages/p/probe/package.toml" <<EOF
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

OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" probe 2>&1) || { echo "$OUT" | tail -20; echo "FAIL: the build sandbox is not isolated"; exit 1; }

# Match on the command name, so this script's own command line can't match.
LEFT=$(ps -eo pid=,comm=,args= | awk '$2 == "sleep" && $3 == "sleep" && $4 == "7777" { print $1 }')
if [ -n "$LEFT" ]; then
    kill $LEFT; echo "FAIL: a process from the build outlived it"; exit 1
fi
# No process is left with a mount of the build's (the host's own table could never show them: the sandbox mounts in
# its own namespace), and its build directory is gone.
if grep -l "$PWD/$T/work/" /proc/[0-9]*/mountinfo 2>/dev/null | grep -q .; then
    echo "FAIL: a process still has a mount from the build"; exit 1
fi
LEFTDIRS=$(find "$T/work" -mindepth 1 -maxdepth 1 ! -name dkbuild.lock 2>/dev/null)
if [ -n "$LEFTDIRS" ]; then
    echo "FAIL: the build left its work directory behind: $LEFTDIRS"; exit 1
fi
echo "ok: no network, no /home, no host processes, uid 0 with a clean environment; nothing left behind"
