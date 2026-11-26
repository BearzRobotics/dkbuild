#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): the Dart SDK and the repositories its DEPS
# pins, checked out with depot_tools' gclient and made into one source
# tarball, so the build needs no network. Runs on the host at fetch time, for
#   { url = "snapshot:dart <Dart version tag> <depot_tools commit> <SDK commit>", sha256 = ... }
#
#   $1  the tarball to write (zstd-compressed tar)
#   $2  a work directory (kept between runs: a failed or repeated sync resumes)
#   $3  Dart's tag (3.10.3)    $4  the depot_tools commit
#   $5  the commit the tag names
#
# As Alpine's dart snapshot: the checkout for x64 and arm64, then no VCS data
# and no ELF files (prebuilt toolchains, gn, ninja and Dart SDKs for glibc; the
# build uses the system's and the bootstrap Dart). Cloud Storage objects (test
# data) are left out: gsutil refuses Python 3.14. CIPD packages that are not
# binaries (DevTools' web build, ...) stay. Reproducible: sorted, fixed times
# and owners.
set -eu
out=$1 work=$2 tag=$3 dtools=$4
[ $# -ge 5 ] || { echo "snapshot: dart needs <tag> <depot_tools commit> <sdk commit>" >&2; exit 1; }
# the commit the tag names (a tag can be moved): checked before anything of the checkout is used
sdkcommit=$5
name=dart-sdk-$tag
mkdir -p "$work"
cd "$work"
log() { echo "snapshot: $*" >&2; }

# at DIR COMMIT: stop unless the checkout is at exactly that commit
at() {
    _head=$(git -C "$1" rev-parse HEAD)
    [ "$_head" = "$2" ] || { log "$1 is at $_head, pinned $2: refusing it"; exit 1; }
}

if [ "$(git -C depot_tools rev-parse HEAD 2>/dev/null)" != "$dtools" ]; then
    log "depot_tools $dtools"
    rm -rf depot_tools
    git init -q depot_tools
    git -C depot_tools fetch -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$dtools"
    git -C depot_tools checkout -q FETCH_HEAD
fi
export PATH="$work/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0 GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
export VPYTHON_BYPASS="manually managed python not supported by chrome operations"

at depot_tools "$dtools"
# gclient is given the commit: for a tag, a re-run fetches a repository's whole history.
rev=$sdkcommit
cat > .gclient <<EOF
solutions = [{
    "name": "sdk",
    "url": "https://dart.googlesource.com/sdk.git@$rev",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
}]
target_cpu = ["x64", "arm64"]
target_cpu_only = True
EOF
log "gclient sync (Dart $tag): a large download"
python3 depot_tools/gclient.py sync --no-history --nohooks --force --reset --ignore-dep-type=gcs
at sdk "$sdkcommit"

log "packing $name"
rm -rf "$name"
mkdir "$name"
cp -al sdk/. "$name/"
find "$name" -name .git -prune -exec rm -rf {} +
python3 -I -c '
import os, sys
n = 0
for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        p = os.path.join(root, f)
        if os.path.islink(p): continue
        try:
            with open(p, "rb") as h: magic = h.read(4)
        except OSError: continue
        if magic == b"\x7fELF": os.unlink(p); n += 1
print(f"snapshot: removed {n} prebuilt ELF files", file=sys.stderr)
' "$name"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    --exclude-backups --exclude='ChangeLog*' --exclude="$name/buildtools/*/clang" \
    --exclude="$name/third_party/fuchsia/sdk/linux/arch" --exclude='.build-id' \
    -cf - "$name" | zstd -q -19 --long=27 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
