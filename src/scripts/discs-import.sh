#!/bin/sh
# Copy this disc of a dkbuild disc set into DIR and check it against the
# MANIFEST. Run it once for every disc, in any order, with the same DIR:
#
#     sh /media/cdrom/import.sh /srv/fenriros
#
# A newer set of the same repository may be copied into the same DIR: it
# updates it, and its index takes over once all of its discs are in.
#
# The MANIFEST's signature is checked against the keys this machine trusts
# (/etc/apk/keys, or the directory in DKBUILD_TRUSTED_KEYS). The keys on the
# disc itself only show that the disc is undamaged: whoever made it chose them.
# Each file is checked (sha256) as it lands; a file cut across discs is joined
# and checked once all of its parts are in. The script then says which discs
# are still missing. Needs only sh, tar, awk, find and sha256sum (and openssl,
# if installed, to check the signature).
set -eu

die() { echo "error: $*" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
dest=${1:-}
if [ -z "$dest" ]; then
    echo "usage: sh $0 DIR    (an empty directory, or one this set was copied into)" >&2
    exit 2
fi
read -r set disc total kind arch < "$here/DISC"
echo "==> $set: disc $disc of $total ($kind, $arch) -> $dest"
tmp=$(mktemp -d) || die "cannot make a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# The MANIFEST is what every check below trusts: check its signature first.
verifies() { openssl dgst -sha256 -verify "$1" -signature "$here/MANIFEST.sig" "$here/MANIFEST" > /dev/null 2>&1; }
if [ -f "$here/MANIFEST.sig" ]; then
    if command -v openssl > /dev/null 2>&1; then
        trusted=${DKBUILD_TRUSTED_KEYS:-/etc/apk/keys}
        signer=""
        for k in "$trusted"/*.pub; do
            if [ -f "$k" ] && verifies "$k"; then signer=$k; break; fi
        done
        if [ -n "$signer" ]; then
            echo "    MANIFEST signature: good, by a key this machine trusts ($signer)"
        else
            for k in "$here"/keys/*.pub; do
                if verifies "$k"; then signer=$k; break; fi
            done
            [ -n "$signer" ] || die "the MANIFEST's signature does not match the keys on this disc"
            echo "    WARNING: the signature is by a key that is only known from this disc. That shows the disc is"
            echo "    undamaged, not who made it. Compare the key's fingerprint with one you have from its maker:"
            echo "    fingerprint (sha256): $(openssl pkey -pubin -in "$signer" -outform DER | sha256sum | cut -d' ' -f1)"
        fi
    else
        echo "    note: openssl is not installed; the MANIFEST's signature is not checked"
    fi
else
    # repository sets are always signed (the index is)
    [ "$kind" != repo ] || die "this repository set is not signed (no MANIFEST.sig)"
    echo "    WARNING: this set is not signed: nothing shows who made it"
fi

# Nothing may be on the disc that the MANIFEST does not list, and the links it
# lists must point where it says (the files are checked after copying).
awk -F'\t' -v d="$disc" '($1 == "F" || $1 == "P" || $1 == "L") && ($4 == d || $4 == "0") { print $5 }' "$here/MANIFEST" > "$tmp/listed"
(cd "$here/data" && find . ! -type d) | awk '{ sub(/^\.\//, ""); print }' > "$tmp/present"
extra=$(awk 'FILENAME == ARGV[1] { listed[$0] = 1; next } !($0 in listed)' "$tmp/listed" "$tmp/present")
[ -z "$extra" ] || die "the disc holds files its MANIFEST does not list:
$extra"
tab=$(printf '\t')
awk -F'\t' -v d="$disc" '$1 == "L" && $4 == d { print $5 "\t" $6 }' "$here/MANIFEST" > "$tmp/links"
while IFS="$tab" read -r p target; do
    [ -L "$here/data/$p" ] || die "link $p is missing"
    [ "$(readlink "$here/data/$p")" = "$target" ] || die "link $p does not point where the MANIFEST says"
done < "$tmp/links"

# the name of a set without the date and time it was made, and those
set_name() { echo "$1" | awk '{ sub(/-[0-9]+-[0-9]+$/, ""); print }'; }
set_stamp() { echo "$1" | awk '{ n = split($0, a, "-"); print a[n - 1] "-" a[n] }'; }
newer() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a "" > b "") }'; }

mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
if [ -f "$dest/DISC-SET" ]; then
    old=$(cat "$dest/DISC-SET")
    if [ "$old" != "$set" ]; then
        if [ "$kind" = repo ] && [ "$(set_name "$old")" = "$(set_name "$set")" ] \
            && newer "$(set_stamp "$set")" "$(set_stamp "$old")"; then
            echo "    updating $old to $set"
            chmod -R u+w "$dest"
            rm -f "$dest/DISCS-DONE" "$dest/apks/$arch/Packages.adb.next"
            find "$dest" \( -name '*.dkpart.*' -o -name '*.joining' \) -type f -exec rm -f {} +
        else
            die "$dest holds another set ($old); give an empty directory"
        fi
    fi
elif [ -n "$(ls -A "$dest")" ]; then
    die "$dest is not empty and holds no disc set; give an empty directory"
fi
# (writable, for what earlier discs left: Go's module cache has read-only directories)
chmod -R u+w "$dest"
echo "$set" > "$dest/DISC-SET"
cp "$here/MANIFEST" "$here/README.txt" "$here/import.sh" "$dest/"
rm -f "$dest/MANIFEST.sig"
[ ! -f "$here/MANIFEST.sig" ] || cp "$here/MANIFEST.sig" "$dest/"
mkdir -p "$dest/keys"
for k in "$here"/keys/*.pub; do [ ! -f "$k" ] || cp "$k" "$dest/keys/"; done
chmod -R u+w "$dest"

# The index names every package of the set: apk must not see a new one before
# all of them are here. The one in place now is kept until then.
index="$dest/apks/$arch/Packages.adb"
if [ "$kind" = repo ] && [ -f "$index" ]; then cp "$index" "$tmp/index.before"; fi

# Parts of a file that is joined already are not copied again.
awk -F'\t' '$1 == "S" { print $5 }' "$here/MANIFEST" > "$tmp/cut"
skip=""
while IFS= read -r p; do
    if [ -f "$dest/$p" ]; then skip="$skip $p"; fi
done < "$tmp/cut"

echo "    copying"
# (not the "./" entry: the disc's data/ must not give DIR its permissions)
(cd "$here/data" && find . -mindepth 1 -maxdepth 1 > "$tmp/top")
while IFS= read -r top; do
    # directory by directory, each made writable again before the next
    (cd "$here/data" && tar -cf - "$top") | (cd "$dest" && tar -xf -)
    chmod -R u+w "$dest/$top"
done < "$tmp/top"
for p in $skip; do rm -f "$dest/$p".dkpart.*; done

echo "    checking"
awk -F'\t' -v d="$disc" '($1 == "F" || $1 == "P") && ($4 == d || $4 == "0") { print $2 "  " $5 }' "$here/MANIFEST" > "$tmp/sums"
# leave out the parts of files that are joined already
: > "$tmp/check"
while IFS= read -r line; do
    p=${line#*  }
    case $p in
        *.dkpart.*) [ -f "$dest/${p%.dkpart.*}" ] && continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp/check"
done < "$tmp/sums"
if [ -s "$tmp/check" ] && ! (cd "$dest" && sha256sum -c "$tmp/check" > "$tmp/check.out" 2>&1); then
    grep -v ': OK$' "$tmp/check.out" >&2 || true
    # a bad file must not be left to be joined, or to be taken for good
    awk -F': ' '$NF != "OK" && NF > 1 { sub(/: [^:]*$/, ""); print }' "$tmp/check.out" > "$tmp/bad"
    while IFS= read -r p; do [ ! -f "$dest/$p" ] || rm -f "$dest/$p"; done < "$tmp/bad"
    if [ "$kind" = repo ]; then
        rm -f "$index"
        [ ! -f "$tmp/index.before" ] || cp "$tmp/index.before" "$index"
    fi
    die "files from disc $disc do not match the MANIFEST (a bad read? clean the disc and run this again)"
fi

grep -qx "$disc" "$dest/DISCS-DONE" 2> /dev/null || echo "$disc" >> "$dest/DISCS-DONE"

# Join the files whose parts are all here (each part was checked with its disc).
awk -F'\t' '$1 == "S" { print $2 "\t" $5 "\t" $6 }' "$here/MANIFEST" > "$tmp/split"
while IFS="$tab" read -r sha p n; do
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
        rm -f "$dest/$p.joining"
        die "$p does not match the MANIFEST once joined"
    fi
    mv "$dest/$p.joining" "$dest/$p"
    i=1
    while [ "$i" -le "$n" ]; do
        rm -f "$dest/$p.dkpart.$(printf %03d "$i")"
        i=$((i + 1))
    done
done < "$tmp/split"

missing=""
i=1
while [ "$i" -le "$total" ]; do
    grep -qx "$i" "$dest/DISCS-DONE" || missing="$missing $i"
    i=$((i + 1))
done
if [ -n "$missing" ]; then
    if [ "$kind" = repo ]; then
        [ ! -f "$index" ] || mv "$index" "$index.next"
        [ ! -f "$tmp/index.before" ] || cp "$tmp/index.before" "$index"
    fi
    echo "==> disc $disc is in. Still to copy:$missing"
    exit 0
fi
rm -f "$index.next"
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
