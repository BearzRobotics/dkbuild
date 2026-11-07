% DKBUILD(1) Version 0.1 | dkbuild Manual
% Dakota Keeler and contributors
% 2026-11-07

NAME
dkbuild - build apk packages from TOML recipes inside an unprivileged sandbox

SYNOPSIS
dkbuild [--tree DIR] COMMAND [ARGUMENTS]

dkbuild check [NAME | FILE.toml]...

dkbuild fetch [NAME]...

dkbuild pkg [-j N] [--key FILE] [--keep-root] [--force] NAME...

dkbuild world [-j N] [--key FILE] [--keep-root] [--force]

dkbuild graph NAME...

dkbuild import-cbuild [--out DIR] TEMPLATE.py | DIR...

dkbuild doctor

dkbuild bootstrap-root [--force] [--dest DIR] IMAGE

DESCRIPTION
dkbuild reads package recipes from the tree (**packages/**), builds each one in a user, mount, PID, network, UTS and IPC namespace on an overlay of the build machine (stage 0), splits and scans the result, and writes signed apk packages into **repo/**. It needs no root privileges. See **SPEC.md** for the design; this page describes what is implemented.

Commands not documented here (**image**, **shell**) are in the SPEC but do not exist yet.

CONVENTIONS
Bold is literal. Upper case is a value you supply. [item] is optional, item... repeats.

COMMANDS
check
Validates recipes: required fields, known keys, checksums present, patches exist, dependencies are in the tree, a recipe lives in **packages/LETTER/NAME/**. With no argument, all recipes. A name or a **.toml** path may be given.

fetch
Downloads the named recipes' sources (all if none) into **cache/sources/**, named by SHA-256, and verifies them.

pkg
Builds the named packages and any dependencies that are missing or out of date. Up-to-date packages are skipped. One package builds at a time.

world
Builds every recipe in the tree that is out of date.

graph
Prints the build order for the named packages.

import-cbuild
Converts Chimera Linux **cbuild** templates (**template.py**) into draft recipes with a list of what needs review. Output goes to **imported/** unless **--out** is given. Drafts are not placed in **packages/** automatically.

doctor
Checks the host: programs, user namespaces, overlayfs, disk space, signing key. Prints the fix for each failure.

bootstrap-root
Unpacks the stage 0 build machine from IMAGE (the DKRescue ISO, its **rootfs.sfs**, or a root tarball; detected by content) into **rootfs/dkrescue/** and checks it runs.

OPTIONS
Global
--tree DIR
: Use DIR as the project root. Default: the current directory. Must come before the command.

pkg and world
-j N
: Parallel jobs per build. A recipe's **jobs:N** option can lower this, never raise it.

--key FILE
: RSA key used to sign packages. Default: **~/.config/dkbuild/signing.rsa**.

--keep-root
: Keep the build root under **work/NAME/** after the build, for inspection.

--force
: Rebuild even when the package is up to date.

import-cbuild
--out DIR
: Where drafts are written. Default: **imported/**.

bootstrap-root
--dest DIR
: Unpack into DIR instead of **rootfs/dkrescue/**.

--force
: Replace an existing root.

EXIT STATUS
0
: Success.

1
: A recipe is invalid, a build failed, or a check failed.

2
: Usage error: no command or an unknown one; the usage text is printed.

ENVIRONMENT
HOME
: Locates the default signing key.

PATH
: Searched by **doctor** for the host programs.

FILES
packages/LETTER/NAME/package.toml
: A recipe. See **package.toml**(5). **patches/** and **files/** beside it hold patches and extra files.

profiles/ARCH.toml
: Per-architecture build settings (triple, CPU, Zig target).

repo/ARCH/
: Built packages and the signed index.

cache/sources/, logs/ARCH/, work/, rootfs/
: Downloaded sources, build logs, scratch space and the stage 0 root. All are ignored by git.

~/.config/dkbuild/signing.rsa
: Private signing key. The matching public key is kept in **keys/**.

EXAMPLES
Check everything, then build one package and what it needs:

    dkbuild check
    dkbuild pkg llvm

Unpack the build machine from the ISO:

    dkbuild bootstrap-root /path/to/dkrescue.iso

Build with fewer jobs:

    dkbuild pkg -j 4 zstd

DIAGNOSTICS
Recipe problems print as **NAME: message**. A failed build prints the log path, **logs/ARCH/NAME-VERSION-rN.log**; the log holds the output of every step.

SECURITY CONSIDERATIONS
Builds run unprivileged in namespaces with no network and no access to the host's **/home**. Sources are verified by SHA-256 before use. The signing key stays on the host, never in the build root. Recipes are code: read third-party recipes before building them.

CONCURRENCY AND ATOMICITY
One package is built at a time. Do not run two dkbuild processes on the same tree.

COMPATIBILITY
Linux 5.11 or newer (unprivileged overlayfs). x86_64 is built; aarch64 and riscv64 profiles exist but are unverified.

LIMITATIONS
No image building, no stage 2, no install scripts, no Zig dependency fetch yet (SPEC 9.4).

SEE ALSO
**package.toml**(5), **SPEC.md**, **docs/roadmap.md**

AUTHOR
Dakota Keeler and contributors.

LICENSE
See the LICENSE file in the source tree.

AVAILABILITY
Source code and issue tracker: https://github.com/BearzRobotics/dkbuild

VERSION
This manual describes the dkbuild in this repository; it is updated with the code.
