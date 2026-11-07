% PACKAGE.TOML(5) Version 0.1 | dkbuild Manual
% Dakota Keeler and contributors
% 2026-11-07

NAME
package.toml - a dkbuild package recipe

SYNOPSIS
packages/LETTER/NAME/package.toml

DESCRIPTION
A recipe describes one source package: where the sources come from, how to build and install them, and the packages that result. LETTER is the first letter of NAME. Unknown keys are an error. All top-level keys come before any **[subpackages.*]** table (TOML rule). Shell steps are multi-line literal strings (**'''** ... **'''**).

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
| source | array of tables | yes | **{ url, sha256 }** or **{ git, tag \| commit }**; the first tarball is unpacked and steps start in its top directory |
| patches | array | no | Files in **patches/**, applied with **patch -p1** |
| archs | array | no | Architectures built; **!riscv64** excludes one |
| hostdeps | array | no | Programs run during the build (build machine's architecture) |
| builddeps | array | no | Libraries and headers linked against (target architecture) |
| checkdeps | array | no | Needed only by **check** |
| rundeps | array | no | Runtime dependencies that cannot be detected |
| options | array | no | See below |
| environment | string | no | Shell lines run before every step |
| setup, build, check, install | string | install: yes | Shell steps |
| subpackages | tables | no | See below |

Options
check, cross, strip, lto, static, bootstrap, jobs:N. A leading **!** turns one off (**!check**, **!strip**, **!cross**, **!lto**). **static** links programs statically by adding **-static** to **LDFLAGS**: never use it on a recipe that installs a shared library. **jobs:N** caps parallel jobs for this recipe.

Variables in steps
jobs, srcdir, pkgdir, target (LLVM triple), arch, zig_target, zig_cpu, CC, CXX, CFLAGS, CXXFLAGS, LDFLAGS.

Macros
%configure, %make, %make_install, %meson, %meson_build, %meson_install, %cmake, %cmake_build, %cmake_install, %zig_build, %kernel_make. They are defined in SPEC.md 5.5.

Subpackages
**[subpackages.KEY]** with **summary** and **paths** creates **NAME-KEY**. **devel**, **static** and **doc** exist by default. Each file goes to the first subpackage whose path matches. A subpackage with no files is not made.

Install scripts
Executable files in **scripts/** next to **package.toml**, named **pre-install**, **post-install**, **pre-upgrade**, **post-upgrade**, **pre-deinstall**, **post-deinstall** or **trigger**, are attached to the main package. They run in the target root when apk installs it, so they can use only what is installed there. Subpackages get none.

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
