#!/bin/sh
# A snapshot is made in the sandbox: nothing of the host runs, and the tarball's modes (so its checksum) do not
# depend on anyone's umask. No network: the git snapshot starts from a checkout it has already.
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p work
W=$(mktemp -d "$PWD/work/snapshot-sandbox.XXXXXX") || exit 1; trap 'rm -rf "$W"' EXIT
T=$W/tree
mkdir -p "$T/packages/s/snapdemo" "$T/rootfs" "$W/bin"
cp -a profiles "$T/"
ln -s "$(readlink -f rootfs/dkrescue)" "$T/rootfs/dkrescue"
cat > "$T/packages/s/snapdemo/package.toml" <<'EOR'
name = "snapdemo"
version = "1"
release = 1
summary = "s"
license = "MIT"
source = [ { url = "snapshot:git https://invalid.example/demo.git v1", sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } ]
install = '''
true
'''
EOR
# the checkout "from before"
work=$T/cache/snapshots/git-https___invalid.example_demo.git-v1
mkdir -p "$work/src"
echo content > "$work/src/file"
chmod 664 "$work/src/file"
: > "$work/src/.done"
# stand-ins on the host's PATH: a snapshot that runs on the host would run these
for tool in sh tar zstd git; do
    printf '#!/bin/sh\necho %s >> "%s/ran-on-the-host"\nPATH=/usr/bin:/bin exec %s "$@"\n' "$tool" "$W" "$tool" > "$W/bin/$tool"
done
sed -i '1s|.*|#!/bin/dash|' "$W/bin/sh"
chmod +x "$W/bin/"*
fail=0
bad() { echo "FAIL: $1"; fail=1; }
OUT=$(umask 077; PATH="$W/bin:$PATH" ./zig-out/bin/dkbuild --tree "$T" fetch snapdemo 2>&1)
[ ! -e "$W/ran-on-the-host" ] || bad "the snapshot ran the host's $(tr '\n' ' ' < "$W/ran-on-the-host")"
got=$(echo "$OUT" | sed -n 's/.*has sha256 \([0-9a-f]*\) .*/\1/p' | head -n1)
if [ -z "$got" ]; then
    bad "no snapshot was made"; echo "$OUT" | tail -n 5; cat "$work.log" 2>/dev/null | tail -n 5
else
    modes=$(zstd -dqc --long=27 "$T/cache/sources/$got" 2>/dev/null | tar -tv | awk '{print $1}' | tr '\n' ' ')
    [ "$modes" = "drwxrwxr-x -rw-rw-r-- " ] || bad "the tarball's modes are $modes"
fi
[ ! -e "$work.sandbox" ] || bad "the sandbox's layer was left behind"
[ $fail = 0 ] && echo "ok: a snapshot is made in the sandbox, with modes no umask changes"
exit $fail
