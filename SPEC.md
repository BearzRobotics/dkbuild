# dkbuild — Specification

> **Name.** `dkbuild` is the final name.

Status: **Draft v0.1**. Anything marked **OPEN** is an undecided question.
Resolve it here before writing code that depends on it.

---

## 1. Vision

The package builder for **FenrirOS**, a general-purpose operating system, in the spirit of Chimera
Linux's `cbuild`, written in Zig, with recipes in TOML whose fields follow
Solus's `package.yml` and Chimera's templates. It turns a tree of recipes into signed **apk**
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

- Build packages from TOML recipes, in dependency order, each in a clean
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
- Building directly from other distributions' recipe formats. They are
  **converted** to our TOML first (5.9); the build only ever sees TOML.
- A binary cache server. Repositories are plain directories, served by any
  web server if wanted.

## 3. Constraints

The FenrirOS constraints (carried over from DKRescue's CONSTRAINTS.md) apply to everything built with this tool. In
particular:

- **No GCC or GNU binutils** in any build root, unless a recipe explicitly
  opts in (planned: `options = ["gcc"]`, for the few that need it, such as
  GRUB 2; see docs/roadmap.md). LLVM is the toolchain.
- **Verified sources:** a recipe without a checksum for every source does
  not build.
- **Offline builds:** the network is available only in the fetch step,
  never during a build: the sandbox has no network at all. Fetching downloads
  every source, and vendors what a language's package manager would download
  (Zig, Go and Rust dependencies, on the host: 5.4 `zigdeps`, `godeps`,
  `cargodeps`), into `cache/`, named by checksum. Anything an upstream build
  would download for itself (CMake FetchContent, git submodules, prebuilt web
  bundles, toolchains) becomes a pinned, checksummed source of the recipe
  instead (ollama's llama.cpp, Hyprland's glaze). With `cache/` and the stage 0
  build image, the whole distribution rebuilds with no network (8: the source
  ISO).
- **Baseline CPUs:** each architecture has a baseline (`x86-64`,
  `armv8-a`, `rv64gc`), set by the target profile (6.1), never
  `-march=native`.
- **Static where it matters:** recipes can ask for static linking (5.4), and
  FenrirOS's critical early-boot and recovery packages do.

### 3.1 Host requirements

Until FenrirOS exists, dkbuild runs on **Ubuntu** (24.04 is the reference).
Everything below is checked by `dkbuild doctor`, which prints the missing
pieces and the fix. Nothing in a build needs root.

```sh
sudo apt install ca-certificates curl git tar xz-utils xorriso squashfs-tools util-linux openssl
```

| Need | Why |
|---|---|
| `curl`, `ca-certificates` | downloading sources (the only step with network) |
| `tar`, `xz-utils` | source tarballs and root tarballs |
| `xorriso`, `squashfs-tools` | `bootstrap-root` reads the DKRescue ISO's `rootfs.sfs` |
| `util-linux` (`unshare`) | `bootstrap-root` and `doctor` test user namespaces |
| `openssl` | creating the repository signing key |
| `git` | recipes whose source is a git repository |
| Zig 0.17.1 | building dkbuild itself (`zig build`); not on apt, see the README |
| a Linux kernel 5.11 or newer with user namespaces and overlayfs | the sandbox (7.1) |
| about 20 GB free, 8 GB of RAM | the unpacked image is 4.2 GB; LLVM needs the RAM |

**Ubuntu 23.10 and later restrict unprivileged user namespaces** with
AppArmor, and the sandbox cannot start until that is relaxed:

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/60-dkbuild.conf
```

## 4. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **Zig 0.17.0** | Pinned in `build.zig.zon`, as in dkde and dklilo. |
| Recipe format | **TOML** (5.1) | `toml-zig` (TOML 1.1, `std.Io`), a path dependency until it is pinned by hash. YAML survives only as an import format (5.9). |
| Packages | **apk-tools v3** (`apk mkpkg`, `apk mkndx`, `apk add`) | The same tool and package format as Chimera. Pinned to an exact version. |
| Sandbox | **Linux namespaces** (user, mount, PID, network, UTS, IPC) and an overlay root | `src/sandbox.zig`, through the system calls directly. No bubblewrap, no util-linux. |
| Fetching | Zig's `std.http` | Only in the fetch step. |
| Stripping and ELF scans | **llvm-strip**, **llvm-readelf** or an ELF reader in Zig | From the LLVM toolchain already in every build root. |
| Build | `zig build` | |

apk-tools is C. It's built with Clang like everything else, and it's the
one part not written in Zig, because it's already the package manager the
installed systems use.

## 5. Recipes

### 5.1 Format

One directory per package, in the recipe tree, under a directory named by the
package's first letter (`packages/z/zstd/`). `dkbuild check` rejects a recipe
in the wrong place. `patches/` holds every patch the recipe applies and sits
next to `package.toml`:

```
packages/
  z/
    zstd/
      package.toml
  l/
    lvm2/
      package.toml
      patches/
        lvm2-2.03.35-musl_stdio-1.patch
  d/
    dinit/
      package.toml
      files/
        boot
        rcboot.sh
```

`package.toml` is TOML, read with `toml-zig`. Keys not in 5.2 are an error,
not ignored, so a typo can't silently do nothing, and every value must have
the type 5.2 gives it. Two TOML rules matter when writing one:

- **Tables go last.** In TOML every key after a `[table]` header belongs to
  that table, so all top-level keys come first and `[subpackages.*]` tables
  last.
- **Shell steps are multi-line *literal* strings** (`'''`...`'''`). Nothing in them is
  an escape, so `\` line continuations, `$pkgdir` and `%macros` are written
  exactly as the shell sees them. A step can't contain `'''`; one that must
  uses a `"""` string with escapes.

The comment character is `#`. `docs/writing-toml.md` in `toml-zig` is a short
guide to the rest of the syntax.

### 5.2 Fields

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Package name: lowercase letters, digits, `-`, `+`, `.` |
| `version` | yes | Upstream version (always a string: `"2.03.35"` is not a number) |
| `release` | yes | Recipe revision, an integer starting at 1; reset when `version` changes |
| `summary` | yes | One line |
| `description` | no | Longer text |
| `license` | yes | SPDX expression |
| `homepage` | no | URL |
| `source` | no | Array of inline tables, `{ url, sha256 }` or `{ git, tag \| commit }` (5.3). Left out, the recipe's own `files/` are everything (base-files); a `meta` package has none |
| `patches` | no | Files in `patches/`, applied in order with `patch -p1` |
| `archs` | no | Architectures this builds for; default all. `!riscv64` excludes one |
| `hostdeps` | no | Packages run during the build (compilers, meson, perl): installed for the **build machine's** architecture |
| `builddeps` | no | Libraries and headers linked against: installed for the **target** architecture |
| `checkdeps` | no | Extra packages needed only by `check` |
| `rundeps` | no | Runtime dependencies that can't be detected (5.6) |
| `stage0deps` | no | With `selfhost` only: what the build needs instead of its own earlier package while `repo/` has none (the first build) |
| `provides` | no | Names the main package provides besides what the scan finds (5.6), e.g. `so:libgcc_s.so.1` for a link the scanner cannot see through |
| `replaces` | no | Packages whose files the main package may take over (apk `replaces`), for a package that supersedes another |
| `options` | no | List from 5.4 |
| `environment` | no | Shell lines run before every step |
| `setup`, `build`, `check`, `install` | `install` yes (not for `meta`) | Shell steps, with macros (5.5) |
| `subpackages` | no | 5.7 |

### 5.3 Sources

```toml
source = [
    { url = "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz", sha256 = "0123…cdef" },
    { git = "https://github.com/BearzRobotics/dkde.git", tag = "v0.0.3" },
]
```

- A tarball entry is `{ url, sha256 }`. The file is downloaded once into the
  source cache, named by its checksum, and the build fails if the checksum
  doesn't match.
- A `{ git, tag }` or `{ git, commit }` entry clones at that tag or commit. A tag is resolved to its commit
  on first fetch and recorded in `package.lock` next to the recipe, so later
  builds use exactly that commit.
- A `{ url = "snapshot:<kind> <args>", sha256 }` entry is made, not
  downloaded: at fetch time an embedded script (`src/snapshot-<kind>.sh`)
  builds a reproducible tarball on the host from pinned upstream checkouts,
  for sources no release tarball covers. `electron` (Electron tag, Chromium
  version, depot_tools commit) runs gclient, applies Electron's patches and
  installs its yarn and npm packages, so the build itself stays offline. Its
  work directory and log are in `cache/snapshots/`. A new snapshot's checksum
  is unknown until it is made: fetch keeps it under the checksum it has and
  prints it for the recipe. `git` (repository URL, tag or commit) is a shallow
  clone with all its submodules, for projects whose release archives leave
  the submodules out. `scratch-media` (an @scratch/scratch-gui version) downloads the
  media library that version lists, each asset checked against the MD5 it
  is named by, for Scratch Desktop.
- The first tarball is unpacked into the build directory, and the build
  steps start inside its top directory. Further tarballs are unpacked next to
  it (`/build/<their top directory>`): a vendored dependency's source, such as
  the llama.cpp that ollama builds.

### 5.4 Options

| Option | Effect |
|---|---|
| `!check` | Don't run `check` (tests that need hardware or network) |
| `!cross` | Can't be cross-compiled; built only natively (6.3) |
| `!strip` | Don't strip binaries |
| `!lto` | Turn off link-time optimization (when it's on by default) |
| `static` | Link programs statically (rescue-critical tools): adds `-static` to `LDFLAGS`. Never on a recipe that ships a shared library: `-shared -static` links without a warning and gives a library that crashes its users (zstd 1.5.7-r1 crashed lld that way) |
| `bootstrap` | Part of the bootstrap set (9); built in stage 0 |
| `selfhost` | A compiler built with itself (dotnet): the build root also gets the newest package of this recipe in `repo/`, of any version, with that build's declared subpackages (all of them, or the build does not count). With none, the first build uses `stage0deps` (a seed such as a vendor binary and what it needs). Not part of the build-root hash, so a new build does not trigger another |
| `jobs:N` | At most N parallel jobs for this recipe (LLVM: `jobs:10`). Also marks it heavy: with `-P`, it builds alone (10) |
| `zigdeps` | Zig dependencies fetched on the host into the shared `cache/zigpkg/` and laid in the source tree as `zig-pkg/` (7.4) |
| `godeps` | Go modules downloaded on the host (`go mod download`, needs `go`) into the shared module cache `cache/gomod/`; the build gets `GOMODCACHE`, `GOPROXY=off`, `GOFLAGS=-mod=mod` (7.4) |
| `npmdeps` | npm packages of every `package-lock.json` in the recipe's unpacked sources (any of them), fetched into the shared `cache/npm/` (each checked against its lockfile integrity hash); the build installs offline with `npm ci` (7.4) |
| `gradledeps` | Gradle dependencies resolved once per source, in the build root with the network, into the shared Maven-layout `cache/maven/`; then the build runs Gradle offline against it. Needs a `gradle-<version>-bin.zip` source and `unzip` in `hostdeps` (7.4) |
| `nugetdeps` | NuGet packages: the recipe's `restore` step (its `dotnet restore` commands) runs once per source with the network, in the build root, and the packages go into the shared `cache/nuget/` (a local NuGet feed); every build has `$DKBUILD_NUGET` (the store, read-only) and restores with `--source $DKBUILD_NUGET` offline (7.4) |
| `gemdeps` | Ruby gems of every `Gemfile.lock` in the recipe's unpacked sources, fetched into the shared `cache/gems/` (checked against the lockfile's CHECKSUMS, or rubygems.org's sha256), always the ruby-platform gem; laid into `vendor/cache` for `bundle install --local` (7.4) |
| `cargodeps` | Rust crates vendored on the host (`cargo vendor`, needs `cargo`) into the shared `cache/crates/`, laid in as `vendor/` with a `.cargo/config.toml` pointing at it; build with `--offline` (7.4). The Cargo project is the one at the top of the source, or else the first `Cargo.lock` below it; `vendor/` and `.cargo/` stay at the top either way |
| `meta` | A meta-package: no source and no steps, only `rundeps` (`base`, `desktop-hyprland`) |
| `rootlayout` | May install outside `/usr /etc /var /opt /boot` (base-files: `/dev`, `/proc`, the usr-merge links) |

### 5.5 Macros

Macros expand to the commands every recipe would otherwise repeat. They
hold the toolchain decisions in one place, per target (6.1).

| Macro | Expands to |
|---|---|
| `%configure` | `./configure` with `--prefix=/usr`, `--sysconfdir=/etc`, `--localstatedir=/var`, `--build`/`--host` for cross. Shared and static libraries both; the static ones go to `<name>-static` (5.7) |
| `%make` | `make -j$jobs` with `CC`, `CXX`, `AR`, `NM`, `RANLIB` set to the LLVM tools |
| `%make_install` | `make DESTDIR=$pkgdir install` |
| `%meson` | `meson setup build --prefix=/usr --buildtype=release --wrap-mode=nodownload -Dwerror=false -Ddefault_library=both`, plus the target's cross file when cross-compiling. Shared and static libraries both, as `%configure` |
| `%meson_build`, `%meson_install` | `ninja -C build`, `DESTDIR=$pkgdir ninja -C build install` |
| `%cmake` | `cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release`, plus the target's toolchain file. Without the libdir, GNUInstallDirs picks `/usr/lib64` on x86_64, which musl's loader never searches; a package that installs there fails the policy check |
| `%cmake_build`, `%cmake_install` | `cmake --build build`, `DESTDIR=$pkgdir cmake --install build --strip` |
| `%zig_build` | `zig build --release=safe --prefix /usr -Dtarget=$zig_target -Dcpu=$zig_cpu` with `--system` for vendored dependencies, `-j$jobs`, and `DESTDIR=$pkgdir` |
| `%kernel_make` | `make LLVM=1 ARCH=$kernel_arch` |

Progress lines are colored by what they report (built green, failures red,
skips yellow, ...) on a terminal; `--color=always` keeps the colors through a
pipe such as `tee`, `--color=never` or `NO_COLOR` turns them off.

After `pkg` or `world`, `logs/<arch>/last-run.txt` (and a dated copy in
`logs/<arch>/runs/`) lists what failed, each with its build log, what was not
built because its recipe changed without a release bump, and what was skipped
because something it needs failed. With `--keep-going` a recipe changed
without a bump does not stop the run; it is listed there. `dkbuild outdated`
lists those recipes without building anything, and `outdated --bump` raises
their `release`.

Build roots are made in `work/<name>/`, or in `$DKBUILD_FAST_WORK/<name>/`
when that variable is set (a faster disk than the project's): only for recipes
that are not heavy (no `jobs:N`), and only while that file system has 30 GB
free, so a small fast disk is never filled.

Variables available in every step: `$name`, `$version`, `$release` (the
recipe's), `$pkgdir` (the install root), `$srcdir`,
`$jobs`, `$target` (the LLVM triple), `$arch`, `$zig_target`, `$CC`,
`$CXX`, `$CFLAGS`, `$CXXFLAGS`, `$LDFLAGS`.

Default flags for every target include `-O2`, the target's baseline CPU,
and `-Wl,--undefined-version`, because lld rejects version scripts that
name undefined symbols and many packages ship such scripts (zlib and
LVM2 in the DKRescue build).

### 5.6 Dependencies found automatically

After `install`, dkbuild scans `$pkgdir`:

- **ELF files:** each shared library a program needs (`DT_NEEDED`) becomes a
  dependency on `so:<soname>`, and each library the package ships in
  `/usr/lib` becomes a `so:<soname>` provide. Matching across packages is then
  apk's job. A library in a subdirectory (`/usr/lib/ollama`, perl's `CORE/`)
  is private, found through an rpath: it is not provided to other packages, and
  a need it meets is not a dependency (two packages each carrying a private
  ggml must not conflict).
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

```toml
[subpackages.devel]
summary = "Headers and development files"
paths   = ["/usr/include", "/usr/lib/*.so", "/usr/lib/pkgconfig", "/usr/share/pkgconfig", "/usr/lib/cmake", "/usr/share/aclocal"]

[subpackages.static]
summary = "Static libraries"
paths   = ["/usr/lib/*.a"]

[subpackages.doc]
summary = "Manual pages and documentation"
paths   = ["/usr/share/man", "/usr/share/doc", "/usr/share/info"]
```

`<name>-devel`, `<name>-static`, `<name>-doc` and, for a package that also ships programs, `<name>-libs` (its shared libraries: `/usr/lib/*.so.*` and any real `*.so` file) are created **by default**
with the paths above. A recipe lists `subpackages` only to add more or to
change those; one with the same name replaces the default, and declared
subpackages are matched before the defaults. Files are moved, not copied:
each file belongs to exactly one package, the first subpackage whose path
matches it (a path matches a file, or a directory above it; `*` matches
within one path component). A subpackage that gets no files isn't made,
unless it says `empty = true` (a group that only depends on others). A
subpackage can also list `depends` (packages it needs besides what the scan
finds) and `install_if` (apk installs it automatically once all of those are
installed). firmware-linux uses both: `firmware-linux-amdgpu` has
`install_if = ["firmware-linux-gpu"]`, so a system gets either just the
firmware it names, or a whole group. A `*.so` pattern matches only symlinks (the development link), so a real `libfoo-1.2.so` is never taken into `-devel`. A package that is only a library has no `-libs`: its libraries stay in the main package. When `-libs` exists, `-devel` depends on it.
Empty directories are dropped.

Static libraries are a first-class product, not an afterthought: musl makes
fully static programs practical, which is why `-static` is its own package.
The `%configure` and `%meson` macros build shared and static libraries both,
and a recipe turns static ones off only for a stated reason (spirv-tools: its
CMake config would point every user at a `.a` in a package they don't
install). CMake projects mostly build one kind or the other; their recipes
choose.
`<name>-devel` depends on `<name>` at the same version, and `<name>-static`
depends on `<name>-devel`, so installing the static library brings the
headers it is used with. Keeping headers, static libraries and manuals in
their own packages lets an image leave them out (8).

**Stripping.** After `install`, unless `!strip`, ELF files are stripped
(`llvm-strip --strip-unneeded`) and static archives lose their debug
information (`--strip-debug`).

### 5.8 Example recipes

**Autotools, with a musl patch:**

```toml
name      = "lvm2"
version   = "2.03.35"
release   = 1
summary   = "Logical Volume Manager"
license   = "GPL-2.0-only AND LGPL-2.1-only"
homepage  = "https://sourceware.org/lvm2/"
patches   = ["lvm2-2.03.35-musl_stdio-1.patch"]
builddeps = ["libaio", "util-linux"]

source = [
    { url = "https://sourceware.org/pub/lvm2/LVM2.2.03.35.tgz", sha256 = "<sha256>" },
]

build = '''
%configure --disable-udev_rules --disable-udev_sync \
           --with-default-locking-dir=/run/lock/lvm
%make
'''
install = '''
%make_install
'''
```

**Meson:**

```toml
name    = "seatd"
version = "0.9.1"
release = 1
summary = "Seat management daemon and library"
license = "MIT"

source = [
    { url = "https://git.sr.ht/~kennylevinsen/seatd/archive/0.9.1.tar.gz", sha256 = "<sha256>" },
]

build = '''
%meson -Dlibseat-builtin=enabled -Dserver=enabled -Dexamples=disabled
%meson_build
'''
install = '''
%meson_install
'''
```

**Zig:**

```toml
name      = "dkde"
version   = "0.0.3"
release   = 1
summary   = "A small Wayland desktop shell"
license   = "MIT"
hostdeps  = ["zig"]
builddeps = ["gtk4-devel", "gtk4-layer-shell-devel", "wayland-devel", "harfbuzz-devel"]
rundeps   = ["labwc", "seatd", "dbus"]

source = [
    { url = "https://github.com/BearzRobotics/dkde/releases/download/v0.0.3/dkde-v0.0.3.tar.gz", sha256 = "<sha256>" },
]

install = '''
%zig_build
'''
```

### 5.9 Importing recipes from other distributions

dkbuild builds only TOML recipes. Recipes from elsewhere are converted by a
separate step. Design record: `docs/decisions/0002-cbuild-importer.md`.

**Chimera `cbuild` templates (`template.py`) are the main source**
(**implemented**). Chimera is also musl, LLVM and apk, so most packages apply
directly:

```
dkbuild import-cbuild [--out DIR] <template.py | package dir>...
```

writes a **draft** `DIR/<name>/package.toml` (default `imported/`), copies the
template's `patches/` and `files/`, prints a report, and says whether the draft
passes the recipe check. It reads the template as *text* and never runs it.

- **Declarative variables map onto fields** (5.2): `pkgname`, `pkgver`,
  `pkgrel` (+1: cbuild counts from 0), `pkgdesc`, `license`, `url`, `source`
  with `sha256` (paired by position; an f-string over earlier variables such as
  `pkgver` is resolved), `hostmakedepends`, `makedepends`, `checkdepends`,
  `depends`, and the `options` and `archs` we know. `tool_flags` become
  `export` lines in `environment`.
- **`build_style` maps onto the macros of 5.5:** `gnu_configure`, `configure`,
  `meson`, `cmake` and `makefile`, with `configure_args`, `make_build_args`,
  `make_install_args` and `make_check_args`. A `do_build`-style function
  replaces the style's step; `pre_*` and `post_*` hooks go around it.
- **Functions are translated only when trivial:** `self.do(...)` with plain
  string arguments (`make_jobs` -> `$jobs`, `destdir` -> `$pkgdir`), and
  `install_license`, `install_file`, `install_bin`, `install_man`,
  `install_dir` and `uninstall`. **Every other statement stays in the step as
  a `# TODO(cbuild): <the Python line>` comment**, and in the report.
- **Dropped, and reported:** variables with no equivalent (`hardening`,
  `compression`, `renames`, `provides`, ...), options and archs we do not
  know, and cbuild's subpackage classes beyond our defaults.
- **Dependency names are Chimera's** (`zlib-ng-compat-devel`, `openssl3-devel`)
  and are listed for review.
- cports is BSD-2-Clause; every draft names its source template and keeps the
  attribution.

Tried on real cports templates: `zstd` and `dinit` come out almost complete
(one `for` loop and one `with pushd` block left as TODOs); `lvm2` and `curl`
list their service files, a module-level `if`, and a file-rewriting block.
It is a typing aid, not a compiler: a draft with TODOs is not expected to
build.

**Solus `package.yml`** files, read with `yaml-zig`, are the secondary path
(**planned**).

## 6. Architectures

### 6.1 Target profiles

Each architecture is a TOML file in `profiles/` (`<arch>.toml`), holding everything
architecture-specific so recipes don't have to:

| Field | x86_64 | aarch64 | riscv64 |
|---|---|---|---|
| LLVM triple | `x86_64-fenriros-linux-musl` | `aarch64-fenriros-linux-musl` | `riscv64-fenriros-linux-musl` |
| Baseline CPU | `x86-64` | `armv8-a` | `rv64gc` |
| Zig target and CPU | `x86_64-linux-musl`, `baseline` | `aarch64-linux-musl`, `baseline` | `riscv64-linux-musl`, `baseline_rv64` |
| Kernel `ARCH` | `x86` | `arm64` | `riscv` |
| Boot | **OPEN** (dklilo, when it exists) | **OPEN** (UEFI) | **OPEN** (UEFI or OpenSBI) |

The vendor field is `fenriros`. Nothing depends on it: DKRescue's clang builds
and runs programs with any vendor (tested, 9.2), and the target's runtime is
found in LLVM's plain layout. (The Chimera prototype this replaces needed its
own `chimera` vendor, because Chimera's compiler looks for its runtime under
`<arch>-chimera-linux-musl`.)

From a profile, dkbuild generates the Meson cross file, the CMake
toolchain file and the `configure` `--host` value for a cross build.

**Decided for installed UEFI systems: systemd-boot.** It is built from
systemd's source with only the boot manager and `bootctl` (as Chimera does),
so it needs no systemd as init. The EFI system partition is mounted at `/boot`
and holds the kernels; `gen-systemd-boot` writes Boot Loader Specification
entries (normal and recovery) for every `/boot/vmlinuz-*`, and the `linux`
package runs it after each install or upgrade (docs/install.md).
**Still OPEN:** the live ISO (dklilo, x86-only in its own spec) and BIOS
machines.

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

1. **Fetch** (network allowed, the only step that is): download missing
   sources into the cache and check their checksums, and vendor the Zig, Go
   or Rust dependencies of recipes that ask for it (`zigdeps`, `godeps`,
   `cargodeps`), on the host, into the shared stores of 7.4.
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
namespaces** (`src/sandbox.zig`, **implemented**), written against the
system calls directly:

- **Unprivileged:** a user namespace maps the building user to root inside
  (`setgroups` denied, one uid and one gid mapped), so dkbuild needs no root
  on the build machine.
- **The root is an overlay.** The base image (stage 0, 9.2) is the read-only
  lower layer; the build writes to a throwaway upper layer. The unpacked image
  is never modified and is shared by every build. The directories the build
  needs from the host (`/build`, `/destdir`, `/dkbuild`, the repository, the
  keys) are bind mounts, read-only where they can be. `pivot_root` then makes
  the overlay the root and detaches the host's tree.
- **No network:** the network namespace has only `lo`.
- **Its own `/proc`, `/dev`** (a tmpfs with `null`, `zero`, `full`, `random`,
  `urandom` and `tty` bound from the host, and `/dev/shm`), **`/tmp` and
  `/run`.** No `devpts` or `ptmx` yet: mounting `devpts` in a user namespace
  needs the host's `tty` group mapped, and no build has needed a pty.
- **The environment is exactly `PATH` and `HOME`**; nothing leaks from the
  host.
- **When the build ends, the kernel ends every process in it and removes
  every mount.** The sandbox runs in a re-executed copy of dkbuild
  (`sandbox-child`), is killed if dkbuild dies (`PR_SET_PDEATHSIG`), and the
  PID namespace takes every process with its first. Nothing is left running or
  mounted (`tests/sandbox.sh` checks both from outside).

### 7.2 Rebuilds

Next to each built package dkbuild writes `repo/<arch>/<name>.dkhash`:

- `version`: the `version-release` it was built as;
- `inputs`: a hash of the recipe's **own inputs** (`package.toml`, everything
  under `patches/`, `files/` and `scripts/`, and the architecture profile);
- `deps`: a hash of its **build root**: the in-tree packages laid into it from
  `repo/` (`tree.needs`: its `hostdeps` and `builddeps`, and what those need to
  build and run), each by name and by what it produced (`output` for the tools
  it runs, `interface` for what it links against);
- `output`: a hash of what this build **produced**: every path of every
  package it made, with type, permission bits and contents (file data, link
  target). No timestamps or owners, so an identical rebuild hashes the same;
- `interface`: the part of that a package building against it can see (below);
- `script`: the recipe's build script with dkbuild's macros expanded (one job,
  a fixed source directory, so it is the same on every machine). When a macro
  changes (`%configure` started building static libraries), every recipe that
  uses it is rebuilt, and published as the next release only if its package
  came out different, as for a changed build root. A record without it (from
  before it was recorded) is taken as current.

| Same version-release? | Own inputs | Build root | Result |
|---|---|---|---|
| no, or no package yet | | | build |
| yes | **changed** | | **error:** bump `release` (`--force` overrides) |
| yes | same | same outputs | skip: "up to date" |
| yes | same | changed outputs | rebuild; then, if it came out **identical**, keep the package in `repo/` as it is; if **different**, publish it as the next release (dkbuild bumps `release` in the recipe) |

The error is decided before anything builds. The build-root comparison is
made when the package's turn comes, after everything in its build root has
been built in this run (src/sched.zig), because it depends on what those
builds produced.

**Early cutoff.** Because the build root is hashed by outputs, a dependency
that is rebuilt and comes out identical (a new build tool, a comment, a
release bump that changes nothing) stops the cascade: nothing above it is
rebuilt. The build tools of a dependency are not in a package's build root, so
they never count (adding rsync, which linux-headers uses, rebuilds
linux-headers and nothing else). A build that is not reproducible (it embeds a
date or a path) never cuts off; its dependents rebuild, which is what would
have happened anyway. A new linux-headers *version* rebuilds what uses the
headers; above that, only what came out different.

**Interfaces.** The record also holds `interface`: the same hash as
`output`, except that each shared library in `/usr/lib` counts as its soname
and its exported symbols (with sizes for data), not its code. In a build root,
the packages a build *links against* count by interface, and the *tools* it
runs (its `hostdeps`, and what they need) by their whole output, since a
changed compiler changes what it makes. So a fix inside a library's code
rebuilds the library and nothing that links against it; a new export, a
changed header or a new compiler rebuilds the dependents.

**Release bumps.** A package rebuilt because its build root changed is
compared with what its last build produced, before it is published. If it
came out identical (a new build tool, a dependency's change that does not
reach this package's files), nothing is published: the package in `repo/` and
its version stay, and only the record learns the new build root. If it came out
different, apk upgrades installed systems only when the version goes up, so
dkbuild writes the next `release` into the recipe (`release = 3` becomes
`release = 4`), as Alpine and Chimera bump `pkgrel` for a rebuild, publishes
the package as that release, and says so; the bump is committed like any
other change, so the history shows which packages changed and why. The old
package files stay in `repo/` until `dkbuild prune`.

### 7.3 Build roots, stage 0 and `repo/`

Two kinds of build root exist, matching the stages of 9.2:

- **Stage 1 (bootstrap):** the build machine is the **DKRescue image** (9.2),
  not a root assembled by apk. Its root filesystem is the read-only lower
  layer of the build root (7.1); the build writes to a throwaway layer on top.
  It has a complete toolchain but **no apk database**, so there is nothing for
  apk's solver to work with, and the recipe's `hostdeps` and `builddeps` are
  **not installed**: they are whatever DKRescue already provides, and a
  forgotten dependency is *not* caught in stage 1. Packages this tree built
  earlier are laid over the image with `apk extract --force-overwrite`
  (`--keys-dir keys/`: every signature is checked, dependencies are not, and
  files of the image are replaced, which is the point). Those are the packages
  providing the recipe's dependencies and what they need to build and run (their
  own `builddeps` and `rundeps`). *Tried first and dropped:* describing the image
  to apk as one package that provides its `so:`/`cmd:` names, then `apk add`.
  A versioned provide makes a package the only owner of that name, and an
  unversioned one still conflicts with a package that provides it versioned
  (apk-package(5)), so installing our own `pkgconf` over the image's failed.
- **Stage 2 and everything after:** the root is populated by apk from
  `repo/` only: the base build set (`base-devel`) plus the recipe's declared
  dependencies and nothing else. This is where "a forgotten dependency fails
  the build" (section 1) is enforced.

There is no other distribution's repository in either; `repo/` is the only
source of packages.

### 7.4 Dependency stores

Go modules, Rust crates and Zig packages are shared between packages: each is
downloaded once and kept once, however many packages use it.

| Where | What |
|---|---|
| `cache/cargo-home/`, `cache/zig-global/` | cargo's and zig's download caches, so nothing is downloaded twice |
| `cache/crates/<dir>-<hash>/` | one vendored crate: `cargo vendor`'s directory, named by the first 16 hex digits of the sha256 of its `.cargo-checksum.json` (which lists every file's checksum) |
| `cache/zigpkg/<name>/` | one Zig package, under the hash name Zig gives it |
| `cache/gomod/` | Go's module cache (`GOMODCACHE`): the module zips, checked against `go.sum` when downloaded, and their unpacked trees |
| `cache/{cargodeps,zigdeps,godeps}/<sha256>.list` | what one source tarball uses; written last, so its presence means the fetch is complete. `cargodeps/<sha256>.config.toml` is the `.cargo/config.toml` for it |

npm packages (`npmdeps`) are kept in npm's own cache layout,
`cache/npm/content-v2/<algorithm>/<hex>`, named by the integrity hash of
the lockfiles that use them, and `cache/npmdeps/<sha256>.list` lists them.
The fetch reads every `package-lock.json` outside `node_modules` as JSON
(nothing from a package runs), downloads what the store lacks and checks
each tarball against its hash. In the build, `npm-offline.js` (embedded in
dkbuild) gives a private npm cache the store as its content and an index
entry for each tarball URL, as npm's fetcher looks them up; `npm ci` then
installs with `npm_config_offline`, checking every tarball again. Lockfiles
without integrity hashes and yarn are not handled yet. pnpm-lock.yaml (lockfile v9)
files are read too: their packages go into the same store, and the build
serves the store to pnpm as a registry on 127.0.0.1 (`pnpm-registry.js`;
the sandbox's loopback interface is up), so `pnpm install --frozen-lockfile`
works offline.

Gradle (`gradledeps`) has no lockfile to read, so its dependencies are
found by letting Gradle resolve them: the first build of a source runs the
recipe's own Gradle (a `gradle-<version>-bin.zip` source) in its build root,
with the network for that one step, with an init script that resolves every
configuration of every project (`gradle-resolve.gradle`). What Gradle
downloaded is copied into `cache/maven/`, a plain Maven repository
(`<group>/<artifact>/<version>/<file>` with `.sha1` and `.sha256` files;
released versions never change, so it is shared), and
`cache/gradledeps/<sha256>.list` lists it. The build steps get `gradle` on
PATH as a wrapper that always runs `--offline` with `gradle-offline.gradle`,
which replaces every repository of the build and its plugins with the
read-only store. Tested outside dkbuild with Gradle 9.9.0 (a project with
Maven Central and plugin-portal dependencies built offline from the
store); not yet with a recipe, as no JDK is built here yet.

The build binds the stores read-only into the sandbox (`/dkdeps/crates`,
`/dkdeps/zig`, `/dkdeps/go`, `/dkdeps/npm`, `/dkdeps/maven`) and lays `vendor/` and `zig-pkg/` into the source
tree as symbolic links to the entries its list names, so nothing is copied and
no build can change a store. Go reads its module cache directly. Cargo checks
every crate against its `.cargo-checksum.json` as it builds. Which entries a
package uses doesn't feed the rebuild hashes: they follow from the source
tarball (its lock files), whose checksum does.

`dkbuild prune` removes the lists of source tarballs no recipe uses any more
and then every crate and Zig package no remaining list names (Go's module
cache is not pruned yet; `go clean -modcache` empties it). It must not run
while a fetch does. A dependency tarball made by an older dkbuild
(`<sha256>.tar`) is moved into the stores at the next fetch, offline.

## 8. Images

```toml
# images/fenriros.toml
name     = "fenriros"
arch     = "x86_64"
packages = [
    "base",
    "linux",
    "systemd-boot", # UEFI installs (6.1)
    "core-utils",
    "dkde",
]
exclude  = ["*-devel", "*-doc"]
services = ["udevd", "dhcpcd", "syslogd", "seatd"]
output   = ["rootfs", "squashfs", "tar"]

[[users]]
name     = "fenrir"
groups   = ["wheel", "video", "render"]
password = "locked"
```

`dkbuild image images/fenriros.toml` (src/image.zig), in the sandbox on the
build machine, as uid 0 of a user namespace, writing only `out/<name>/`:

1. `apk add --root <rootfs> --arch <arch> --initdb` with the package list
   from the local repository (`repo/<arch>/Packages.adb`, trusting `keys/`).
   No package in the list may match an `exclude` pattern; what they depend on
   is installed whatever its name.
2. Writes `/etc/hostname`, enables the services listed (links in
   `/etc/dinit.d/boot.d`) and creates the users (`useradd -R`). A user's
   `password` is `"locked"` (the default: set it when installing), `"empty"`,
   or a crypt(3) hash.
3. Produces what `output` asks for: `rootfs` (the directory), `tar`
   (`<name>.tar.zst`, root-owned: the way onto a disk, docs/install.md) and
   `squashfs` (`<name>.sfs`). The archives are made inside the sandbox so they
   record root ownership; on the host the files belong to the calling user.

**Not yet:** the `iso` output (initramfs, the live-boot bootloader, `xorriso`),
which waits on the live-ISO bootloader (6.1). The same image list can later
feed an installer.

**Planned: package and source ISOs.** With no repository server, packages
travel on discs. `iso_repo` will put packages on an ISO, as `apks/<arch>/`
with the signed `Packages.adb` and the public key, the way Alpine's install
media carry theirs: a list of packages, so the install ISO works offline, or
`"all"` for a **repository ISO** of every package. A machine mounts it and
adds `<mount>/apks/<arch>/Packages.adb` to `/etc/apk/repositories` (tagged,
`@cdrom ...`, to use it only on request); a newer disc and `apk upgrade`
update it, and rebuilt packages are seen because rebuilds bump the release
(7.2). It also restores any installed system. A **source ISO** carries
`cache/` (every source tarball and vendored dependency), the git tree at that
point and the stage 0 build image: enough to rebuild the whole distribution
offline, even after upstream downloads disappear. **The private signing key is
on neither**; it is backed up separately, encrypted and offline.

Meta-packages (`options = ["meta"]`) keep image lists short: `base` (boots to
a login prompt with apk working), `base-net` (dhcpcd, OpenSSH, curl) and
`desktop-hyprland`.

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
- **Shells:** dash is `/bin/sh` (scripts, and the fallback); bash is every
  user's login shell, root's too (`/etc/default/useradd`, `dkbuild image`),
  with bash-completion. dksh (experimental) is a separate package, `dksh`, not
  installed by default.
- **Editors:** msedit (the default `EDITOR`/`VISUAL`, set in `/etc/profile`)
  and vim. A user picks their own in `~/.profile`.
- **The user's environment:** `/etc/profile` (PATH, umask 022, `PAGER=less`,
  `LESS=-R`, `EDITOR`, then `/usr/lib/profile.d` and `/etc/profile.d`) for
  login shells; `/etc/shrc` (aliases with color, the prompt) for every
  interactive shell, read by dash through `$ENV` and by bash through
  `~/.bashrc`. `/etc/skel` has `.profile` (`~/.local/bin` first on PATH),
  `.shrc`, `.bashrc`, `.bash_profile` and `~/.local/bin`.
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
libunwind, libc++abi, libc++), `zig` (a build-time system Zig, see below),
CMake, Ninja, Meson, Python, Perl, GNU make, m4, gawk, patch, file, pkgconf,
gettext, Bison, Flex, bc, gperf, Autoconf, Automake, Libtool, scdoc and
setuptools. Python and Perl are build tools, not part of `base`.

**The `zig` package** is there to build the repository's Zig programs, as
Debian ships a Rust only to build its own packages. It is not a recommendation
for writing Zig: the language still changes between releases, so users are
pointed to zvm, anyzig and similar tools, and the package's README says so.
Its version follows what the Zig packages need (dklilo 0.0.3 requires 0.17.1,
so the image's 0.17.0 is too old). Today the recipe repackages the official
x86_64 binary (`/usr/lib/zig`, `/usr/bin/zig` symlink). **OPEN:** build it
from source once `llvm` exists in the tree (wave 1); the name stays `zig`.

Every package has a reason to exist, stated in its recipe (a `# needed by:`
comment): nothing joins the tree because DKRescue had it.

### 9.2 Stages

dkbuild needs a build machine with a toolchain and apk. That machine is
**stage 0: the DKRescue image**, the hand-built system documented in the
DKRescue posts (`dkrescue.iso`, sha256 `b3929359…ea72`, the build that boots to a desktop on real hardware). Its `/live/rootfs.sfs` already has
LLVM 23 and compiler-rt, musl, Zig, Python, Perl, GNU make, CMake, Ninja,
Meson, bash, dinit, git, scdoc, `unshare`, `pivot_root` and apk-tools, which
is the list in the "build host" post. No hand-built stage 0 is left to do, and
no other distribution's packages are needed.

`dkbuild bootstrap-root <image>` (**implemented**) unpacks the image's root
filesystem into `rootfs/dkrescue/`, without privileges. It accepts the ISO
(reading `/live/rootfs.sfs` with `xorriso`), the squashfs itself (with
`unsquashfs`), or a root tarball (`dkrescue-bootstrap.tar.xz`), and tells them
apart by their magic bytes, not their names. The host needs `xorriso` (ISO
only), `unsquashfs` or `tar`, and `unshare`. Unpacking the 1.2 GB ISO took
about a minute and 4.2 GB of disk. Files end up owned by the current user,
which a user namespace that maps that user to root shows as root; device
nodes, setuid bits and file capabilities are not kept, and builds don't need
them. It then checks that `apk`, `clang`, `ld.lld`, `llvm-ar`, `make`, `sh`,
`sed`, `tar` and `xz` are present (a tool may be a symlink with an absolute
target, such as `zig -> /opt/zig-0.17.0/zig`, so links are not followed),
and that the root runs its own `apk` and `clang` from inside a user namespace
(`unshare --user --map-root-user chroot`). The private signing key never comes from the image: the
ISO is built without `home/builder` and `srv/dkbuild`.

1. **Stage 1:** build `base` and `base-devel` inside stage 0, as 7.3
   describes: DKRescue's root is the lower layer, `repo/` supplies the
   in-tree packages built so far.
2. **Stage 2:** build both again with build roots populated from **`repo/`
   only**, and the base build set is `base-devel`. The stage 0 root still
   supplies the `apk` binary that populates the roots; it never supplies a
   package.
3. **Compare** the stage 1 and stage 2 packages: file lists, sizes, and the
   scans' `depends` and `provides`. Differences point to a package that
   depends on its build machine in a way it shouldn't. Byte-identical output
   is not required in v1.

After stage 2, nothing in the tree depends on DKRescue.

**The vendor field.** The profiles' triples say `fenriros` from the start.
DKRescue's LLVM installs its runtime in the plain layout
(`usr/lib/clang/23/lib/linux/`, `libclang_rt.builtins-x86_64.a`), not under a
per-triple directory, so the vendor does not matter. **Tested** (clang 23.1.4
from the image, unprivileged user namespace): a C program built with
`--target=x86_64-fenriros-linux-musl`, with `x86_64-chimera-linux-musl` and
with `x86_64-dkrescue-linux-musl` (the image's own default) links with lld and
runs, dynamically and with `-static`. `profiles/bootstrap/` is not needed.

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

1. **Stage 2 build roots.** Stage 1 is implemented: the DKRescue root is the
   lower layer of an overlay mounted inside the user namespace (7.1, 7.3; it
   works unprivileged on Linux 5.11 and newer, and `dkbuild doctor` checks
   it). Stage 2 must populate the root from `base-devel` and `repo/` only, with
   `/etc/apk/repositories` listing `repo/` alone.
2. **Names across stages:** the recipes now say `sed`, the name in both
   DKRescue and FenrirOS (Chimera's was `gsed`, because its `sed` is BSD), and
   the `gsed` workarounds in `linux-headers` and `lvm2` are gone. If a build
   tool ever has different names in stage 1 and stage 2, a recipe needs a
   `provides` key or a per-stage name map. **OPEN**, but no recipe needs it.
3. **Zig dependency fetch** for `dkde-console`: `dkbuild fetch` runs
   `zig fetch` while the network is allowed, and the build uses `--system`
   offline (the `zig_build` macro already passes it). Scoped to libghostty-vt
   and what it needs, not the full dkde tree.
4. ~~**Install scripts.**~~ **Implemented:** a file named after an apk script
   type (`pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`,
   `pre-deinstall`, `post-deinstall`, `trigger`) in the recipe's `scripts/`
   directory is attached to the main package with `apk mkpkg --script`. They
   run inside the target root, so they use only what `base` provides. Tested
   with `tests/scripts.sh`.
5. **Setuid and file modes:** `su`, `passwd` and `sudo` need mode 4755 in the
   package. Packaging runs under the root mapping, so they should carry over,
   but nothing has checked it. Test with shadow.
6. **Directory modes:** the subpackage split recreates moved directories with
   default permissions (5.7); a package whose directory is `0700` loses that.
7. **Tests that need GNU tools:** many `check` steps need GNU coreutils.
   DKRescue's root has them (static), so stage 1 can already run those
   checks and the `!check` workarounds added for Chimera's BSD tools (zstd's
   `stat -c`) can go. Verify against DKRescue before removing them.
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
| `dkbuild doctor` | Checks the host (programs, namespaces, overlayfs, disk, key) and prints the fixes (3.1) |
| `dkbuild image <file>` | Builds an image (8) |
| `dkbuild bootstrap-root [--force] [--dest DIR] <image>` | Unpacks the stage 0 build machine and checks it (9.2) |
| `dkbuild prune [--dry-run]` | Removes packages from `repo/` that their recipe no longer builds (older versions, dropped subpackages), once the recipe's present version is built, and rebuilds the index. Packages no recipe provides are reported, not removed |
| `dkbuild shell <name>` | Opens a shell in a prepared build root for that recipe |
| `-j N` | Parallel jobs per build (default: the number of CPUs) |
| `-P N` | Builds at once (default 1) |
| `--keep-root` | Keeps the build root after the build |

One package builds at a time unless `-P N` asks for more; one at a time
suits an 8 GB machine better than several builds side by side. With `-P N`
(src/sched.zig), a build starts once every in-tree package its build root
unpacks from repo/ is built, each build gets the full `-j`, and a recipe with
`jobs:N` (the large ones: LLVM, Zig) runs alone. New packages are written
under a temporary name and renamed into place, and one build at a time rebuilds
the index, so no build sees half a package or half an index. Every rebuild
decision (7.2) is made before the first build starts. **Later:** a real memory
budget instead of "heavy builds run alone".

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
  recipe.zig   recipe model, validation (reads TOML with toml-zig)
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
packages/<letter>/<name>/package.toml, patches/, files/
profiles/x86_64.toml, aarch64.toml, riscv64.toml
images/fenriros.toml
keys/             public signing keys (private keys never in the repository)
```

## 12. Testing

- **Unit tests:** recipe and profile validation (wrong types, unknown keys,
  bad checksums), macro expansion for each target,
  the generated cross and toolchain files, subpackage splitting, and the
  ELF and pkg-config scans against fixture files.
- **End-to-end:** `tests/run-all.sh` runs the end-to-end scripts. `forgotten-dep` is skipped: stage 1 cannot catch a forgotten
  dependency (7.3), so that test comes back with stage 2.
- **Sandbox tests:** a build can't reach the network, can't see the build
  machine's processes or `/home`, and leaves no mount or process behind.
  (`tests/sandbox.sh`: a probe runs as a build step and checks the sandbox
  from the inside; the same probe must flag the host, or it proves nothing.)
- **End-to-end tests** (`tests/run-all.sh`) use `dkdemo`, a tiny library built
  from a generated tarball through a `file://` source, so they need no
  download and no package from any repository can stand in for it.
- **A forgotten dependency fails:** a test recipe that uses zlib without
  declaring it must fail to build.
- **The FenrirOS tree:** `dkbuild world` for `x86_64`, then
  `dkbuild image images/fenriros.toml`, then the ISO boots in QEMU with
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
- **Done when:** `dkbuild image images/fenriros.toml` produces an ISO that
  boots in QEMU on BIOS and UEFI, and passes CONSTRAINTS.md's checks.

### B4 — Cross

- Sections 6.2 to 6.4, aarch64 first.
- **Done when:** the aarch64 base set and an aarch64 image build on an
  x86_64 machine, and the image boots in `qemu-system-aarch64`.

### B5 — riscv64

- **Done when:** as B4, for riscv64.

## 14. Open questions

1. ~~The real name.~~ **Decided:** `dkbuild`.
2. ~~Recipe format.~~ **Decided:** TOML, read with `toml-zig` (decision
   record `docs/decisions/0001-toml-recipes.md`). Earlier it was a YAML subset
   read by our own `src/yaml.zig` (zig-yaml had been tried and dropped: it
   needed patches for Zig 0.17.0 and had no `|` block scalars). YAML remains
   only as an import format (5.9). Semantic errors (unknown key, wrong type)
   name the key but not the line, because `toml-zig` does not record key
   positions; syntax errors keep line and column.
3. The apk-tools v3 version to pin, and how signing keys are kept and used
   (undecided).
4. Bootloader for all architectures, pending dklilo (6.1). Until then B3 needs a
   stand-in on x86_64.
5. qemu-user and `binfmt_misc` for native builds of other architectures
   (6.3).
6. ~~DKRescue's posts.~~ **Decided:** DKRescue was a one-off. FenrirOS has its
   own documentation; the DKRescue posts stay as history. The DKRescue
   *image* is not history: it is stage 0 (9.2).
7. ~~The base system's contents and stages (9).~~ **Decided:** `/bin/sh` is
   **dash**; bash is the interactive shell; **dksh** is an experimental shell,
   packaged and installable but not the default. GNU userland, as in DKRescue
   (static where 9.1 says). The compiler is **not** in `base`; it is in
   `base-devel`, which build roots and a later "everything included" image
   install. Still open: how a recipe names a build tool that has different
   names in stage 1 and stage 2 (9.4, item 2).
8. ~~Stage 1 lower layer (7.3, 9.4 item 1).~~ **Decided:** an overlay in the
   user namespace. Stage 1 cannot catch a forgotten dependency; stage 2 does.
9. ~~Triple vendor (6.1, 9.2).~~ **Decided:** `fenriros`; DKRescue's LLVM
   builds and runs programs with any vendor (tested, 9.2). The profiles switch
   when builds move to the DKRescue root.
10. ~~The importer (5.9).~~ **Decided:** inside dkbuild (`src/cbuild.zig`); it
    translates only trivial calls and marks everything else for a person. Split
    it out only if something else needs the Python reader.
