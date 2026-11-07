# dkbuild — Specification

> **Name.** `dkbuild` is the final name.

Status: **Draft v0.1**. Anything marked **OPEN** is an undecided question.
Resolve it here before writing code that depends on it.

---

## 1. Vision

The package builder for **FenrirOS**, a general-purpose operating system, in the spirit of Chimera
Linux's `cbuild`, written in Zig, with recipes in a YAML format modelled on
Solus's `package.yml`. It turns a tree of recipes into signed **apk**
packages and repositories, and turns a list of packages into a bootable
system image.

DKRescue was a one-off, hand-rolled distribution built for a specific task.
FenrirOS is not: it's meant to be installed, upgraded and extended. dkbuild
replaces the by-hand build of DKRescue with reproducible recipes, and DKRescue's
build notes are the starting point for them, not part of FenrirOS. Every
lesson from that build
(`LLVM=1`, `--undefined-version`, the musl patches, Meson's
`--wrap-mode=nodownload`) is written down once, in a recipe or a macro,
instead of being repeated in every build block.

Three things make it trustworthy, and this spec exists to enforce them:

1. **Every build runs in a clean, isolated root** that holds only the
   recipe's declared dependencies, with no network. A forgotten dependency
   fails the build instead of working by accident.
2. **Every source is checksummed** in its recipe.
3. **Packages are apk packages,** installed by apk-tools, the package
   manager Chimera Linux uses, so installed systems can be upgraded and
   changed with a mature tool.

## 2. Goals and non-goals

### Goals (v1)

- Build packages from YAML recipes, in dependency order, each in a clean
  sandbox.
- Produce apk v3 packages and signed repository indexes with apk-tools.
- **Several architectures:** `x86_64` first, then `aarch64` and `riscv64`,
  by cross-compiling with LLVM from an `x86_64` host (6).
- Build FenrirOS's whole system from recipes, including the LLVM toolchain,
  dinit and its services, dkde and the desktop stack, and dklilo once it
  exists.
- Assemble a root filesystem from packages, and from it the live ISO (8).
- Run on an 8 GB laptop: job limits per build and per recipe.

### Non-goals (v1)

- A package manager of our own. apk-tools is the package manager.
- Building with GCC. The toolchain is LLVM/Clang, as everywhere in FenrirOS.
- Building recipes from other distributions' formats.
- A binary cache server. Repositories are plain directories, served by any
  web server if wanted.

## 3. Constraints

