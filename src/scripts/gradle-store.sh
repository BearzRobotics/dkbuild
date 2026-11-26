#!/bin/sh
# dkbuild gradledeps (SPEC.md 7.4): copies what Gradle downloaded into its user
# home ($1, caches/modules-2/files-2.1/<group>/<module>/<version>/<sha1>/<file>)
# into the shared Maven-layout store ($2: <group as path>/<module>/<version>/
# <file>, with .sha1 and .sha256 files beside it, as Maven repositories have
# and Gradle checks). Writes the store paths it used to $3, one per line.
set -eu
src=$1/caches/modules-2/files-2.1
store=$2
list=$3
: > "$list.part"
[ -d "$src" ] || { mv "$list.part" "$list"; exit 0; }
cd "$src"
find . -mindepth 5 -maxdepth 5 -type f | while read -r f; do
    f=${f#./}
    group=${f%%/*}; rest=${f#*/}
    module=${rest%%/*}; rest=${rest#*/}
    version=${rest%%/*}; rest=${rest#*/}
    name=${rest#*/}
    rel=$(printf '%s' "$group" | tr . /)/$module/$version/$name
    dest=$store/$rel
    if [ ! -e "$dest" ]; then
        mkdir -p "${dest%/*}"
        cp "$f" "$dest.part"
        sha1sum "$dest.part" | cut -d' ' -f1 > "$dest.sha1"
        sha256sum "$dest.part" | cut -d' ' -f1 > "$dest.sha256"
        mv "$dest.part" "$dest"
    fi
    echo "$rel" >> "$list.part"
done
sort -u "$list.part" > "$list.sorted" && rm -f "$list.part" && mv "$list.sorted" "$list"
