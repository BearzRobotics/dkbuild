# Setting up dkbuild on Ubuntu

This takes a bare Ubuntu machine (24.04 is the one this was tested against) to a signed apk repository you built
yourself. Nothing here needs root except installing packages and one kernel setting. FenrirOS does not exist yet, so
Ubuntu is the first host.

What you will have at the end: `repo/x86_64/` with `.apk` files and a signed `Packages.adb` index, built from the
recipes in `packages/` inside a sandbox on top of the DKRescue image.

## 1. What the machine needs

| | |
|---|---|
| Disk | about 20 GB free where the project lives (the unpacked image is 4.2 GB, plus sources, build trees, packages) |
| RAM | 8 GB is enough for what is in the tree now; LLVM, later, is what needs it |
| Kernel | Linux 5.11 or newer with user namespaces and overlayfs (every current Ubuntu has both) |
| CPU | x86_64 (the only architecture built so far) |

## 2. Host packages

```sh
sudo apt install ca-certificates curl git tar xz-utils lzip xorriso squashfs-tools util-linux openssl
```

| Package | Why |
|---|---|
| `curl`, `ca-certificates` | downloading sources: the only step that uses the network |
| `tar`, `xz-utils` | source tarballs |
| `xorriso`, `squashfs-tools` | reading the DKRescue ISO and unpacking its root |
| `util-linux` | `unshare`, used by `doctor` and `bootstrap-root` to test namespaces |
| `openssl` | making the repository signing key |
| `git` | cloning this project and `toml-zig` |

## 3. Let Ubuntu run the sandbox