The FenrirOS constraints (carried over from DKRescue's CONSTRAINTS.md) apply to everything built with this tool. In
particular:

- **No GCC or GNU binutils** in any build root.
- **Verified sources:** a recipe without a checksum for every source does
  not build.
- **Offline builds:** the network is available only in the fetch step,
  never during a build.
- **Baseline CPUs:** each architecture has a baseline (`x86-64`,
  `armv8-a`, `rv64gc`), set by the target profile (6.1), never
  `-march=native`.
- **Static where it matters:** recipes can ask for static linking (5.4), and
  FenrirOS's critical early-boot and recovery packages do.

## 4. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **Zig 0.17.0** | Pinned in `build.zig.zon`, as in dkde and dklilo. |
| Recipe format | **YAML**, a strict subset (5.1) | Our own reader, `src/yaml.zig`. zig-yaml was tried and dropped (14). |
| Packages | **apk-tools v3** (`apk mkpkg`, `apk mkndx`, `apk add`) | The same tool and package format as Chimera. Pinned to an exact version. |
| Sandbox | **Linux namespaces** (user, mount, PID, network, UTS, IPC) | Through `unshare(2)` directly. No bubblewrap. |
| Fetching | Zig's `std.http` | Only in the fetch step. |
| Stripping and ELF scans | **llvm-strip**, **llvm-readelf** or an ELF reader in Zig | From the LLVM toolchain already in every build root. |
| Build | `zig build` | |

apk-tools is C. It's built with Clang like everything else, and it's the
one part not written in Zig, because it's already the package manager the
installed systems use.

## 5. Recipes

### 5.1 Format

One directory per package, in the recipe tree:

```
packages/
  zstd/
    package.yml
  lvm2/
    package.yml
    patches/
      lvm2-2.03.35-musl_stdio-1.patch
  dinit/
    package.yml
    files/
      boot
      rcboot.sh
```

`package.yml` is YAML, limited to: block mappings, block sequences, plain and
quoted scalars, literal block scalars (`|`), and one-line flow sequences of
scalars (`[a, b]`, used for short lists like `builddeps`). No anchors,
aliases, tags, flow mappings, nested flow collections, folded (`>`) or
chomped (`|-`) scalars, tabs in indentation, duplicate keys or multiple
documents. Keys not in 5.2 are an error, not
ignored, so a typo can't silently do nothing.

### 5.2 Fields

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Package name: lowercase letters, digits, `-`, `+`, `.` |
| `version` | yes | Upstream version |
| `release` | yes | Recipe revision, starting at 1; reset when `version` changes |
| `summary` | yes | One line |
| `description` | no | Longer text |
| `license` | yes | SPDX expression |
| `homepage` | no | URL |
| `source` | yes | List of `URL : sha256` entries (5.3) |
| `patches` | no | Files in `patches/`, applied in order with `patch -p1` |
| `archs` | no | Architectures this builds for; default all. `!riscv64` excludes one |
| `hostdeps` | no | Packages run during the build (compilers, meson, perl): installed for the **build machine's** architecture |
| `builddeps` | no | Libraries and headers linked against: installed for the **target** architecture |
| `checkdeps` | no | Extra packages needed only by `check` |
| `rundeps` | no | Runtime dependencies that can't be detected (5.6) |
| `options` | no | List from 5.4 |
| `environment` | no | Shell lines run before every step |
| `setup`, `build`, `check`, `install` | `install` yes | Shell steps, with macros (5.5) |
| `subpackages` | no | 5.7 |

### 5.3 Sources

```yaml
source     :
    - https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz : 0123…cdef
    - git|https://github.com/BearzRobotics/dkde.git : v0.0.3
```

- A tarball entry is `URL : sha256`. The file is downloaded once into the
  source cache, named by its checksum, and the build fails if the checksum
  doesn't match.
- A `git|` entry clones at a tag or commit. A tag is resolved to its commit
  on first fetch and recorded in `package.lock` next to the recipe, so later
  builds use exactly that commit.
- The first tarball is unpacked into the build directory, and the build
  steps start inside its top directory.

### 5.4 Options

| Option | Effect |
|---|---|
| `!check` | Don't run `check` (tests that need hardware or network) |
| `!cross` | Can't be cross-compiled; built only natively (6.3) |
| `!strip` | Don't strip binaries |
| `!lto` | Turn off link-time optimization (when it's on by default) |
| `static` | Link programs statically (rescue-critical tools) |
| `bootstrap` | Part of the bootstrap set (9); built in stage 0 |
| `jobs:N` | At most N parallel jobs for this recipe (LLVM: `jobs:2`) |

### 5.5 Macros

Macros expand to the commands every recipe would otherwise repeat. They
hold the toolchain decisions in one place, per target (6.1).

| Macro | Expands to |
|---|---|
| `%configure` | `./configure` with `--prefix=/usr`, `--sysconfdir=/etc`, `--localstatedir=/var`, `--build`/`--host` for cross, `--disable-static` unless `static` |
| `%make` | `make -j$jobs` with `CC`, `CXX`, `AR`, `NM`, `RANLIB` set to the LLVM tools |
| `%make_install` | `make DESTDIR=$pkgdir install` |
| `%meson` | `meson setup build --prefix=/usr --buildtype=release --wrap-mode=nodownload -Dwerror=false`, plus the target's cross file when cross-compiling |
| `%meson_build`, `%meson_install` | `ninja -C build`, `DESTDIR=$pkgdir ninja -C build install` |
| `%cmake` | `cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release`, plus the target's toolchain file |
| `%cmake_build`, `%cmake_install` | `cmake --build build`, `DESTDIR=$pkgdir cmake --install build --strip` |
| `%zig_build` | `zig build --release=safe --prefix /usr -Dtarget=$zig_target -Dcpu=$zig_cpu` with `--system` for vendored dependencies, `-j$jobs`, and `DESTDIR=$pkgdir` |
| `%kernel_make` | `make LLVM=1 ARCH=$kernel_arch` |

Variables available in every step: `$pkgdir` (the install root), `$srcdir`,
`$jobs`, `$target` (the LLVM triple), `$arch`, `$zig_target`, `$CC`,
`$CXX`, `$CFLAGS`, `$CXXFLAGS`, `$LDFLAGS`.

Default flags for every target include `-O2`, the target's baseline CPU,
and `-Wl,--undefined-version`, because lld rejects version scripts that
name undefined symbols and many packages ship such scripts (zlib and
LVM2 in the DKRescue build).

### 5.6 Dependencies found automatically

After `install`, dkbuild scans `$pkgdir`:

- **ELF files:** each shared library a program needs (`DT_NEEDED`) becomes a
  dependency on `so:<soname>`, and each library the package ships becomes a
  `so:<soname>` provide. Matching across packages is then apk's job.
- **pkg-config files:** each `.pc` provides `pc:<name>`, and each
  `Requires:` becomes a dependency.
- **Commands:** each executable in `/usr/bin` provides `cmd:<name>`.

The scans run per package, after the split (5.7), so a `-devel` package
provides the `pc:` names and the main package the `so:` ones. A dependency
a package satisfies itself is dropped. Provides carry a version, because
apk only chooses a provider automatically for versioned provides: `so:`
names get `=0`, `cmd:` and `pc:` names the package's version. Only 64-bit
little-endian ELF files are read; static executables have no `DT_NEEDED` and
so need nothing.

`rundeps` is only for what can't be seen this way: scripts calling other
programs, data packages, plugins loaded with `dlopen`.

### 5.7 Subpackages

```yaml
subpackages:
    devel:
        summary : Headers and development files
        paths   : [/usr/include, /usr/lib/*.so, /usr/lib/pkgconfig, /usr/share/pkgconfig, /usr/lib/cmake, /usr/share/aclocal]
    static:
        summary : Static libraries
        paths   : [/usr/lib/*.a]
    doc:
        summary : Manual pages and documentation
        paths   : [/usr/share/man, /usr/share/doc, /usr/share/info]
```

`<name>-devel`, `<name>-static` and `<name>-doc` are created **by default**
with the paths above. A recipe lists `subpackages` only to add more or to
change those; one with the same name replaces the default, and declared
subpackages are matched before the defaults. Files are moved, not copied:
each file belongs to exactly one package, the first subpackage whose path
matches it (a path matches a file, or a directory above it; `*` matches
within one path component). A subpackage that gets no files isn't made.
Empty directories are dropped.

Static libraries are a first-class product, not an afterthought: musl makes
fully static programs practical, which is why `-static` is its own package.
`<name>-devel` depends on `<name>` at the same version, and `<name>-static`
depends on `<name>-devel`, so installing the static library brings the
headers it is used with. Keeping headers, static libraries and manuals in
their own packages lets an image leave them out (8).

**Stripping.** After `install`, unless `!strip`, ELF files are stripped
(`llvm-strip --strip-unneeded`) and static archives lose their debug
information (`--strip-debug`).

### 5.8 Example recipes

**Autotools, with a musl patch:**

```yaml
name       : lvm2
version    : 2.03.35
release    : 1
summary    : Logical Volume Manager
license    : GPL-2.0-only AND LGPL-2.1-only
homepage   : https://sourceware.org/lvm2/
source     :
    - https://sourceware.org/pub/lvm2/LVM2.2.03.35.tgz : <sha256>
patches    :
    - lvm2-2.03.35-musl_stdio-1.patch
builddeps  : [libaio, util-linux]
build      : |
    %configure --disable-udev_rules --disable-udev_sync \
               --with-default-locking-dir=/run/lock/lvm
    %make
install    : |
    %make_install
```

**Meson:**

```yaml
name       : seatd
version    : 0.9.1
release    : 1
summary    : Seat management daemon and library
license    : MIT
source     :
    - https://git.sr.ht/~kennylevinsen/seatd/archive/0.9.1.tar.gz : <sha256>
build      : |
    %meson -Dlibseat-builtin=enabled -Dserver=enabled -Dexamples=disabled
    %meson_build
install    : |
    %meson_install
```

**Zig:**

```yaml
name       : dkde
version    : 0.0.3
release    : 1
summary    : A small Wayland desktop shell
license    : MIT
source     :
    - https://github.com/BearzRobotics/dkde/releases/download/v0.0.3/dkde-v0.0.3.tar.gz : <sha256>
hostdeps   : [zig]
builddeps  : [gtk4-devel, gtk4-layer-shell-devel, wayland-devel, harfbuzz-devel]
rundeps    : [labwc, seatd, dbus]
install    : |
    %zig_build
```

## 6. Architectures

### 6.1 Target profiles

Each architecture is a file in `profiles/`, holding everything
architecture-specific so recipes don't have to:

| Field | x86_64 | aarch64 | riscv64 |
|---|---|---|---|
| LLVM triple | `x86_64-chimera-linux-musl` | `aarch64-chimera-linux-musl` | `riscv64-chimera-linux-musl` |
| Baseline CPU | `x86-64` | `armv8-a` | `rv64gc` |
| Zig target and CPU | `x86_64-linux-musl`, `baseline` | `aarch64-linux-musl`, `baseline` | `riscv64-linux-musl`, `baseline_rv64` |
| Kernel `ARCH` | `x86` | `arm64` | `riscv` |
| Boot | **OPEN** (dklilo, when it exists) | **OPEN** (UEFI) | **OPEN** (UEFI or OpenSBI) |

The vendor field is `chimera` for now, because the Chimera toolchain used to
bootstrap builds looks for its compiler runtime under
`x86_64-chimera-linux-musl`; with any other vendor, clang can't find
`crtbeginS.o` and `libclang_rt.builtins`. Once FenrirOS builds its own LLVM
(section 9), the vendor becomes `fenriros`.

From a profile, dkbuild generates the Meson cross file, the CMake
toolchain file and the `configure` `--host` value for a cross build.

**OPEN:** the bootloader for FenrirOS on every architecture. dklilo isn't
implemented yet and is x86-only in its own spec, so nothing is decided; the
x86_64 image can't depend on it until it exists. The kernel's EFI stub can boot directly from UEFI firmware on
both, which may be enough for v1.

### 6.2 Cross-compiling

LLVM is a cross compiler already: one Clang targets every architecture.
A cross build has two roots:

- **The build root**, for the build machine's architecture: `hostdeps`, the
  toolchain, and the tools that run during the build.
- **The sysroot**, for the target architecture, at `/sysroot` inside the
  build root: `builddeps`, installed with `apk add --root /sysroot
  --arch <target>`. Clang is pointed at it with `--sysroot`.

The target's compiler runtime (compiler-rt builtins and CRT objects,
libunwind, libc++) and musl are ordinary packages, built for each target
and installed into the sysroot like any other dependency.

**Zig 0.17's libc detection** asks `cc -print-file-name=crtbeginS.o` and
expects GCC's file names (Codeberg ziglang/zig#36919). The compiler-rt
package provides `crtbegin.o`, `crtbeginS.o`, `crtend.o` and `crtendS.o`
as links to its `clang_rt.*` objects, as the DKRescue toolchain build did,
until Zig fixes this.

### 6.3 Native builds for what won't cross

Some packages can't be cross-compiled (their build runs programs it just
built). They're marked `!cross` and built **natively** in a build root of
the target architecture, run through `qemu-user` registered with
`binfmt_misc`. It's slow, so it's the exception.

