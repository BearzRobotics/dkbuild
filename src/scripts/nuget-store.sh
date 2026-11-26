#!/bin/sh
# dkbuild nugetdeps (SPEC.md 7.4): copies the packages a restore put in NuGet's
# global packages folder ($1: <id>/<version>/<id>.<version>.nupkg, with its
# .nupkg.sha512) into the shared store ($2, the same layout: a local NuGet
# feed). Writes the store paths it used to $3, one per line.
set -eu
src=$1 store=$2 list=$3
: > "$list.part"
cd "$src"
find . -mindepth 3 -maxdepth 3 -type f -name '*.nupkg' | while read -r f; do
    f=${f#./}
    dir=${f%/*}
    dest=$store/$dir
    if [ ! -e "$dest/${f##*/}" ]; then
        mkdir -p "$dest"
        cp "$f" "$dest/${f##*/}.part"
        [ -f "$f.sha512" ] && cp "$f.sha512" "$dest/"
        mv "$dest/${f##*/}.part" "$dest/${f##*/}"
    fi
    echo "$f" >> "$list.part"
done
sort -u "$list.part" > "$list.sorted" && rm -f "$list.part" && mv "$list.sorted" "$list"
