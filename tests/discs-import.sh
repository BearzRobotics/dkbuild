#!/bin/sh
# src/scripts/discs-import.sh, run on small hand-made discs (no ISO is made): updates, read-only directories,
# signatures, files the MANIFEST does not list, and what a failed or repeated disc leaves behind.
set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=$PWD/src/scripts/discs-import.sh
W=$(mktemp -d) || exit 1
trap 'chmod -R u+w "$W"; rm -rf "$W"' EXIT
fail=0
bad() { echo "FAIL: $1"; fail=1; }
openssl genrsa -out "$W/ours.rsa" 2048 >/dev/null 2>&1 && openssl rsa -in "$W/ours.rsa" -pubout -out "$W/ours.pub" >/dev/null 2>&1
openssl genrsa -out "$W/other.rsa" 2048 >/dev/null 2>&1 && openssl rsa -in "$W/other.rsa" -pubout -out "$W/other.pub" >/dev/null 2>&1
mkdir -p "$W/trusted" && cp "$W/ours.pub" "$W/trusted/"

# disc DIR SET K TOTAL KIND: a disc with an empty data/; then put files in DIR/data and call `seal DIR K [KEY]`
disc() { rm -rf "$1"; mkdir -p "$1/data" "$1/keys"; echo "$2 $3 $4 $5 x86_64" > "$1/DISC"; echo readme > "$1/README.txt"; cp "$SCRIPT" "$1/import.sh"; : > "$1/MANIFEST"; }
list() { # list DIR K PATH...: F lines for files of disc K
    _d=$1 _k=$2; shift 2
    for _p in "$@"; do printf 'F\t%s\t0\t%s\t%s\n' "$(sha256sum "$_d/data/$_p" | cut -d' ' -f1)" "$_k" "$_p" >> "$_d/MANIFEST"; done
}
sign() { openssl dgst -sha256 -sign "$2" -out "$1/MANIFEST.sig" "$1/MANIFEST"; cp "${2%.rsa}.pub" "$1/keys/disc.pub"; }
import() { OUT=$(DKBUILD_TRUSTED_KEYS="$W/trusted" sh "$1/import.sh" "$2" 2>&1); }

repo() { # repo DIR SET CONTENT: a one-disc repository set
    disc "$1" "$2" 1 1 repo; mkdir -p "$1/data/apks/x86_64"
    echo "index $3" > "$1/data/apks/x86_64/Packages.adb"; echo "$3" > "$1/data/apks/x86_64/p-$3.apk"
    list "$1" 0 apks/x86_64/Packages.adb; list "$1" 1 "apks/x86_64/p-$3.apk"; sign "$1" "$W/ours.rsa"
}

# --- updates (ID-05)
repo "$W/v1" fen-repo-20260101-0900 one; repo "$W/v2" fen-repo-20260301-0900 two
import "$W/v1" "$W/dest" || { echo "$OUT"; bad "first import"; }
echo "$OUT" | grep -q 'trusts' || bad "a signature by a trusted key is not said to be one"
import "$W/v2" "$W/dest" || { echo "$OUT"; bad "a newer set of the same repository was refused"; }
grep -q 'index two' "$W/dest/apks/x86_64/Packages.adb" 2>/dev/null || bad "the new index is not in place"
import "$W/v1" "$W/dest" && bad "an older set was copied over a newer one"
repo "$W/vx" other-repo-20260401-0900 x; import "$W/vx" "$W/dest" && bad "another repository's set was copied over this one"
# an update of two discs keeps the old index until both are in
for k in 1 2; do disc "$W/u$k" fen-repo-20260501-0900 "$k" 2 repo; mkdir -p "$W/u$k/data/apks/x86_64"; echo "index three" > "$W/u$k/data/apks/x86_64/Packages.adb"; echo "$k" > "$W/u$k/data/apks/x86_64/q$k.apk"; list "$W/u$k" 0 apks/x86_64/Packages.adb; list "$W/u$k" "$k" "apks/x86_64/q$k.apk"; sign "$W/u$k" "$W/ours.rsa"; done
import "$W/u1" "$W/dest" || { echo "$OUT"; bad "disc 1 of the update"; }
grep -q 'index two' "$W/dest/apks/x86_64/Packages.adb" || bad "the index changed before all discs were in"
import "$W/u2" "$W/dest" || { echo "$OUT"; bad "disc 2 of the update"; }
grep -q 'index three' "$W/dest/apks/x86_64/Packages.adb" || bad "the index did not change when all were in"