**OPEN:** whether `qemu-user` is itself built with dkbuild, and how the
`binfmt_misc` registration is set up on the build machine.

### 6.4 Bootstrapping a new architecture

1. Cross-build the base set (`bootstrap` option) from `x86_64`: musl,
   compiler-rt, libunwind, libc++, LLVM, and enough tools to build the rest.
2. Build the rest of the tree for that architecture, cross where possible
   and natively through `qemu-user` where not.
3. On real hardware of that architecture, rebuild everything natively
   to check the packages are complete.

## 7. A build

For each recipe, in dependency order:

1. **Fetch** (network allowed): download missing sources into the cache and
   check their checksums.
2. **Prepare the build root:** a new directory, with apk-tools installing
   `hostdeps`, the toolchain and the base build set into it, plus the
   sysroot for cross builds (6.2). Nothing from previous builds is reused
   except through packages.
3. **Enter the sandbox** (7.1) and run `setup`, `build`, `check` (unless
   `!check`) and `install`.
4. **Finish:** strip (unless `!strip`), split subpackages (5.7), scan
   dependencies (5.6), and check that `$pkgdir` holds no files outside
   `/usr`, `/etc`, `/var`, `/opt` and `/boot`, and nothing in `/usr/local`.
5. **Package:** `apk mkpkg` for each package, into
   `repo/<arch>/`; then `apk mkndx` updates and signs that architecture's
   index.