Every build runs in new user, mount, PID, network, UTS and IPC namespaces. **Ubuntu 23.10 and later block
unprivileged user namespaces with AppArmor**, so the sandbox cannot start until you allow them:

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/60-dkbuild.conf
```

The first line takes effect now, the second keeps it after a reboot. (Older Ubuntu does not have this setting; skip
it.) `dkbuild doctor` (step 6) tells you if this is the problem.

## 4. Zig 0.17.1

dkbuild is written in Zig and needs **0.17.1** (not on apt). Either:

```sh
zvm install 0.17.1 && zvm use 0.17.1       # if you use zvm
```

or download the Linux x86_64 tarball from <https://ziglang.org/download/>, unpack it, and put the `zig` binary on
your `PATH`. Check with `zig version`.

## 5. Get the code

dkbuild depends on the `toml-zig` library, which it finds **next to it**, so clone the two side by side:

```sh
mkdir -p ~/de && cd ~/de
git clone https://github.com/BearzRobotics/toml-zig.git
git clone https://github.com/BearzRobotics/dkbuild.git
cd dkbuild
zig build                                  # -> zig-out/bin/dkbuild
```

Both repositories are private: sign in first (`gh auth login`, or use a token or SSH key). If the clone of
`dkbuild` sits anywhere other than next to `toml-zig`, the build fails with a missing `../toml-zig`.

## 6. Check the machine

```sh
./zig-out/bin/dkbuild doctor
```

It checks the programs above, that user namespaces and an overlay file system work for you, free disk space, the
signing key and the build machine. For anything wrong it prints the fix (including the `apt install` line for missing
programs). **Run it until it ends with `ok: this machine can run dkbuild`.** "absent" for the signing key and the
build machine is normal at this point; the next two steps create them.

## 7. The build machine (the DKRescue image)

Builds run on the DKRescue system: its root filesystem is the read-only base that every build sits on. Copy the ISO
to the machine and unpack it (about a minute, 4.2 GB, no root needed):

```sh
./zig-out/bin/dkbuild bootstrap-root /path/to/dkrescue.iso
```

The image these instructions were tested with is 1,187,035,136 bytes with SHA-256
`7991de96eebf20eca6d5d2eaeb3f1283b12ee2f78ac292183700938dbb0b8c3c`; check yours with `sha256sum`. The command also
accepts the ISO's `rootfs.sfs` or a root tarball. It unpacks into `rootfs/dkrescue/` and ends with
`ok: ./rootfs/dkrescue is a usable build machine`, after confirming the toolchain is there and that the root runs
its own `apk` and `clang` from inside a user namespace. `--force` replaces an existing unpack.

## 8. The signing key

Every package and the repository index are signed. The private key never goes in the repository.

**If you already have one** (for example from the machine this was developed on), copy it:

```sh
mkdir -p ~/.config/dkbuild && cp /path/to/signing.rsa ~/.config/dkbuild/ && chmod 600 ~/.config/dkbuild/signing.rsa
```

`keys/dkbuild-signing.rsa.pub` in the repository is the matching public key.

**If you do not**, make one, and replace the public key in `keys/` with its public half:

```sh
mkdir -p ~/.config/dkbuild && openssl genrsa -out ~/.config/dkbuild/signing.rsa 4096
chmod 600 ~/.config/dkbuild/signing.rsa
openssl rsa -in ~/.config/dkbuild/signing.rsa -pubout -out keys/dkbuild-signing.rsa.pub
```

Keep a copy of the private key somewhere safe, off the machine. Without it you cannot sign more packages for
systems that already trust the old one, and every one of them would have to be told to trust a new key. If the
private key and `keys/*.pub` do not match, the index step fails; that is the thing to check first.

## 9. Build the repository

```sh
./zig-out/bin/dkbuild check          # every recipe in packages/ is valid
./zig-out/bin/dkbuild world          # build every recipe that is out of date
ls repo/x86_64/                      # the packages and Packages.adb
```

What to expect: the first run downloads the sources (kept in `cache/`) and builds in dependency order; the 12
packages currently in the tree (35 `.apk` files with their `-devel`, `-doc` and `-static` parts) took about
3 minutes from a clean clone, downloads included, and about 2 once the sources were cached. Each package prints
`built <name>` and where its log is (`logs/x86_64/`). Run it again and it says `up to date` for everything,
because a package is rebuilt only when its recipe, patches, files, the architecture profile or something it
builds against changes. `dkbuild pkg <name>...` builds just those and what they need.

Things that look like errors and are not:

- `note: 'x' is assumed to be in the base image` — a dependency the tree does not build; the DKRescue image has
  it. (Stage 1 does not check this; stage 2 will.)
- `error: <name>: its recipe, patches or files changed but the release is still rN` — you edited a recipe without
  bumping its `release`. Bump it, or pass `--force`. After you change something every recipe depends on, such as
  `profiles/x86_64.toml`, use `dkbuild world --force` once.

## 10. Use the repository

The index is `repo/x86_64/Packages.adb`. On a system that uses apk (DKRescue, or a FenrirOS image later), trust the
key and add the repository:

```sh
cp keys/dkbuild-signing.rsa.pub /etc/apk/keys/
echo /path/to/dkbuild/repo/x86_64/Packages.adb >> /etc/apk/repositories     # a local path
# or serve repo/x86_64/ with any web server and use its URL:
echo http://host/x86_64/Packages.adb >> /etc/apk/repositories
apk update && apk add zstd
```

(A line whose URL ends in `.adb` is an index; see `apk-repositories(5)`.) Packages built by dkbuild have been
unpacked and run with `apk extract` in the tests; installing them into a running system with `apk add` is for stage 2
and the images, which are not built yet.

## 11. The tests

```sh
./tests/run-all.sh
```

Unit tests, the recipe check, then end-to-end scripts that build small test packages in the real sandbox: no
network, no host files visible, nothing left behind; dependency chains; rebuild decisions; installing from the
repository; linking a program against the musl package; the Chimera importer. All should print `ok:` (the
forgotten-dependency one says `skipped`, by design).

## 12. Bringing in a Chimera recipe

Chimera's `cports` tree has recipes for most of the base system. `dkbuild import-cbuild` turns a template into a
draft recipe; it reads the Python as text and never runs it.

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/chimera-linux/cports.git ~/cports
git -C ~/cports sparse-checkout set main/xz
./zig-out/bin/dkbuild import-cbuild --out imported ~/cports/main/xz
```

It writes `imported/xz/package.toml` (and copies `patches/` and `files/`) and prints a report:
`TODO` lines are things a person must finish (each is also left in the recipe as a `# TODO(cbuild): ...` comment),
`dropped` lines are template settings with no equivalent, `check` lines are things to look at. Copy the directory
to `packages/<letter>/`, fix the TODOs, run `dkbuild check`, then `dkbuild pkg <name>`. Dependency names are Chimera's
(`zlib-ng-compat-devel`, `openssl3-devel`) and may need changing. cports is BSD-2-Clause; the draft's header
keeps the attribution.

## 13. Where things are

| Path | What | In git? |
|---|---|---|
| `packages/<letter>/<name>/` | recipes: `package.toml`, `patches/`, `files/` | yes |
| `profiles/` | per-architecture settings | yes |
| `keys/` | public signing key(s) | yes |
| `docs/`, `SPEC.md` | design | yes |
| `rootfs/dkrescue/` | the unpacked build machine (4.2 GB) | no |
| `cache/` | downloaded sources, named by checksum | no |
| `work/` | build trees; removed when each build ends | no |
| `logs/x86_64/` | one log per build | no |
| `repo/x86_64/` | **the repository you built** | no |

To start over: delete `repo/`, `work/`, `logs/` (and `cache/` to download again). Unpack the image again with
`bootstrap-root --force` if `rootfs/dkrescue/` is damaged.

## 14. When something goes wrong

| Symptom | Likely cause and fix |
|---|---|
| `unshare` ... `Operation not permitted`, or `doctor` says BLOCKED | Ubuntu is blocking user namespaces: step 3 |
| `doctor`: overlay `FAILED` | kernel older than 5.11, or `sudo modprobe overlay` |
| `error: rootfs/dkrescue is missing` | step 7 |
| `no signing key` / `signing key ... not found` | step 8 |
| `apk mkndx failed` after a key change | `keys/*.pub` does not match `~/.config/dkbuild/signing.rsa` |
| `download of ... failed: ... 404` | the upstream moved the file; the recipe's URL (or checksum) needs updating |
| `No space left on device` | free 20 GB; also `df -h /tmp` (nothing here uses `/tmp` for big files, but other tools do) |
| `failed to open ../toml-zig` while building dkbuild | clone `toml-zig` next to `dkbuild` (step 5) |

A failed build prints the end of its log; the whole log is in `logs/x86_64/<name>-<version>-r<release>.log`.
`dkbuild pkg --keep-root <name>` keeps the build tree under `work/<name>/` for a look.

## 15. What this does not do yet

- Only **stage 1**: builds run on the DKRescue image, so a dependency a recipe forgot to declare can still build
  (the image has it). Stage 2 will fill build roots from declared packages only and catch that.
- No LLVM, no images, no cross-compiling; only x86_64.
- Recipes can be imported from Chimera (step 12); Solus `package.yml` import is planned.

The design, with the reasoning, is in `SPEC.md` and `docs/decisions/`.

## Moving a build to another machine

Everything the build needs that is not in git:

| What | Where it goes | Notes |
|---|---|---|
| The signing key | `~/.config/dkbuild/signing.rsa` | Private; copy it over a safe channel. Its public half is `keys/dkbuild-signing.rsa.pub` (in git). |
| The DKRescue ISO | anywhere, e.g. `~/dkrescue.iso` | `dkbuild bootstrap-root ~/dkrescue.iso` unpacks it into `rootfs/dkrescue/`. The current build is the one that boots to a desktop on real hardware. |
| `zig` 0.17.1 | on the PATH | Builds dkbuild, and fetches Zig dependencies for recipes with the `zigdeps` option. |
| `lzip` and the other host tools | `apt install` | `dkbuild doctor` lists what is missing. |

Then:

```
git clone https://github.com/BearzRobotics/dkbuild.git && cd dkbuild
zig build
./zig-out/bin/dkbuild doctor
./zig-out/bin/dkbuild bootstrap-root ~/dkrescue.iso
./zig-out/bin/dkbuild world --no-check --keep-going
```

`--keep-going` builds everything that can build and prints which recipes failed and
which were skipped because something they need failed. The first pass takes hours
(LLVM, Zig and the kernel are the long ones); use at least 16 GB of RAM and keep `/tmp`
off a small RAM disk. Recipes that need a manual fix are listed in the failed set.
