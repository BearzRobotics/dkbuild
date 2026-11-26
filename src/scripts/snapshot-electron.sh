#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): Electron and the Chromium it pins, checked
# out with depot_tools' gclient and made into one source tarball, so the build
# needs no network. Runs on the host at fetch time, for a source
#   { url = "snapshot:electron <electron tag> <chromium version> <depot_tools commit>", sha256 = ... }
#
#   $1  the tarball to write (zstd-compressed tar)
#   $2  a work directory (kept between runs: a failed or repeated sync resumes)
#   $3  Electron's tag (v43.8.3)    $4  Chromium's version (150.0.7871.250)
#   $5  the depot_tools commit
#
# What goes in: the gclient checkout with Electron's patches applied; Electron's
# node_modules (yarn, from the yarn release in its tree) and third_party/node's
# (npm ci), installed here since the build is offline; no VCS data; no ELF
# files (prebuilt toolchains and helpers for glibc; the build uses the
# system's). The tarball is reproducible: sorted, fixed times and owners, so
# the same pins give the same sha256.
set -eu
out=$1 work=$2 etag=$3 cver=$4 dtools=$5
name=electron-$etag-$cver
mkdir -p "$work"
cd "$work"
log() { echo "snapshot: $*" >&2; }

if [ ! -d depot_tools/.git ]; then
    log "depot_tools $dtools"
    rm -rf depot_tools
    git init -q depot_tools
    git -C depot_tools fetch -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$dtools"
    git -C depot_tools checkout -q FETCH_HEAD
fi
export PATH="$work/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0 GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
# vpython3 runs the system python3 with this set
export VPYTHON_BYPASS="manually managed python not supported by chrome operations"
export CHROMIUM_BUILDTOOLS_PATH="$work/src/buildtools"

# On a re-run (an interrupted or failed sync), gclient fetches a repository's
# whole history (tens of GB for Chromium) for any revision given as a tag;
# given a commit it already has, it fetches nothing. So: fetch the two tags
# shallowly in the existing checkouts and pin the commits they point to.
src_rev=$cver
e_rev=$etag
if [ -d src/.git ]; then
    log "shallow fetch of tag $cver in src"
    git -C src fetch -q --depth 1 origin "+refs/tags/$cver:refs/tags/$cver" &&
        src_rev=$(git -C src rev-parse "refs/tags/$cver^{commit}") || true
fi
if [ -d src/electron/.git ]; then
    log "shallow fetch of tag $etag in src/electron"
    git -C src/electron fetch -q --depth 1 origin "+refs/tags/$etag:refs/tags/$etag" &&
        e_rev=$(git -C src/electron rev-parse "refs/tags/$etag^{commit}") || true
fi
cat > .gclient <<EOF
solutions = [{
    "name": "src/electron",
    "url": "https://github.com/electron/electron.git@$e_rev",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": { "src": "https://chromium.googlesource.com/chromium/src.git@$src_rev" },
    "custom_vars": {
        "checkout_pgo_profiles": False,
        # no Google Cloud Storage or CIPD downloads: prebuilt tools, sysroots,
        # Node, test data (gsutil also refuses Python 3.14). The build uses
        # the system's toolchain, Node and tools instead.
        "non_git_source": False,
        "llvm_force_head_revision": True,
        "rust_force_head_revision": True,
    },
}]
EOF
log "gclient sync (Electron $etag, Chromium $cver): a large download"
# --ignore-dep-type: no Cloud Storage or CIPD downloads at all (non_git_source
# above covers most; a few test-data entries have no condition)
python3 depot_tools/gclient.py sync --no-history --nohooks --force --reset --ignore-dep-type=gcs --ignore-dep-type=cipd

log "generated version headers"
python3 src/build/util/lastchange.py -m DAWN_COMMIT_HASH -s src/third_party/dawn \
    --revision src/gpu/webgpu/DAWN_VERSION --header src/gpu/webgpu/dawn_commit_hash.h
python3 src/build/util/lastchange.py -m GPU_LISTS_VERSION \
    --revision-id-only --header src/gpu/config/gpu_lists_version.h
python3 src/build/util/lastchange.py -m SKIA_COMMIT_HASH \
    -s src/third_party/skia --header src/skia/ext/skia_commit_hash.h
python3 src/build/util/lastchange.py -o src/build/util/LASTCHANGE
python3 src/build/util/lastchange.py -m LASTCHANGE --revision-id-only -o src/build/util/LASTCHANGE.committime 2>/dev/null || true

log "Electron's patches"
git config --global --get user.email >/dev/null 2>&1 || export GIT_AUTHOR_NAME=dkbuild GIT_AUTHOR_EMAIL=dkbuild@localhost GIT_COMMITTER_NAME=dkbuild GIT_COMMITTER_EMAIL=dkbuild@localhost
python3 src/electron/script/apply_all_patches.py src/electron/patches/config.json

log "Electron's node_modules (yarn)"
yarn=$(ls src/electron/.yarn/releases/yarn-*.cjs | head -n1)
(cd src/electron && node "../../$yarn" install --immutable --mode=skip-build)
log "third_party/node's node_modules (npm ci)"
(cd src/third_party/node && npm ci --ignore-scripts --no-audit --no-fund)

log "packing $name"
rm -rf "$name"
mkdir "$name"
# a copy without VCS data and prebuilt binaries (hard links: no extra space)
cp -al src/. "$name/"
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
    --exclude-backups --exclude='*/testdata/*' --exclude='*/test_data/*' \
    -cf - "$name" | zstd -q -19 --long=27 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
