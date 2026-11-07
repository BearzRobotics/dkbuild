#!/bin/sh
# Install scripts (SPEC 9.4): scripts/<type> next to package.toml are attached to the
# main package with 'apk mkpkg --script', and apk runs them when it installs it.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
T=tests/trees/scripts
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
mkdir -p "$T/packages/d/dkdemo/scripts"
printf '#!/bin/sh\necho pre > /pre-ran\n' > "$T/packages/d/dkdemo/scripts/pre-install"
printf '#!/bin/sh\necho post > /post-ran\n' > "$T/packages/d/dkdemo/scripts/post-install"
chmod +x "$T/packages/d/dkdemo/scripts/"*
OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg dkdemo 2>&1) || { echo "$OUT" | tail -8; echo "FAIL: build"; exit 1; }
R=$(mktemp -d "$PWD/work/sc.XXXXXX")
trap 'rm -rf "$R"' EXIT
mkdir -p "$R/etc/apk/keys"; cp keys/*.pub "$R/etc/apk/keys/"
# The scripts run inside the target root, which needs a shell: the image's static dash.
mkdir -p "$R/bin"; cp rootfs/dkrescue/usr/bin/dash "$R/bin/sh"
sbrun --bind "$R" /mnt --robind "$PWD/$T/repo/x86_64" /tmp/repo --robind "$PWD/repo/x86_64" /tmp/real -- /usr/bin/apk --root /mnt --initdb \
    --keys-dir /mnt/etc/apk/keys --repository /tmp/repo/Packages.adb --repository /tmp/real/Packages.adb --no-network --no-interactive add dkdemo >"$R/log" 2>&1 \
    || { cat "$R/log"; echo "FAIL: apk add"; exit 1; }
[ "$(cat "$R/pre-ran" 2>/dev/null)" = pre ] || { cat "$R/log"; echo "FAIL: pre-install did not run"; exit 1; }
[ "$(cat "$R/post-ran" 2>/dev/null)" = post ] || { echo "FAIL: post-install did not run"; exit 1; }
[ -e "$R/usr/lib/libdkdemo.so.1" ] || { echo "FAIL: package files missing"; exit 1; }
echo "ok: pre-install and post-install scripts are in the package and run on install"
