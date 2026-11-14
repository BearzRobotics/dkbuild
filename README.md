# dkbuild

The package builder for **FenrirOS**: TOML recipes in, signed **apk** packages and a repository out, built in an
unprivileged namespace sandbox on musl and LLVM. Written in Zig. See `SPEC.md` for the design.

**Full step-by-step guide, with troubleshooting: [`docs/setup-ubuntu.md`](docs/setup-ubuntu.md).**

## Quick start on Ubuntu

FenrirOS builds on a host Linux for now; Ubuntu 24.04 is the reference. (FenrirOS itself boots as live ISOs, but dkbuild's build machine is the unpacked DKRescue image.) One command installs the
host tools:

```sh
sudo apt install ca-certificates curl git tar xz-utils lzip xorriso squashfs-tools util-linux openssl
```

Ubuntu 23.10 and later block unprivileged user namespaces, which the sandbox needs:

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/60-dkbuild.conf
```

**Zig 0.17.1** builds dkbuild (it is not on apt): `zvm install 0.17.1`, or download it from
<https://ziglang.org/download/> and put `zig` on your `PATH`.

dkbuild depends on the sibling `toml-zig` library, so clone the two **side by side**:

```sh
git clone https://github.com/BearzRobotics/toml-zig.git
git clone https://github.com/BearzRobotics/dkbuild.git
cd dkbuild
zig build                      # -> zig-out/bin/dkbuild
./zig-out/bin/dkbuild doctor   # checks this machine, prints the fix for anything missing
```

Then:

```sh
# 1. The build machine: unpack the DKRescue image (1 minute, 4.2 GB). Needs no root.
./zig-out/bin/dkbuild bootstrap-root /path/to/dkrescue.iso

# 2. A signing key for the repository (keep it private and backed up).
mkdir -p ~/.config/dkbuild && openssl genrsa -out ~/.config/dkbuild/signing.rsa 4096
openssl rsa -in ~/.config/dkbuild/signing.rsa -pubout -out keys/dkbuild-signing.rsa.pub

# 3. Build a repository.
./zig-out/bin/dkbuild world        # every recipe in packages/; or: dkbuild pkg zstd xz ...
ls repo/x86_64/                # the .apk files and the signed Packages.adb
```

Builds run on the unpacked DKRescue image (`rootfs/dkrescue`). Sources are downloaded the first time (`cache/`), the logs are in `logs/`, and a package is only rebuilt when its recipe, patches,
profile or a dependency changes. Edit a recipe without bumping its `release` and dkbuild stops and says so.

## Offline, and packages without a server

Builds never use the network: the sandbox has none. `dkbuild fetch` (or the
first build) downloads every source and vendors Go, Rust and Zig dependencies
into `cache/`, named by checksum, and from then on everything rebuilds offline.
Upstream builds that would download things themselves get those as pinned
sources in their recipes instead.

There is no repository server: packages travel on discs. `dkbuild discs` makes a
**repository ISO** set of every package, signed (`images/repo.toml`), that any
FenrirOS machine mounts as an apk repository to install and upgrade from, and a
**source ISO** set of `cache/`, the git tree and the build image
(`images/source.toml`), enough to rebuild the whole distribution offline. The
private signing key goes on neither: keep it encrypted on a drive of its own
(docs/setup-ubuntu.md, 8).

## Tests

```sh
./tests/run-all.sh             # unit tests, recipe check, then every end-to-end script
```

The end-to-end scripts build tiny test packages in the real sandbox: no network, no host files, nothing left behind;
dependency chains; rebuilds; installing from the repository. They run once for each build machine present.

## Commands

| Command | Does |
|---|---|
| `dkbuild doctor` | checks the host and prints the fixes |
| `dkbuild bootstrap-root <iso\|sfs\|tar>` | unpacks the build machine into `rootfs/dkrescue` and checks it |
| `dkbuild check [name]...` | validates recipes |
| `dkbuild image [-v] <file.toml>` | makes an image from repo/: tar, squashfs, directory or a live ISO (BIOS and UEFI); `--verbose` shows each package; see docs/install.md |
| `dkbuild discs [--media M] <file.toml>` | the repository or the sources as ISO images (one for usb, or a set for cd, dvd, bd25, bd50, bd100) |
| `dkbuild prune [--dry-run]` | removes older versions of packages from repo/ and rebuilds the index |
| `dkbuild outdated [--bump]` | recipes changed since their last build without a new release |
| `dkbuild upstream [--all] [--refresh] [name]...` | which recipes have a newer upstream release (changes nothing) |
| `dkbuild graph <name>...` | prints the build order |
| `dkbuild fetch [name]...` | downloads sources and checks their checksums |
| `dkbuild world [--force] [-P N] [--keep-going] [--no-check]` | builds every recipe that is out of date (`-P N`: N builds at once) |
| `dkbuild pkg [--force] <name>...` | builds packages and their in-tree dependencies |
| `dkbuild import-cbuild [--out DIR] <template.py\|dir>...` | converts Chimera cbuild templates into draft recipes (`imported/`) |
| `dkbuild hackage-lock`, `python-lock`, `yarn-lock` | write dependency lock files for the Haskell, Python and yarn stores |

`--tree DIR` (before the command) uses another tree than the current directory.

## Status

About 2300 recipes in `packages/` and about 4850 apks in `repo/x86_64` (approximate, 2026-11-13). LLVM 22, zig, Rust (from
source), the base system, the kernel, dklilo, dkde and Hyprland are built. `dkbuild image` makes three live ISOs (base, rescue, dkde) that boot in QEMU on UEFI
and BIOS; `dkinstaller` is on them. Not done: stage 2 (roots filled from `repo/` only, which also catches forgotten
dependencies), aarch64 and riscv64 (profiles only) and the rest of the world build (see docs/roadmap.md and docs/handoff.md). The cbuild importer (SPEC 5.9) writes draft recipes with
`TODO(cbuild)` markers; a Solus `package.yml` importer does not exist.