6. **Remove the build root** (kept with `--keep-root`, for debugging).

The log of every step goes to `logs/<arch>/<name>-<version>-r<release>.log`.

### 7.1 Sandbox

Every build runs in new **user, mount, PID, network, UTS and IPC
namespaces**:

- **Unprivileged:** a user namespace maps the building user to root inside,
  so dkbuild needs no root on the build machine. Preparing a root is the
  exception: apk-tools runs with `--usermode`, which it refuses as uid 0, so
  that step runs as the building user (in a user namespace, with network),
  and only the build steps run with the root mapping.
- **No network:** the network namespace has only `lo`.
- **Its own `/proc`, `/dev` (a minimal set: `null`, `zero`, `full`,
  `random`, `urandom`, `tty`, `ptmx` with a new `devpts`), `/tmp` and
  `/run`.**
- **When the build ends, the kernel ends every process in it and removes
  every mount.** That's the same reason the DKRescue build's chroot moved to
  namespaces: nothing is left running or mounted.

### 7.2 Rebuilds

Next to each built package dkbuild writes `repo/<arch>/<name>.dkhash`: the
`version-release` it was built as, a hash of the recipe's **own inputs**
(`package.yml`, everything under `patches/` and `files/`, and the
architecture profile), and a hash of the **in-tree packages it was built
against** (its `hostdeps` and `builddeps`, transitively: their names,
versions and own-input hashes). Before building, `dkbuild pkg` compares:

