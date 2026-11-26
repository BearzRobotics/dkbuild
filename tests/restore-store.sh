#!/bin/sh
# The networked restore step (here mavendeps, with a pretend Maven: no network is used) runs upstream code. It must
# not be able to change what is already in the shared store, another source's list, or the root the build runs in.
# What it downloads still reaches the store, with checksums made by dkbuild.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/restore
newtree "$T"
mkdemo "$T/src"
S=$T/cache/maven; L=$T/cache/mavendeps
mkdir -p "$S/org/common/1.0" "$L" "$T/src/maven/apache-maven-9/bin"
echo genuine > "$S/org/common/1.0/common.jar"
printf 'genuine-sum\n' > "$S/org/common/1.0/common.jar.sha256"
OTHER=$(printf '%064d' 7)
echo "org/common/1.0/common.jar" > "$L/$OTHER.list"
printf '#!/bin/sh\n' > "$T/src/maven/apache-maven-9/bin/mvn"
tar -C "$T/src/maven" --owner=0 --group=0 --numeric-owner -czf "$T/src/apache-maven-9-bin.tar.gz" apache-maven-9
mkdir -p "$T/packages/m/mvndemo"
cat > "$T/packages/m/mvndemo/package.toml" <<EOR
name    = "mvndemo"
version = "1"
release = 1
summary = "Test recipe"
license = "MIT"
options = ["mavendeps", "!check"]
source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
    { url = "file://$PWD/$T/src/apache-maven-9-bin.tar.gz", sha256 = "$(sha256sum "$T/src/apache-maven-9-bin.tar.gz" | cut -d' ' -f1)", unpack = false },
]
restore = '''
# what an honest restore leaves
mkdir -p /tmp/m2-restore/org/new/2.0
echo new-artifact > /tmp/m2-restore/org/new/2.0/new.jar
mkdir -p /tmp/m2-restore/org/common/1.0
echo different-bytes > /tmp/m2-restore/org/common/1.0/common.jar
# two repositories' lists of one artifact's versions: both join what the store has
mkdir -p /tmp/m2-restore/org/lib
echo '<metadata><versioning><versions><version>2.0</version></versions><lastUpdated>2</lastUpdated></versioning></metadata>' > /tmp/m2-restore/org/lib/maven-metadata-central.xml
echo '<metadata><versioning><versions><version>3.0</version></versions><lastUpdated>3</lastUpdated></versioning></metadata>' > /tmp/m2-restore/org/lib/maven-metadata-other.xml
# what a hostile one tries
mkdir -p /dkstore/maven/org/common/1.0
echo poisoned > /dkstore/maven/org/common/1.0/common.jar || true
echo poisoned-sum > /dkstore/maven/org/common/1.0/common.jar.sha256 || true
echo poisoned > "/dkstore/mavendeps/$OTHER.list" || true
ln -s /etc/hostname /dkstore/maven/org/link.jar || true
echo changed-by-restore > /usr/lib/dk-restore-mark || true
'''
build = '''
test ! -e /usr/lib/dk-restore-mark
test -f /dkdeps/maven/org/new/2.0/new.jar
'''
install = '''
mkdir -p \$pkgdir/usr/share/mvndemo
echo ok > \$pkgdir/usr/share/mvndemo/ok
'''
EOR
mkdir -p "$S/org/lib"
echo '<metadata><versioning><versions><version>1.0</version></versions><lastUpdated>1</lastUpdated></versioning></metadata>' > "$S/org/lib/maven-metadata.xml"
OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" mvndemo 2>&1); RC=$?
fail=0
bad() { echo "FAIL: $1"; fail=1; }
[ "$(cat "$S/org/common/1.0/common.jar")" = genuine ] || bad "the restore changed an artifact that was already in the store"
[ "$(cat "$S/org/common/1.0/common.jar.sha256")" = genuine-sum ] || bad "the restore changed a checksum in the store"
[ "$(cat "$L/$OTHER.list")" = org/common/1.0/common.jar ] || bad "the restore changed another source's list"
[ ! -L "$S/org/link.jar" ] && [ ! -e "$S/org/link.jar" ] || bad "a link the restore made is in the store"
[ $RC = 0 ] || { echo "$OUT" | tail -8; bad "the build failed (a root changed by the restore, or a missing artifact)"; }
[ "$(cat "$S/org/new/2.0/new.jar" 2>/dev/null)" = new-artifact ] || bad "the downloaded artifact did not reach the store"
[ "$(cat "$S/org/new/2.0/new.jar.sha256" 2>/dev/null)" = "$(printf 'new-artifact\n' | sha256sum | cut -d' ' -f1)" ] || bad "the new artifact's sha256 is missing or wrong"
[ "$(cat "$S/org/new/2.0/new.jar.sha1" 2>/dev/null)" = "$(printf 'new-artifact\n' | sha1sum | cut -d' ' -f1)" ] || bad "the new artifact's sha1 is missing or wrong"
for v in 1.0 2.0 3.0; do grep -q "<version>$v</version>" "$S/org/lib/maven-metadata.xml" || bad "the store's version list lacks $v"; done
[ "$(cat "$S/org/lib/maven-metadata.xml.sha1" 2>/dev/null)" = "$(sha1sum "$S/org/lib/maven-metadata.xml" | cut -d' ' -f1)" ] || bad "the merged metadata's sha1 is wrong"
[ ! -e "$S/org/lib/maven-metadata-central.xml" ] || bad "a repository's own metadata file reached the store"
grep -qx 'org/lib/maven-metadata.xml' "$L/$DEMO_SHA"-????????????????.list 2>/dev/null || bad "the metadata is not in this source's list"
# named by the source and (as the recipe has a restore step) a hash of what else decides the downloads
grep -qx 'org/new/2.0/new.jar' "$L/$DEMO_SHA"-????????????????.list 2>/dev/null || bad "this source's list is missing"
[ $fail = 0 ] && echo "ok: a restore adds to the store and can change nothing in it, nor the build's root"
exit $fail