# --- read-only directories, as Go's module cache has them (ID-06)
for k in 1 2; do disc "$W/g$k" src-20260101-0900 "$k" 2 source; mkdir -p "$W/g$k/data/mod/m@v1"; echo "$k" > "$W/g$k/data/mod/m@v1/f$k"; list "$W/g$k" "$k" "mod/m@v1/f$k"; chmod 555 "$W/g$k/data/mod/m@v1"; done
import "$W/g1" "$W/gd" || { echo "$OUT"; bad "source disc 1"; }
import "$W/g1" "$W/gd" || { echo "$OUT" | tail -3; bad "the same disc could not be copied again"; }
import "$W/g2" "$W/gd" || { echo "$OUT" | tail -3; bad "the second disc could not add to a read-only directory"; }
echo "$OUT" | grep -qi 'not signed' || bad "an unsigned source set is not said to be unsigned"

# --- signatures and unlisted files (ID-08)
repo "$W/a" a-repo-20260101-0900 a; rm "$W/a/MANIFEST.sig"; import "$W/a" "$W/ad" && bad "an unsigned repository set was imported"
repo "$W/b" a-repo-20260101-0900 b; sign "$W/b" "$W/other.rsa"
import "$W/b" "$W/bd" || { echo "$OUT"; bad "a set signed by a key not known here should import with a warning"; }
echo "$OUT" | grep -q 'fingerprint' || bad "no warning, with the key's fingerprint, for a signature only the disc's own key verifies"
repo "$W/c" a-repo-20260101-0900 c; echo evil > "$W/c/data/apks/x86_64/extra.apk"; import "$W/c" "$W/cd" && bad "a file the MANIFEST does not list was accepted"
[ ! -e "$W/cd/apks/x86_64/extra.apk" ] || bad "the unlisted file was copied"
disc "$W/l" l-20260101-0900 1 1 source; echo t > "$W/l/data/t"; list "$W/l" 1 t; ln -s /etc/passwd "$W/l/data/ln"; printf 'L\t-\t0\t1\tln\tt\n' >> "$W/l/MANIFEST"
import "$W/l" "$W/ld" && bad "a link with another target than listed was accepted"

# --- leftovers (ID-19)
printf 'part-one\n' > "$W/p1"; printf 'part-two\n' > "$W/p2"; cat "$W/p1" "$W/p2" > "$W/whole"
for k in 1 2; do disc "$W/s$k" s-20260101-0900 "$k" 2 source; cp "$W/p$k" "$W/s$k/data/big.dkpart.00$k"
    printf 'S\t%s\t0\t-\tbig\t2\n' "$(sha256sum "$W/whole" | cut -d' ' -f1)" >> "$W/s$k/MANIFEST"
    printf 'P\t%s\t0\t%s\tbig.dkpart.00%s\n' "$(sha256sum "$W/p$k" | cut -d' ' -f1)" "$k" "$k" >> "$W/s$k/MANIFEST"; done
echo damaged > "$W/s1/data/big.dkpart.001"
import "$W/s1" "$W/sd" && bad "a damaged part was accepted"
[ ! -e "$W/sd/big.dkpart.001" ] || bad "the damaged part stayed"
cp "$W/p1" "$W/s1/data/big.dkpart.001"
import "$W/s2" "$W/sd" || { echo "$OUT"; bad "disc 2 after a failed disc 1"; }
import "$W/s1" "$W/sd" || { echo "$OUT"; bad "disc 1 again"; }
cmp -s "$W/whole" "$W/sd/big" || bad "the cut file was not joined"
import "$W/s1" "$W/sd" || { echo "$OUT"; bad "disc 1 a third time"; }
[ -z "$(find "$W/sd" -name 'big.dkpart.*')" ] || bad "parts of an already joined file stayed"
mkdir -p "$W/full" && echo mine > "$W/full/README.txt"
import "$W/s1" "$W/full" && bad "a directory with other things in it was taken over"
[ "$(cat "$W/full/README.txt")" = mine ] || bad "a file of the user's was overwritten"
[ $fail = 0 ] && echo "ok: import.sh updates a repository, handles read-only directories and leftovers, and says what it can vouch for"
exit $fail
