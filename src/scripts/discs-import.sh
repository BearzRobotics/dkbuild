#!/bin/sh
# Copy this disc of a dkbuild disc set into DIR and check it against the
# MANIFEST. Run it once for every disc, in any order, with the same DIR:
#
#     sh /media/cdrom/import.sh /srv/fenriros
#
# Each file is checked (sha256) as it lands; a file cut across discs is joined
# and checked once all of its parts are in. The script then says which discs
# are still missing. Needs only sh, tar, awk and sha256sum (and openssl, if
# installed, to check the MANIFEST's signature).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=${1:-}
if [ -z "$dest" ]; then
    echo "usage: sh $0 DIR    (an empty directory, or one this set was copied into)" >&2
    exit 2
fi
read -r set disc total kind arch < "$here/DISC"
echo "==> $set: disc $disc of $total ($kind, $arch) -> $dest"

# The MANIFEST is what every check below trusts: check its signature first.
if [ -f "$here/MANIFEST.sig" ]; then
    if command -v openssl > /dev/null 2>&1; then
        good=no
        for k in "$here"/keys/*.pub; do
            if openssl dgst -sha256 -verify "$k" -signature "$here/MANIFEST.sig" "$here/MANIFEST" > /dev/null 2>&1; then
                good=yes
            fi
        done
        if [ "$good" != yes ]; then
            echo "error: the MANIFEST's signature does not match the keys on this disc" >&2
            exit 1
        fi
        echo "    MANIFEST signature: good"
    else
        echo "    note: openssl is not installed; the MANIFEST's signature is not checked"
    fi
fi

mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
if [ -f "$dest/DISC-SET" ] && [ "$(cat "$dest/DISC-SET")" != "$set" ]; then
    echo "error: $dest holds another set ($(cat "$dest/DISC-SET")); give an empty directory" >&2
    exit 1
fi
echo "$set" > "$dest/DISC-SET"
cp "$here/MANIFEST" "$here/README.txt" "$here/import.sh" "$dest/"
[ -f "$here/MANIFEST.sig" ] && cp "$here/MANIFEST.sig" "$dest/"
mkdir -p "$dest/keys"
cp "$here"/keys/*.pub "$dest/keys/"

echo "    copying"
(cd "$here/data" && tar -cf - .) | (cd "$dest" && tar -xf -)

echo "    checking"
tab=$(printf '\t')
awk -F'\t' -v d="$disc" '($1 == "F" || $1 == "P") && ($4 == d || $4 == "0") { print $2 "  " $5 }' "$here/MANIFEST" > "$dest/.check"
if ! (cd "$dest" && sha256sum -c .check > .check.out 2>&1); then
    grep -v ': OK$' "$dest/.check.out" >&2 || true
    echo "error: files from disc $disc do not match the MANIFEST (a bad read? clean the disc and run this again)" >&2
    exit 1
fi
awk -F'\t' -v d="$disc" '$1 == "L" && $4 == d { print $5 }' "$here/MANIFEST" | while IFS= read -r p; do
    [ -L "$dest/$p" ] || { echo "error: link $p is missing" >&2; exit 1; }
done
rm -f "$dest/.check" "$dest/.check.out"

# Join the files whose parts are all here.
awk -F'\t' '$1 == "S" { print $2 "\t" $5 "\t" $6 }' "$here/MANIFEST" | while IFS="$tab" read -r sha p n; do
    [ -f "$dest/$p" ] && continue
    i=1; all=yes
    while [ "$i" -le "$n" ]; do
        [ -f "$dest/$p.dkpart.$(printf %03d "$i")" ] || all=no
        i=$((i + 1))
    done
    [ "$all" = yes ] || continue
    echo "    joining $p ($n parts)"
    i=1
    while [ "$i" -le "$n" ]; do
        cat "$dest/$p.dkpart.$(printf %03d "$i")"
        i=$((i + 1))
    done > "$dest/$p.joining"
    if [ "$(sha256sum "$dest/$p.joining" | cut -d' ' -f1)" != "$sha" ]; then
        echo "error: $p does not match the MANIFEST once joined" >&2
        exit 1
    fi
    mv "$dest/$p.joining" "$dest/$p"
    i=1
    while [ "$i" -le "$n" ]; do
        rm -f "$dest/$p.dkpart.$(printf %03d "$i")"
        i=$((i + 1))
    done
done

grep -qx "$disc" "$dest/DISCS-DONE" 2> /dev/null || echo "$disc" >> "$dest/DISCS-DONE"
missing=""
i=1
while [ "$i" -le "$total" ]; do
    grep -qx "$i" "$dest/DISCS-DONE" || missing="$missing $i"
    i=$((i + 1))
done
if [ -n "$missing" ]; then
    echo "==> disc $disc is in. Still to copy:$missing"
    exit 0
fi
echo "==> all $total disc(s) are in: $dest holds the complete set ($set)"
case $kind in
repo)
    echo "    For apk, add this line to /etc/apk/repositories, then run apk update:"
    echo "        $dest/apks/$arch/Packages.adb"
    ;;
source)
    echo "    To rebuild: see $dest/README.txt"
    ;;
esac
