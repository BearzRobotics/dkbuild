#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): .NET's source with everything its offline
# "source-only" build needs, for a source
#   { url = "snapshot:dotnet <VMR tag> <musl SDK version> <VMR commit> <VMR archive sha256> <SDK sha512>", sha256 = ... }
#
# Everything is checked before anything in it runs (the recipe's sha256 of the result can only be checked at the
# end): the VMR archive of that commit against the sha256 given, and the SDK against the sha512 Microsoft's
# release metadata gives for it. What prep-source-build.sh then downloads by itself is not pinned here.
#
#   $1  the tarball to write (zstd-compressed tar)
#   $2  a work directory (kept between runs)
#   $3  the dotnet/dotnet (VMR) tag, e.g. v10.0.114
#   $4  the version of Microsoft's linux-musl-x64 SDK to start from (the seed)
#   $5  the commit the tag names   $6  sha256 of GitHub's archive of that commit
#   $7  sha512 of the SDK archive (releases.json of that .NET version)
#
# Upstream's way to source-build for a new platform: prep-source-build.sh
# downloads the previously source-built artifacts and, with --bootstrap-rid,
# replaces their portable packages with the linux-musl-x64 ones (a host SDK
# drives that restore, then is removed). The seed SDK the build runs on is
# Microsoft's musl SDK, as Go, Rust and Java start from a binary. The build
# itself (build.sh --source-only) then needs no network.
set -eu
out=$1 work=$2 tag=$3 seedver=$4
[ $# -ge 7 ] || { echo "snapshot: dotnet needs <tag> <SDK version> <commit> <archive sha256> <SDK sha512>" >&2; exit 1; }
commit=$5 vmrsum=$6 sdksum=$7
ver=${tag#v}
name=dotnet-$ver
mkdir -p "$work"
cd "$work"
log() { echo "snapshot: $*" >&2; }

# verified FILE SUM TOOL: stop, and remove the file, unless it has that checksum
verified() {
    _got=$("$3" "$1" | cut -d' ' -f1)
    [ "$_got" = "$2" ] || { rm -f "$1"; log "$1: checksum $_got, pinned $2: refusing it"; exit 1; }
}

# a kept work directory counts only if it was made from this archive
if [ "$(cat src/.done/pin 2>/dev/null)" != "$commit $vmrsum" ]; then
    log "VMR $tag ($commit)"
    rm -rf src
    curl -fL --proto =https --proto-redir =https --retry 4 -o vmr.tar.gz "https://github.com/dotnet/dotnet/archive/$commit.tar.gz"
    verified vmr.tar.gz "$vmrsum" sha256sum
    mkdir src
    tar -xzf vmr.tar.gz -C src --strip-components=1
    rm -f vmr.tar.gz
    mkdir src/.done
    echo "$commit $vmrsum" > src/.done/pin
fi
cd src

if [ ! -f prereqs/.bootstrapped ]; then
    log "previously source-built artifacts, with linux-musl-x64 packages (prep-source-build.sh)"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1
    ./prep-source-build.sh --bootstrap-rid linux-musl-x64
    touch prereqs/.bootstrapped
fi

log "the seed: Microsoft's linux-musl-x64 SDK $seedver"
rm -rf .dotnet-musl
curl -fL --proto =https --proto-redir =https --retry 4 -o sdk-musl.tar.gz "https://builds.dotnet.microsoft.com/dotnet/Sdk/$seedver/dotnet-sdk-$seedver-linux-musl-x64.tar.gz"
verified sdk-musl.tar.gz "$sdksum" sha512sum
mkdir .dotnet-musl
tar -xzf sdk-musl.tar.gz -C .dotnet-musl
rm -f sdk-musl.tar.gz

cd ..
log "packing $name"
rm -rf "$name"
mkdir "$name"
cp -al src/. "$name/"
# the glibc SDK that drove the restore, logs and NuGet's caches are not sources
rm -rf "$name/.dotnet" "$name/artifacts" "$name/.done" "$name/.git"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf - "$name" | zstd -q -19 --long=27 -T0 -o "$out.tmp" -f
mv "$out.tmp" "$out"
rm -rf "$name"
log "done: $(sha256sum "$out" | cut -d' ' -f1)"
