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

```sh
git clone https://github.com/BearzRobotics/dkbuild.git
cd dkbuild
zig build                      # -> zig-out/bin/dkbuild
./zig-out/bin/dkbuild doctor   # checks this machine, prints the fix for anything missing
```

The one dependency, [`toml-zig`](https://github.com/BearzRobotics/toml-zig), is pinned by URL and hash in
`build.zig.zon`, and a copy is committed under `zig-pkg/`.

Then:

```sh
# 1. The build machine: unpack the DKRescue image (1 minute, 4.2 GB). Needs no root.
./zig-out/bin/dkbuild bootstrap-root /path/to/dkrescue.iso

# 2. A signing key for the repository (keep it private and backed up). Kept somewhere else, point to it with
#    --key FILE (pkg, world, prune, discs; docs/setup-ubuntu.md, 8).
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
| `dkbuild discs [--media M] [--key FILE] <file.toml>` | the repository or the sources as ISO images (one for usb, or a set for cd, dvd, bd25, bd50, bd100) |
| `dkbuild prune [--dry-run] [--key FILE]` | removes older versions of packages from repo/ and rebuilds the index |
| `dkbuild outdated [--bump]` | recipes changed since their last build without a new release |
| `dkbuild upstream [--all] [--refresh] [name]...` | which recipes have a newer upstream release (changes nothing) |
| `dkbuild graph <name>...` | prints the build order |
| `dkbuild fetch [name]...` | downloads sources and checks their checksums |
| `dkbuild world [--force] [-P N] [--keep-going] [--no-check] [--key FILE]` | builds every recipe that is out of date (`-P N`: N builds at once) |
| `dkbuild pkg [--force] [--key FILE] <name>...` | builds packages and their in-tree dependencies |
| `dkbuild import-cbuild [--out DIR] <template.py\|dir>...` | converts Chimera cbuild templates into draft recipes (`imported/`) |
| `dkbuild hackage-lock`, `python-lock`, `yarn-lock` | write dependency lock files for the Haskell, Python and yarn stores |

`--tree DIR` (before the command) uses another tree than the current directory.

## Status

As of 2026-11-25, x86_64 only: 3188 recipes in `packages/`; 2809 have their main package built at the recipe's
current version and release, 5 only at an older one, and 374 have none (many were never reached or are blocked by
another that fails). `repo/x86_64` holds 6852 apk files. The base system, LLVM 23, Zig, Rust (from source), Go,
the kernel (7.3), dklilo, dkde, Hyprland, Firefox and many desktop applications are built. Not built yet include
Brave, Electron, Code - OSS, LibreOffice, Thunderbird, Plasma and Kdenlive. The newest live ISO
(`images/dkde-devel.toml`, 2026-11-24) was tested in QEMU with BIOS only; the user reports it booting on real hardware. Installing from
it was not tested. aarch64 and riscv64 are profiles only. Current state: `docs/handoff.md`; plan:
`docs/roadmap.md`; failures: `docs/unbuildable.md`. The cbuild importer (SPEC 5.9) writes draft recipes with
`TODO(cbuild)` markers; there is no Solus `package.yml` importer (dropped: recipes come from Chimera and Alpine).