| Same version-release? | Own inputs | Built-against | Result |
|---|---|---|---|
| no, or no package yet | | | build |
| yes | same | same | skip: "up to date" |
| yes | same | changed | rebuild |
| yes | **changed** | | **error:** bump `release` (`--force` overrides) |

The error is the rule that `version` or `release` must change whenever the
package's output changes. A rebuild only because something it builds against
changed is not an error: the recipe didn't change, and the new package keeps
its version, as in a rebuild against a new library.

### 7.3 Build roots and the bootstrap repositories

Until FenrirOS builds its own toolchain (9), the build root is populated from
the Chimera repositories plus `repo/`. The root's `/etc/apk/repositories`
lists `repo/` first, tagged `@dk`, then Chimera's. Every in-tree dependency is
requested as `name@dk=<version>-r<release>`, together with its recipe's main
package, so a same-named package in the Chimera repositories can't be chosen
instead. Anything else a package pulls in (its own runtime dependencies) is
resolved by apk from all repositories.

## 8. Images

```yaml
# images/fenriros.yml
name     : fenriros
arch     : x86_64
packages :
    - base
    - linux
    - bootloader   # OPEN: dklilo when it exists
    - core-utils
    - dkde
exclude  :
    - "*-devel"
    - "*-doc"
users    :
    - name: fenrir
      groups: [wheel, video, render]
      password: locked
services : [udevd, dhcpcd, syslogd, seatd]
output   : [rootfs, squashfs, iso]
```

`dkbuild image images/fenriros.yml`:

1. `apk add --root <rootfs> --arch <arch> --initdb` with the package list
   (and nothing matching `exclude`), from the local repository.
