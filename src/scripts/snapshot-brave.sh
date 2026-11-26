#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): Brave's brave-core at a release tag, with
# what Brave's own checkout (`npm run init`: gclient and its hooks) adds to it
# on Linux, as one source tarball, so the build needs no network. Chromium is
# not in it: the recipe takes Google's release tarball of the Chromium version
# brave-core's package.json pins, and applies Brave's patches to it itself.
# Runs on the host at fetch time, for
#   { url = "snapshot:brave <brave-core tag> <pnpm version>", sha256 = ... }
#
#   $1  the tarball to write (zstd-compressed tar)
#   $2  a work directory (kept between runs: a failed run resumes)
#   $3  brave-core's tag (v1.99.57)
#   $4  the pnpm release to install the JavaScript packages with (11.25.0, the
#       one brave-core's third_party/node/package.json pins)
#
# What goes in:
#   - brave-core at the tag (top directory brave-core-<tag>; the recipe moves
#     it to src/brave);
#   - the repositories its DEPS pins that a Linux build reads, each at its
#     commit, shallow (DEPS is read as data with Python's ast, nothing in it
#     runs): the deps without a condition; left out the Windows/macOS ones
#     (omaha, Sparkle, libdmg-hfsplus) and reclient_configs (Google's remote
#     build service only);
#   - the JavaScript packages: brave-core's (pnpm-lock.yaml) and
#     web-discovery-project's, installed by pnpm with --ignore-scripts (no
#     package's install script runs on the host) and for linux/x64/musl, so
#     that packages with per-platform builds pick the musl ones; and
#     @brave/leo (Brave's design system, a git-hosted package that has to be
#     built: its `prepare` script) as source again in dkbuild-leo/, with the
#     packages it needs to build (leo's own pnpm-lock.yaml). The recipe builds
#     leo, offline, in the build;
#   - what the hooks write that the build reads: LASTCHANGE (brave-core's
#     commit; the recipe puts it in Chromium's build/util) and a stand-in
#     .git/HEAD for web-discovery-project (a GN action lists it as an input).
#     The other hooks (version.gni, licenses, chromium_src/.clang-format) need
#     Chromium's tree and run in the recipe; the ones that download Brave's
#     prebuilt rust toolchain overlay, Node, node_modules (pnpm only), ast-grep
#     and opengrep are not needed: the build uses the system's rust and
#     rust-wasm, nodejs and pnpm.
# No VCS data. Prebuilt executables are left in node_modules (see the recipe
# for which ones the build uses and which it replaces). Reproducible: sorted,
# fixed times and owners, so the same pins give the same sha256 (as long as
# the npm registry and GitHub serve the same files, which pnpm checks against
# the lockfiles' hashes).
set -eu
out=$1 work=$2 tag=$3 pnpmver=$4
name=brave-core-$tag
mkdir -p "$work"
cd "$work"
log() { echo "snapshot: $*" >&2; }

# shallow checkout of one commit (or tag) into a directory
checkout() { # dir url rev
    if [ -f "$1/.dkdone" ]; then return 0; fi
    rm -rf "$1"
    git init -q "$1"
    log "$2 at $3"
    # a few tries: brave-core alone is a large download, which a dropped
    # connection would otherwise fail
    n=0
    until git -C "$1" -c http.version=HTTP/1.1 fetch -q --depth 1 "$2" "$3"; do
        n=$((n + 1))
        [ $n -lt 4 ] || return 1
        log "retrying $2 ($n)"
        sleep 10
    done
    git -C "$1" checkout -q FETCH_HEAD
    touch "$1/.dkdone"
}

checkout src https://github.com/brave/brave-core.git "refs/tags/$tag"

# The DEPS entries a Linux build checks out (use_relative_paths: each is
# relative to brave-core's top directory).
python3 -I - src/DEPS > deps.txt <<'EOF'
import ast, sys
skip = {"third_party/reclient_configs/src"}
tree = ast.parse(open(sys.argv[1]).read())
env = {}
def val(n):
    if isinstance(n, ast.Constant): return n.value
    if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add): return val(n.left) + val(n.right)
    if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "Var": return env["vars"][val(n.args[0])]
    if isinstance(n, ast.Dict): return {val(k): val(v) for k, v in zip(n.keys, n.values)}
    if isinstance(n, ast.List): return [val(e) for e in n.elts]
    if isinstance(n, ast.Name) and n.id in ("True", "False"): return n.id == "True"
    raise ValueError(ast.dump(n))
