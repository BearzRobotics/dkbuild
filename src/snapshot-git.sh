#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): a git repository with its submodules, for
# sources whose release archives leave the submodules out, as
#   { url = "snapshot:git <repository URL> <tag or commit>", sha256 = ... }
#
#   $1  the tarball to write    $2  a work directory (kept between runs)
#   $3  the repository URL      $4  a tag or a full commit hash
#
# A shallow clone at that ref, every submodule at the commit the ref records
# (recursively), no VCS data; packed reproducibly (sorted, fixed times and
# owners), so the same ref gives the same sha256.
set -eu
out=$1 work=$2 url=$3 ref=$4
name=$(basename "$url" .git)-$ref
mkdir -p "$work"
cd "$work"
log() { echo "snapshot: $*" >&2; }

if [ ! -f src/.done ]; then
    rm -rf src
    git init -q src
    git -C src remote add origin "$url"
    log "$url at $ref"
    git -C src fetch -q --depth 1 origin "$ref"
    git -C src checkout -q FETCH_HEAD
    log "submodules"
    git -C src submodule update -q --init --recursive --depth 1 || git -C src submodule update -q --init --recursive
    touch src/.done
fi

rm -rf "$name"
mkdir "$name"
cp -al src/. "$name/"
find "$name" -name .git -prune -exec rm -rf {} +
rm -f "$name/.done"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - "$name" | zstd -q -19 --long=27 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