2. Creates the users and enables the services listed.
3. Produces what `output` asks for: the root filesystem as a directory, its
   squashfs, and the live ISO, using the same steps as the DKRescue ISO
   build (initramfs, `mksquashfs`, the bootloader's ISO tooling, `xorriso`).

The ISO output is x86_64-only in v1, and waits on the bootloader decision
(6.1, **OPEN**). The same image list can later feed an installer.

## 9. Bootstrap and the base system

### 9.1 What the base system is

`base` is the smallest FenrirOS that gives a working command line and a
working apk: it boots, you log in on a text console, and `apk add` works. It is
what the DKRescue base-system post builds, without the parts a rescue disc
needed and an installed system doesn't. It has no desktop, no compiler and no
documentation. Three meta-packages describe the sets:

| Meta-package | Holds | Why separate |
|---|---|---|
| `base` | what runs the system (below) | An image installs this and nothing else. |
| `base-devel` | the toolchain and every build tool | A build root is `base-devel` plus a recipe's own dependencies. |
| `base-net` | dhcpcd, OpenSSH | Networking is a choice, not a need (DKRescue's CONSTRAINTS: every service earns its place). |

`base` contains:

- **Kernel and headers:** `linux`, `linux-headers`.
- **C library and runtime:** musl, libatomic-chimera, and compiler-rt's
  runtime pieces that programs need at run time.
- **Libraries the base programs link:** zlib, xz, zstd, bzip2, lz4, ncurses,
  readline, libcap, attr, acl, expat, OpenSSL, and libelf with the musl
  compatibility libraries (argp-standalone, musl-fts, musl-obstack) where
  something needs them.
- **Shells:** dash is `/bin/sh`; bash is the login shell. dksh (experimental)
  is a separate package, `dksh`, not installed by default.
- **Programs to repair a broken system, built static** (`options: [static]`):
  coreutils, findutils, grep, sed, diffutils, tar, gzip, less, which, bash,
  dash, dinit. This is DKRescue's rule: on musl it is cheap and safe, and a damaged
  `/usr/lib` can't take the repair tools with it.
- **System tools:** util-linux, e2fsprogs, kmod, eudev, shadow, kbd,
  procps-ng, psmisc, iproute2, sysklogd.
- **Init:** dinit and its service files (the lfs-dinit collection), and
  `base-files` (the directory layout, `/etc/passwd`, `group`, `os-release`,
  `fstab`, `services` and `protocols` from iana-etc).
- **Package management:** apk-tools.
- **Our own programs:** `dkde-console` (the login console that replaces
  agetty; built alone with `zig build console -Dgui=false`, so it needs only
  libghostty-vt from dkde's Zig dependencies), and dklilo. dkinstaller belongs
  to the live image (8), not to `base`.

`base-devel` contains: LLVM (clang, lld, the LLVM binutils, compiler-rt,
libunwind, libc++abi, libc++), `zig` (the official binary tarball, repackaged),
CMake, Ninja, Meson, Python, Perl, GNU make, m4, gawk, patch, file, pkgconf,
gettext, Bison, Flex, bc, gperf, Autoconf, Automake, Libtool, scdoc and
setuptools. Python and Perl are build tools, not part of `base`.

Every package has a reason to exist, stated in its recipe (a `# needed by:`
comment): nothing joins the tree because DKRescue had it.

### 9.2 Stages

dkbuild needs a build machine with a toolchain and apk. The machine we have is
the **Chimera bootstrap root** (`rootfs/chimera`), and building in it needs no
hand-built stage 0, so the by-hand DKRescue chroot is no longer on the path.

1. **Stage 1:** build `base` and `base-devel` with build roots populated from
   the Chimera repositories plus `repo/` (7.3). Names the recipes use for
   build tools are Chimera's.
2. **Stage 2:** build both again with build roots populated from **`repo/`
   only**: no Chimera repository, and the base build set is `base-devel`. The
   Chimera root still supplies the `apk` binary that populates the roots; it
   never supplies a package.
3. **Compare** the stage 1 and stage 2 packages: file lists, sizes, and the
   scans' `depends` and `provides`. Differences point to a package that
   depends on its build machine in a way it shouldn't. Byte-identical output
   is not required in v1.

After stage 2, nothing in the tree depends on Chimera.

**The vendor field changes at the cut-over.** Stage 1 uses the `chimera` triples
(6.1) because the toolchain that builds it looks for its runtime there. The
LLVM built in stage 1 is configured with `LLVM_HOST_TRIPLE=<arch>-fenriros-linux-musl`,
so stage 2 runs with the profiles' triples switched to `fenriros`. The stage 1
profiles live in `profiles/bootstrap/` and are used with `--bootstrap`.

### 9.3 Build order

Each wave needs only the ones before it.

| Wave | Builds | Notes |
|---|---|---|
| 0 | `linux-headers` | `make LLVM=1 headers_install` |
| 1 | `musl`, `libatomic-chimera`, `llvm` (one build: clang, lld, compiler-rt, libunwind, libc++abi, libc++, shared `libLLVM`), `zig` | `llvm` is the longest build; it uses `jobs:` and `LLVM_PARALLEL_LINK_JOBS` for 8 GB machines. Its pieces become subpackages (5.7). |
| 2 | zlib, bzip2, xz, lz4, zstd, pkgconf, ncurses, readline, libffi, expat, OpenSSL, attr, acl, libcap, elfutils' libelf, argp-standalone, musl-fts, musl-obstack | The libraries everything else links. |
| 3 | m4, make, patch, file, gawk, bc, gperf, Flex, Bison, gettext, Perl, Python, CMake, Ninja, setuptools, Meson, Autoconf, Automake, Libtool, scdoc | Together with wave 1: `base-devel`. |
| 4 | coreutils, findutils, grep, sed, diffutils, tar, gzip, less, which, bash, dash, dksh | Static where 9.1 says so. |
| 5 | util-linux, e2fsprogs, kmod, eudev, shadow, kbd, procps-ng, psmisc, iproute2, sysklogd, dinit, dinit services, `base-files`, `linux` | `linux` takes its configuration from the recipe's `files/`. |
| 6 | apk-tools, dklilo, `dkde-console` | The Zig programs need `zig` (wave 1) and, for `dkde-console`, the Zig dependency fetch (9.4). |
| meta | `base`, `base-devel`, `base-net` | Metapackages: no files, only dependencies. |

The order inside a wave is dkbuild's dependency order, not this table's.

### 9.4 What dkbuild still needs for this

Found by reading the DKRescue posts against what exists:

1. **Stage 2 build roots:** the base build set comes from `base-devel`, and
   `/etc/apk/repositories` lists `repo/` only. Today `build.zig` hard-codes
   Chimera's package names (`base-bootstrap`, `clang`, `gmake`,
   `chimerautils-extra`).
2. **Names across stages:** Chimera calls GNU sed `gsed` because `sed` is BSD
   there; in FenrirOS `sed` is GNU. A recipe that says `gsed` works in stage 1
   and not in stage 2. Needs a `provides` key in recipes, or a per-stage name
   map. **OPEN.**
3. **Zig dependency fetch** for `dkde-console`: `dkbuild fetch` runs
   `zig fetch` while the network is allowed, and the build uses `--system`
   offline (the `zig_build` macro already passes it). Scoped to libghostty-vt
   and what it needs, not the full dkde tree.
4. **Install scripts:** `apk mkpkg --script`, for what `base` needs at
   install time (creating system users and groups, updating `/etc/shells`).
   Recipes need a way to attach them.
5. **Setuid and file modes:** `su`, `passwd` and `sudo` need mode 4755 in the
   package. Packaging runs under the root mapping, so they should carry over,
   but nothing has checked it. Test with shadow.
6. **Directory modes:** the subpackage split recreates moved directories with
   default permissions (5.7); a package whose directory is `0700` loses that.
7. **Tests that need GNU tools:** many `check` steps need GNU coreutils, which
   Chimera's root doesn't have. They can be switched on once wave 4 has built
   them, i.e. in stage 2.
8. **Large builds on 8 GB:** LLVM needs `LLVM_PARALLEL_LINK_JOBS` and the
   `jobs:N` option; the build tool should print a memory warning rather than
   die silently.

### 9.5 Order of work and when B2 is done

1. Waves 0 and 1: the toolchain. This proves the heavy machinery (one big
   build, many subpackages, `zig`) before anything depends on it.
2. Waves 2 and 3: the libraries and build tools. `base-devel` exists.
3. Waves 4 to 6: the programs. `base` exists.
4. Stage 2, and the comparison.

**B2 is done when:** stage 1 and stage 2 of `base` and `base-devel` build on
x86_64; `apk add base` into an empty directory works from `repo/` alone; and
inside a namespace the installed root runs `apk --version`, `sh`, `ls` and
`dinit --version`. Booting it is B3.

## 10. Command line

| Command | Does |
|---|---|
| `dkbuild pkg <name>...` | Builds packages and their missing dependencies |
| `dkbuild pkg --arch aarch64 <name>` | The same, for another architecture |
| `dkbuild world` | Builds every recipe that's out of date |
| `dkbuild fetch [<name>...]` | Only downloads and checks sources |
| `dkbuild check <name>...` | Checks recipes: fields, checksums present, patches exist, no unknown keys |
| `dkbuild graph <name>` | Prints the dependency order |
| `dkbuild image <file>` | Builds an image (8) |
| `dkbuild shell <name>` | Opens a shell in a prepared build root for that recipe |
| `-j N` | Parallel jobs per build (default: the number of CPUs) |
| `--keep-root` | Keeps the build root after the build |

Only one package builds at a time in v1. The jobs go to that one build,
which suits an 8 GB machine better than several builds side by side.
**Post-v1:** several builds at once, with a memory budget.

## 11. Repository layout

The tool and the recipes live in separate repositories, so the tool can
build other distributions too.

**The tool:**

```
build.zig
build.zig.zon
SPEC.md
src/
  main.zig
  yaml.zig     YAML subset reader (5.1)
  recipe.zig   recipe model, validation
  macro/       macro expansion, per-target variables
  profile/     target profiles, cross files, toolchain files
  fetch/
  sandbox/     namespaces, mounts, the minimal /dev
  build/       the steps of 7
  scan/        ELF and pkg-config scans (5.6)
  apk/         running apk mkpkg, mkndx, add
  image/
```

**The recipe tree** (FenrirOS's):

```
packages/<name>/package.yml, patches/, files/
profiles/x86_64.yml, aarch64.yml, riscv64.yml
images/fenriros.yml
keys/             public signing keys (private keys never in the repository)
```

## 12. Testing

- **Unit tests:** the YAML subset reader (and its errors for everything
  outside the subset), recipe validation, macro expansion for each target,
  the generated cross and toolchain files, subpackage splitting, and the
  ELF and pkg-config scans against fixture files.
- **Sandbox tests:** a build can't reach the network, can't see the build
  machine's processes or `/home`, and leaves no mount or process behind.
  (`tests/sandbox.sh`: a probe runs as a build step and checks the sandbox
  from the inside; the same probe must flag the host, or it proves nothing.)
- **End-to-end tests** (`tests/run-all.sh`) use `dkdemo`, a tiny library built
  from a generated tarball through a `file://` source, so they need no
  download and no package in the Chimera repositories can stand in for it.
- **A forgotten dependency fails:** a test recipe that uses zlib without
  declaring it must fail to build.
- **The FenrirOS tree:** `dkbuild world` for `x86_64`, then
  `dkbuild image images/fenriros.yml`, then the ISO boots in QEMU with
  SeaBIOS and OVMF, as in the DKRescue ISO build.
- **Cross:** the base set for `aarch64` builds, and its image boots in
  `qemu-system-aarch64` with UEFI firmware.

## 13. Milestones

### B0 — Recipes

- Recipe reader, validation, macros, profiles, `dkbuild check` and
  `dkbuild graph`.
- **Done when:** every recipe in a test tree validates or fails with a
  clear message, and the generated cross files are correct for all three
  targets.

### B1 — Building natively

- Fetch, sandbox, build steps, subpackages, scans, `apk mkpkg` and
  `apk mkndx`.
- **Done when:** zstd, lvm2 (with its patch) and seatd build into
  installable apk packages on x86_64, and the forgotten-dependency test
  fails as it should.
- **Deferred:** dkde. It needs the `zig` toolchain as a package, its Zig
  dependencies fetched during `dkbuild fetch` (network allowed) and used
  offline with `--system`, and the GTK 4, poppler and Wayland stack, which
  is hundreds of packages in the build root. That belongs with the desktop
  work after the base system builds, not in B1.

### B2 — Bootstrap and the base system

- Section 9: `base`, `base-devel` and `base-net`, built in two stages.
- **Done when:** stage 1 and stage 2 of `base` and `base-devel` build on
  x86_64, and `apk add base` into an empty root works from `repo/` alone
  (9.5). The desktop is a later milestone.

### B3 — Images

- Section 8.
- **Done when:** `dkbuild image images/fenriros.yml` produces an ISO that
  boots in QEMU on BIOS and UEFI, and passes CONSTRAINTS.md's checks.

### B4 — Cross

- Sections 6.2 to 6.4, aarch64 first.
- **Done when:** the aarch64 base set and an aarch64 image build on an
  x86_64 machine, and the image boots in `qemu-system-aarch64`.

### B5 — riscv64

- **Done when:** as B4, for riscv64.

## 14. Open questions

1. ~~The real name.~~ **Decided:** `dkbuild`.
2. ~~YAML.~~ **Decided:** our own reader for the 5.1 subset. zig-yaml was
   vendored first, but it needed patches to build on Zig 0.17.0 and has no
   support for `|` block scalars, which every recipe's build steps use. The
   subset reader is about 300 lines with tests, and rejects everything
   outside the subset by construction.
3. The apk-tools v3 version to pin, and how signing keys are kept and used
   (undecided).
4. Bootloader for all architectures, pending dklilo (6.1). Until then B3 needs a
   stand-in on x86_64.
5. qemu-user and `binfmt_misc` for native builds of other architectures
   (6.3).
6. ~~DKRescue's posts.~~ **Decided:** DKRescue was a one-off. FenrirOS has its
   own documentation; the DKRescue posts stay as history.
7. ~~The base system's contents and stages (9).~~ **Decided:** `/bin/sh` is
   **dash**; bash is the interactive shell; **dksh** is an experimental shell,
   packaged and installable but not the default. GNU userland, as in DKRescue
   (static where 9.1 says). The compiler is **not** in `base`; it is in
   `base-devel`, which build roots and a later "everything included" image
   install. Still open: how a recipe names a build tool that has different
   names in stage 1 and stage 2 (9.4, item 2).
