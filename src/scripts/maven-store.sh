#!/bin/sh
# dkbuild mavendeps (SPEC.md 7.4): copies what a Maven build downloaded into its
# local repository ($1, Maven's own layout: <group as path>/<artifact>/<version>/
# <file>) into the shared Maven-layout store ($2, the one gradledeps fills too),
# with .sha1 and .sha256 files beside each file. The bookkeeping files of a local
# repository (_remote.repositories, *.lastUpdated, resolver-status.properties) are
# left out; a repository's metadata (maven-metadata-<id>.xml: plugin prefixes, the
# versions of an artifact) is kept as maven-metadata.xml, which is what a repository
# serves. Writes the store paths it used to $3, one per line.
set -eu
src=$1 store=$2 list=$3
: > "$list.part"
[ -d "$src" ] || { mv "$list.part" "$list"; exit 0; }
cd "$src"
find . -type f ! -name '_remote.repositories' ! -name '*.lastUpdated' ! -name 'resolver-status.properties' \
    ! -name '*.sha1' ! -name '*.sha256' ! -name '*.md5' ! -name '*.part' | while read -r f; do
    f=${f#./}
    rel=$f
    case ${f##*/} in
        maven-metadata-*.xml) rel=${f%/*}/maven-metadata.xml; [ "${f%/*}" = "$f" ] && rel=maven-metadata.xml ;;
    esac
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