for st in tree.body:
    if isinstance(st, ast.Assign) and st.targets[0].id in ("vars", "deps"):
        env[st.targets[0].id] = val(st.value)
for p, d in sorted(env["deps"].items()):
    if p in skip: continue
    if isinstance(d, dict):
        c = d.get("condition", "")
        # conditions name Windows/macOS checkouts only so far
        if c and "checkout_linux" not in c: continue
        d = d["url"]
    u, rev = d.rsplit("@", 1)
    print(p, u, rev)
EOF
while read -r p u rev; do
    checkout "src/$p" "$u" "$rev"
done < deps.txt

# LASTCHANGE as Brave's brave_lastchange hook writes it (lastchange.py:
# LASTCHANGE=<commit>-<ref>, and the commit time beside it)
rev=$(git -C src rev-parse HEAD)
printf 'LASTCHANGE=%s-refs/tags/%s\n' "$rev" "$tag" > src/LASTCHANGE.dkbuild
git -C src log -1 --format=%ct HEAD > src/LASTCHANGE.committime.dkbuild

# pnpm itself, the npm package (bundled JavaScript), run with the host's node
if [ ! -f pnpm/package/bin/pnpm.mjs ]; then
    log "pnpm $pnpmver"
    rm -rf pnpm
    mkdir pnpm
    curl -fsSL "https://registry.npmjs.org/pnpm/-/pnpm-$pnpmver.tgz" | tar -xzf - -C pnpm
fi
# --ignore-scripts: nothing from a package runs here. The platform: musl
# x64, whatever the host is. The store and the copies are private to this
# work directory. runtimeOnFail/engine-strict: the host's Node may be older
# than the one the projects ask for; installing runs none of their code.
pnpm_install() { # dir
    log "pnpm install in $1"
    (cd "$1" && node "$work/pnpm/package/bin/pnpm.mjs" install --frozen-lockfile --ignore-scripts \
        --config.runtimeOnFail=ignore --config.engine-strict=false \
        --os=linux --cpu=x64 --libc=musl \
        --config.package-import-method=copy --config.confirmModulesPurge=false \
        --store-dir="$work/pnpm-store" --config.update-notifier=false)
}
[ -f src/.dkdone-pnpm ] || { pnpm_install src; touch src/.dkdone-pnpm; }
[ -f src/vendor/web-discovery-project/.dkdone-pnpm ] || {
    pnpm_install src/vendor/web-discovery-project
    touch src/vendor/web-discovery-project/.dkdone-pnpm
}
# @brave/leo with what it needs to build: pnpm keeps only part of a git-hosted
# package (not its lockfile), so leo's source again, from the tarball and
# with the integrity brave-core's lockfile gives, in src/dkbuild-leo, and its
# own packages (leo's pnpm-lock.yaml, dev dependencies included) installed
# there. The recipe builds it and puts it in the place of the installed copy.
if [ ! -f src/dkbuild-leo/.dkdone-pnpm ]; then
    python3 -I - src/pnpm-lock.yaml > leo.txt <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^  '@brave/leo@(https://codeload\.github\.com/[^']+)':\n    resolution: \{[^}]*integrity: ([^,}]+)", text, re.M)
print(m.group(1), m.group(2))
EOF
    read -r leo_url leo_int < leo.txt
    log "@brave/leo source $leo_url"
    rm -rf src/dkbuild-leo leo.tgz
    curl -fsSL --retry 4 -o leo.tgz "$leo_url"
    got=$(python3 -I -c 'import base64, hashlib, sys; print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' leo.tgz)
    [ "$got" = "$leo_int" ] || { log "@brave/leo: integrity $got, the lockfile says $leo_int"; exit 1; }
    mkdir src/dkbuild-leo
    tar -xzf leo.tgz -C src/dkbuild-leo --strip-components=1
    pnpm_install src/dkbuild-leo
    touch src/dkbuild-leo/.dkdone-pnpm
fi

log "packing $name"
rm -rf "$name"
mkdir "$name"
cp -a src/. "$name/"
find "$name" -name .git -prune -exec rm -rf {} +
find "$name" -name '.dkdone*' -delete
# components/brave_extension's web_discovery_project_resources action lists
# web-discovery-project's .git/HEAD as an input
wdp_rev=$(git -C src/vendor/web-discovery-project rev-parse HEAD)
mkdir -p "$name/vendor/web-discovery-project/.git"
echo "$wdp_rev" > "$name/vendor/web-discovery-project/.git/HEAD"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - "$name" | zstd -q -19 --long=27 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
