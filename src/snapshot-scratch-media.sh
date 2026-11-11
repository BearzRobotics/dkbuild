#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): Scratch's media library (the costumes,
# sprites, sounds and backdrops its editor offers), for Scratch Desktop, as
#   { url = "snapshot:scratch-media <@scratch/scratch-gui version>", sha256 = ... }
#
#   $1  the tarball to write    $2  a work directory (kept between runs)
#   $3  the @scratch/scratch-gui npm version whose library lists are used
#
# Scratch Desktop's `npm run fetch` (scripts/fetchMediaLibraryAssets.js) does
# this in its build; here it happens at fetch time. Every asset is named by
# the MD5 of its content, which is checked; a download that does not match
# fails the snapshot. The tarball holds scratch-media-<version>/<md5>.<ext>,
# packed reproducibly (sorted, fixed times and owners).
set -eu
out=$1 work=$2 ver=$3
name=scratch-media-$ver
mkdir -p "$work/assets"
cd "$work"
log() { echo "snapshot: $*" >&2; }

if [ ! -f gui/.done ]; then
    rm -rf gui
    mkdir gui
    log "@scratch/scratch-gui $ver"
    curl -sSfL --retry 3 -o gui.tgz "https://registry.npmjs.org/@scratch/scratch-gui/-/scratch-gui-$ver.tgz"
    tar -xzf gui.tgz -C gui package/src/lib/libraries
    rm gui.tgz
    touch gui/.done
fi

# the asset names, as fetchMediaLibraryAssets.js collects them
python3 -I - gui/package/src/lib/libraries > list.txt <<'PY'
import json, sys, os
d = sys.argv[1]
names = set()
def simple(items):
    for it in items:
        for k in ("md5", "baseLayerMD5", "md5ext"):
            if it.get(k):
                names.add(it[k])
for f in ("backdrops", "costumes", "sounds"):
    simple(json.load(open(os.path.join(d, f + ".json"))))
for s in json.load(open(os.path.join(d, "sprites.json"))):
    simple(s.get("costumes", []))
    simple(s.get("sounds", []))
for n in sorted(names):
    print(n)
PY
log "$(wc -l < list.txt) assets"

fetch_one() {
    a=$1
    f="assets/$a"
    if [ ! -f "$f" ]; then
        curl -sSfL --retry 3 -o "$f.tmp" "https://cdn.assets.scratch.mit.edu/internalapi/asset/$a/get/"
        mv "$f.tmp" "$f"
    fi
    sum=$(md5sum "$f" | cut -d' ' -f1)
    if [ "$sum" != "${a%%.*}" ]; then
        echo "snapshot: $a: content md5 is $sum" >&2
        rm -f "$f"
        return 1
    fi
}
failed=0
while read -r a; do
    fetch_one "$a" || failed=$((failed + 1))
done < list.txt
[ "$failed" -eq 0 ] || { log "$failed asset(s) failed"; exit 1; }

rm -rf "$name"
mkdir "$name"
while read -r a; do ln "assets/$a" "$name/$a"; done < list.txt
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - "$name" | zstd -q -19 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
