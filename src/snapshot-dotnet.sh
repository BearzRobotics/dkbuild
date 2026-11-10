#!/bin/sh
# dkbuild snapshot (SPEC.md 5.3): .NET's source with everything its offline
# "source-only" build needs, for a source
#   { url = "snapshot:dotnet <VMR tag> <musl SDK version>", sha256 = ... }
#
#   $1  the tarball to write (zstd-compressed tar)
#   $2  a work directory (kept between runs)
#   $3  the dotnet/dotnet (VMR) tag, e.g. v10.0.114
#   $4  the version of Microsoft's linux-musl-x64 SDK to start from (the seed)
#
# Upstream's way to source-build for a new platform: prep-source-build.sh
# downloads the previously source-built artifacts and, with --bootstrap-rid,
# replaces their portable packages with the linux-musl-x64 ones (a host SDK
# drives that restore, then is removed). The seed SDK the build runs on is
# Microsoft's musl SDK, as Go, Rust and Java start from a binary. The build
# itself (build.sh --source-only) then needs no network.
set -eu
out=$1 work=$2 tag=$3 seedver=$4
ver=${tag#v}
name=dotnet-$ver
mkdir -p "$work"
cd "$work"
log() { echo "snapshot: $*" >&2; }

if [ ! -d src/.done ]; then
    log "VMR $tag"
    rm -rf src
    curl -fL --retry 4 -o vmr.tar.gz "https://github.com/dotnet/dotnet/archive/refs/tags/$tag.tar.gz"
    mkdir src
    tar -xzf vmr.tar.gz -C src --strip-components=1
    rm -f vmr.tar.gz
    mkdir src/.done
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
mkdir .dotnet-musl
curl -fL --retry 4 -o sdk-musl.tar.gz "https://builds.dotnet.microsoft.com/dotnet/Sdk/$seedver/dotnet-sdk-$seedver-linux-musl-x64.tar.gz"
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
