# dkbuild

The package builder for **FenrirOS**: TOML recipes in, signed **apk** packages and a repository out, built in an
unprivileged namespace sandbox on musl and LLVM. Written in Zig. See `SPEC.md` for the design.

**Full step-by-step guide, with troubleshooting: [`docs/setup-ubuntu.md`](docs/setup-ubuntu.md).**

## Quick start on Ubuntu

FenrirOS does not exist yet, so the first host is Ubuntu (24.04 is the reference). One command installs the
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
| `dkbuild graph <name>...` | prints the build order |
| `dkbuild fetch [name]...` | downloads sources and checks their checksums |
| `dkbuild world [--force] [-P N]` | builds every recipe in the tree that is out of date (`-P N`: up to N builds at once) |
| `dkbuild pkg [--force] <name>...` | builds packages and their in-tree dependencies |
| `dkbuild import-cbuild [--out DIR] <template.py\|dir>...` | converts Chimera cbuild templates into draft recipes (`imported/`) |

## Status

Stage 1 (building on the DKRescue image) works for the twelve recipes in `packages/`; seven of them were imported from Chimera's cports by `import-cbuild` (`pkgconf`, `attr`, `acl`, `libexpat`, `xz`, `lz4`, `zlib-ng-compat`). Not yet built: the LLVM
toolchain and the rest of the base system (SPEC 9), stage 2 (roots filled from `repo/` only, which also catches
forgotten dependencies), images and cross-compiling. The cbuild importer (SPEC 5.9) writes draft recipes with
`TODO(cbuild)` markers; Solus `package.yml` import is planned.
