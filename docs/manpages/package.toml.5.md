% PACKAGE.TOML(5) Version 0.1 | dkbuild Manual
% Dakota Keeler and contributors
% 2026-11-25

NAME
package.toml - a dkbuild package recipe

SYNOPSIS
packages/LETTER/NAME/package.toml

DESCRIPTION
A recipe describes one source package: where the sources come from, how to build and install them, and the packages that result. LETTER is the first character of NAME, a letter or a digit. Unknown keys are an error. All top-level keys come before any **[subpackages.*]** table (TOML rule). Shell steps are multi-line literal strings (**'''** ... **'''**).

CONFIGURATION
Keys

| Key | Type | Required | Meaning |
|---|---|---|---|
| name | string | yes | Lower case letters, digits, **-**, **+**, **.**; must match the directory |
| version | string | yes | Upstream version |
| release | integer | yes | Recipe revision, from 1; reset on a new version |
| summary | string | yes | One line |
| description | string | no | Longer text |
| license | string | yes | SPDX expression |
| homepage | string | no | URL |
| source | array of tables | no | **{ url, sha256 }**, see Sources below; **{ git, tag \| commit }** is accepted but cannot be fetched yet. Without it, **files/** is the whole content |
| patches | array | no | Files in **patches/**, applied in order with **patch -Np1** |
| archs | array | no | Architectures built; **!riscv64** excludes one. Checked, but nothing acts on it yet |
| hostdeps | array | no | Programs run during the build (build machine's architecture) |
| builddeps | array | no | Libraries and headers linked against (target architecture) |
| checkdeps | array | no | Needed only by **check** |
| rundeps | array | no | Runtime dependencies that cannot be detected |
| stage0deps | array | no | With **selfhost** only: what the first build uses while **repo/** has no earlier package of this recipe |
| provides | array | no | Names the main package provides besides what the scan finds |
| noscan | array | no | Globs of paths the dependency scan skips; **/\*\*** at the end takes a whole tree |
| replaces | array | no | Packages whose files the main package may take over |
| triggers | array | no | Directories whose changes run the main package's **scripts/trigger** |
| options | array | no | See below |
| environment | string | no | Shell lines run once, before the first step |
| restore | string | with nugetdeps or mavendeps | Commands that fill the package store; run once per source, with the network |
| setup, build, check, install | string | install: yes (not for **meta**) | Shell steps |
| subpackages | tables | no | See below |

Sources
A tarball entry is **{ url, sha256 }**, with a lower case SHA-256. The first tarball is unpacked into **/build**, and the steps start in its top directory; further tarballs and **.zip** files are unpacked beside it. **unpack = false** or **name = "FILE"** copies the file to **/build/sources/** instead, as is done for any file that is not an archive. A **url** of the form **snapshot:KIND ARGS** is made at fetch time by a script in dkbuild (**electron**, **git**, **dart**, **scratch-media**, **brave**, **euro-office**, **dotnet**; SPEC.md 5.3).

Options
Any other option is an error.

| Option | Effect |
|---|---|
| !check | Do not run **check** |
| !strip | Do not strip binaries |
| !cross, !lto, bootstrap | Accepted; no effect yet |
| static | Link programs statically by adding **-static** to **LDFLAGS**; never use it on a recipe that installs a shared library |
| gcc | Build with GCC 15 and GNU binutils instead of clang |
| selfhost | A compiler built with itself: the build root also gets this recipe's newest package in **repo/** |
| jobs:N | At most N parallel jobs for this recipe; with **-P**, it builds alone |
| meta | A meta-package: no source and no steps, only dependencies |
| rootlayout | May install outside **/usr /etc /var /opt /boot** |
| !repo-iso | Left out of repository discs |
| zigdeps, godeps, cargodeps, npmdeps, gemdeps, pubdeps | Vendor the language's dependencies at fetch time from the source's own files |
| hackagedeps, pydeps | Vendor the packages pinned in **files/hackage.lock** or **files/python.lock** |
| gradledeps | Needs a **gradle-VERSION-bin.zip** source and **unzip** in **hostdeps** |
| mavendeps | Needs an **apache-maven-VERSION-bin.tar.gz** source (**unpack = false**) and **restore** |
| nugetdeps | Needs **restore** |
| yarnberry | With **npmdeps**, for a recipe that installs with yarn 2 or later |
| cargolock=DIR | With **cargodeps**: use **files/Cargo.lock** for the Rust project at DIR of the source, which ships none |

The dependency options are described in SPEC.md 5.4 and 7.4.

Variables in steps
name, version, release, jobs, srcdir, pkgdir, pkgfiles (the recipe's **files/**), target (LLVM triple), arch, zig_target, zig_cpu, CC, CXX, CFLAGS, CXXFLAGS, LDFLAGS.

Macros
%configure, %make, %make_install, %meson, %meson_build, %meson_install, %cmake, %cmake_build, %cmake_install, %zig_build, %kernel_make. They are defined in SPEC.md 5.5.

Subpackages
**[subpackages.KEY]** with **summary** and **paths** creates **NAME-KEY**. **devel**, **static**, **doc** and, for a package that also ships programs, **libs** exist by default; one with the same name replaces the default. Each file goes to the first subpackage whose path matches, declared ones first. Optional keys: **depends** (packages needed besides what the scan finds; **PKG=@built** pins the version in the build root), **install_if** (installed automatically once all of these are) and **empty = true** (made even with no files). Otherwise a subpackage with no files is not made.

Install scripts
Files in **scripts/** next to **package.toml**, named **pre-install**, **post-install**, **pre-upgrade**, **post-upgrade**, **pre-deinstall**, **post-deinstall** or **trigger**, are attached to the main package. They run in the target root when apk installs it, so they can use only what is installed there. Subpackages get none.

EXAMPLES
    name = "dksh"
    version = "0.0.1"
    release = 1
    summary = "A small shell written in Zig"
    license = "MIT"
    hostdeps = ["zig"]
    source = [
        { url = "https://example.org/dksh-0.0.1.tar.gz", sha256 = "..." },
    ]
    install = '''
    %zig_build
    '''

SEE ALSO
**dkbuild**(1), **SPEC.md** section 5

AUTHOR
Dakota Keeler and contributors.

VERSION
Describes the recipe format implemented in this repository.
