#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): the V8 that Euro-Office's document engine
# (core's doctrenderer) links statically, with the repositories V8's DEPS pins
# that a v8_monolith build reads, and the GN that Euro-Office builds it with,
# in one source tarball, so the build needs no network. Runs on the host at
# fetch time, for
#   { url = "snapshot:euro-office v8 <V8 tag> <GN commit>", sha256 = ... }
#
#   $1  the tarball to write (zstd-compressed tar)
#   $2  a work directory (kept between runs: a failed run resumes)
#   $3  what to snapshot: "v8" (the only kind so far)
#   $4  V8's tag (8.9.45)    $5  the GN commit (from core's
#       Common/3dParty/v8/nc-build.py: Euro-Office builds that old GN, as a
#       current one no longer reads V8 8.9's build files)
#
# What core's Common/3dParty/v8/nc-build.py gets with depot_tools' gclient,
# without gclient: V8 at the tag, then each DEPS entry below at the commit DEPS
# pins (DEPS is read as data with Python's ast, nothing in it runs), shallow.
# Left out: what only V8's tests, Android, Fuchsia, Windows or macOS use, the
# CIPD packages (prebuilt gn, luci-go) and the hooks (they download a clang, a
# sysroot, binutils and clang-format: the build uses the system's). The one file
# a gclient sync writes that the build reads, build/config/gclient_args.gni,
# is written here with DEPS's values. No VCS data. Reproducible: sorted, fixed
# times and owners.
set -eu
out=$1 work=$2 what=$3
log() { echo "snapshot: $*" >&2; }
[ "$what" = v8 ] || { log "unknown euro-office snapshot '$what'"; exit 1; }
tag=$4 gn=$5
name=euro-office-v8-$tag
mkdir -p "$work"
cd "$work"

# shallow checkout of one commit (or tag) into a directory
checkout() { # dir url rev
    if [ -f "$1/.dkdone" ]; then return 0; fi
    rm -rf "$1"
    git init -q "$1"
    log "$2 at $3"
    if ! git -C "$1" fetch -q --depth 1 "$2" "$3"; then
        # a server that refuses to fetch a commit by id: the whole history
        git -C "$1" fetch -q "$2"
    fi
    if git -C "$1" rev-parse -q --verify "$3^{commit}" >/dev/null 2>&1; then
        git -C "$1" checkout -q "$3"
    else
        git -C "$1" checkout -q FETCH_HEAD
    fi
    touch "$1/.dkdone"
}

checkout src/v8 https://chromium.googlesource.com/v8/v8.git "refs/tags/$tag"
checkout src/gn https://gn.googlesource.com/gn "$gn"

# The DEPS entries a v8_monolith build reads (V8's DEPS sets
# use_relative_paths, so each is relative to V8's top directory).
python3 -I - src/v8/DEPS > deps.txt <<'EOF'
import ast, sys
want = ["build", "buildtools", "base/trace_event/common", "third_party/googletest/src",
        "third_party/icu", "third_party/jinja2", "third_party/markupsafe",
        "third_party/zlib", "tools/clang"]
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
for p in want:
    d = env["deps"][p]
    url = d["url"] if isinstance(d, dict) else d
    u, rev = url.rsplit("@", 1)
    print(p, u, rev)
EOF
while read -r path url rev; do
    checkout "src/v8/$path" "$url" "$rev"
done < deps.txt

log "packing $name"
rm -rf "$name"
mkdir "$name"
cp -al src/v8 "$name/v8"
cp -al src/gn "$name/gn"
find "$name" -name .git -prune -exec rm -rf {} +
find "$name" -name .dkdone -delete
# what `gclient sync` writes from DEPS's gclient_gn_args (both False in 8.9)
rm -f "$name/v8/build/config/gclient_args.gni"
printf '# Generated from DEPS (by dkbuild'"'"'s euro-office snapshot)\ncheckout_fuchsia_for_arm64_host = false\ncheckout_google_benchmark = false\n' \
    > "$name/v8/build/config/gclient_args.gni"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - "$name" | zstd -q -19 --long=27 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
