% DKBUILD(1) Version 0.1 | dkbuild Manual
% Dakota Keeler and contributors
% 2026-11-25

NAME
dkbuild - build apk packages from TOML recipes inside an unprivileged sandbox

SYNOPSIS
dkbuild [--tree DIR] COMMAND [ARGUMENTS]

dkbuild check [NAME | FILE.toml]...

dkbuild fetch [NAME]...

dkbuild pkg [-j N] [-P N] [--key FILE] [--keep-root] [--no-check] [--keep-going] [--force] [--color=WHEN] NAME...

dkbuild world [-j N] [-P N] [--key FILE] [--keep-root] [--no-check] [--keep-going] [--force] [--color=WHEN]

dkbuild image [-v | --verbose] FILE.toml

dkbuild discs [--media M] [--key FILE] FILE.toml

dkbuild prune [--dry-run] [--key FILE]

dkbuild outdated [--bump]

dkbuild hackage-lock FREEZE-FILE [-o FILE]

dkbuild python-lock INPUT [-o FILE]

dkbuild yarn-lock YARN.LOCK [-o FILE]

dkbuild upstream [--all] [--refresh] [--notify] [NAME]...

dkbuild graph NAME...

dkbuild import-cbuild [--out DIR] TEMPLATE.py | DIR...

dkbuild doctor

dkbuild bootstrap-root [--force] [--dest DIR] IMAGE

DESCRIPTION
dkbuild reads package recipes from the tree (**packages/**), builds each one in a user, mount, PID, network, UTS and IPC namespace on an overlay of the build machine (stage 0), splits and scans the result, and writes signed apk packages into **repo/**. It also makes images and disc sets from that repository. It needs no root privileges. See **SPEC.md** for the design; this page describes what is implemented.

There is no **shell** command (SPEC.md 10).

CONVENTIONS
Bold is literal. Upper case is a value you supply. [item] is optional, item... repeats.

COMMANDS
check
Validates recipes: required fields, known keys, checksums present, patches exist, no dependency cycles, a recipe lives in **packages/LETTER/NAME/**. A dependency that no recipe provides is not an error. With no argument, all recipes. A name or a **.toml** path may be given; a file given by path is only parsed.

fetch
Downloads the named recipes' sources (all if none) into **cache/sources/**, named by SHA-256, and verifies them. Makes **snapshot:** sources and vendors the dependency stores in **cache/** (SPEC.md 5.3, 7.4). The Gradle, Maven and NuGet stores are not filled here: a build fills them, once per source.

pkg
Builds the named packages, their run-time dependencies, and any build dependencies that are missing or out of date. Up-to-date packages are skipped. One package builds at a time unless **-P** is given.

world
Builds every recipe in the tree that is out of date.

image
Makes an image from **repo/** as described by FILE.toml (**images/**): a root directory, tarball, squashfs or live ISO in **out/NAME/**. A failed run leaves the old **out/NAME/** in place. See SPEC.md 8 for the file's keys.

discs
Writes the repository or the sources, as described by FILE.toml (**kind** = "repo" or "source"), as ISO images in **out/NAME/**. A source set carries the named source tarballs and every dependency store in **cache/** (SPEC.md 8). A file with the contents of the private signing key stops either kind.

prune
Removes packages from **repo/** that their recipe no longer builds, once its present version is built, and rebuilds the index. Packages no recipe provides are reported and left. Also prunes the Rust, Zig, Go and gem dependency lists and stores, and cargo's extracted copies. Do not run it while a fetch or build is running.

outdated
Lists recipes whose recipe, patches, files or scripts changed since they were built, with the same version and release.

hackage-lock, python-lock, yarn-lock
Write the pinned lock files of the **hackagedeps** and **pydeps** options, and the **yarn.package-lock.json** that **npmdeps** reads for a yarn project (SPEC.md 7.4). These use the network and the host's **python3**.

upstream
Reports recipes that have a newer upstream release. It changes no recipe. **upstream.toml** holds per-package overrides.

Pre-releases are never reported unless a package has **prerelease = true** there. They are recognised by words (alpha, beta, rc, dev, pre, preview, snapshot, nightly, test, canary) and, for git tags, directory listings, SourceForge and GNOME, by numbers: a part after the first that is 90-99 or 900-999 with no release among the nine numbers below it (2.4.99 after 2.4.4), unless the recipe's version is already numbered that way. A pre-release that only a forge's release page marks as one is not recognised: use **ignore**.

graph
Prints the build order for the named packages. A dependency that no recipe provides is an error.

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

-P N
: Run up to N builds at once (default 1). A build starts once every in-tree package its build root needs is built; when one of those fails, it is skipped. Each build gets the full **-j**. A recipe with a **jobs:N** option (LLVM, Zig) is heavy and runs alone: it waits for the running builds to end, and nothing starts beside it. With N above 1, each build's output is printed whole when it ends, after a **--> NAME: started** line when it begins.

--keep-going
: When a build fails, keep building what does not need it, and list the failed and skipped recipes at the end. A recipe changed without a release bump is listed too instead of stopping the run. The same lists are written to **logs/ARCH/last-run.txt**, with or without this option.

--key FILE
: RSA key used to sign packages. Default: **~/.config/dkbuild/signing.rsa**. Also accepted by **prune** and **discs**.

--keep-root
: Keep the build root under **work/NAME/** after the build, for inspection.

--no-check
: Skip every recipe's check step. For first bring-up builds, when test suites would take longer than the build.

--force
: Rebuild even when the package is up to date, or when its recipe changed without a release bump. This applies to every package in the run, including dependencies.

--color=auto|always|never
: Colors in the progress lines. **always** keeps them through a pipe.

image
-v, --verbose
: List the packages asked for and show the run as it happens. Otherwise its output is only in the log.

discs
--media M
: Override the file's medium: **usb** (one image), **cd**, **dvd**, **dvd-dl**, **bd25**, **bd50** or **bd100**.

--key FILE
: The private key that signs the disc set (the index of a repository set, and the MANIFEST). Its public half must be in **keys/**. A file that does not exist is an error. No disc may carry this key or the default one. Without the option the default is used; a source set is made unsigned if that is missing.

prune
--dry-run
: Say what would be removed, and remove nothing.

outdated
--bump
: Raise **release** in each listed recipe.

hackage-lock, python-lock, yarn-lock
-o FILE
: The lock file to write.

upstream
--all
: Also list what could not be checked.

--refresh
: Ignore the cached results (kept 12 hours).

--notify
: Send a desktop notification when there are updates.

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
: A recipe or image file is invalid, a build failed or was skipped, or a check failed. The **\*-lock** and **upstream** commands pass on the exit status of their Python script.

2
: Usage error, such as no command or an unknown one; the usage text is printed.

ENVIRONMENT
HOME
: Locates the default signing key.

PATH
: Where the host programs are found; **doctor** searches it.

DKBUILD_FAST_WORK
: A directory on a faster disk for build roots, used while it has 30 GB free (100 GB for a recipe with **jobs:N**).

NO_COLOR
: Turns colors off.

FILES
packages/LETTER/NAME/package.toml
: A recipe. See **package.toml**(5). **patches/**, **files/** and **scripts/** beside it hold patches, extra files and apk install scripts.

profiles/ARCH.toml
: Per-architecture build settings (triple, CPU, Zig target).

repo/ARCH/
: Built packages, the signed index, and a **NAME.dkhash** rebuild record for each recipe built.

images/, upstream.toml
: Image and disc-set files; overrides for **upstream**.

cache/
: **sources/** holds downloaded sources; the other directories are the dependency stores and snapshot work directories (SPEC.md 7.4).

logs/ARCH/, work/, rootfs/, out/
: Build logs and run summaries (**last-run.txt**, **runs/**), scratch space, the stage 0 root, and images and discs. These, **cache/** and **repo/ARCH/** are ignored by git, and may be symbolic links to another disk.

contrib/worldloop.sh
: Repeats **prune** and **world --keep-going** until nothing fails; run as a systemd user unit (see its header).

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

Make an image:

    dkbuild image --verbose images/base.toml

DIAGNOSTICS
Recipe problems print as **NAME: message**. A failed build prints the log path, **logs/ARCH/NAME-VERSION-rN.log**; the log holds the output of every step. An earlier log of the same name is kept as **NAME-VERSION-rN.1.log**, and so on.

SECURITY CONSIDERATIONS
Builds run unprivileged in namespaces with no network and no access to the host's **/home**. The exception is the once-per-source restore run of **gradledeps**, **mavendeps** and **nugetdeps** recipes, which has the network. Sources are verified by SHA-256 before use. The signing key is bound read-only only into the sandbox runs that sign (packaging, the index, disc sets), never into a recipe's build steps. Some fetch work (applying patches to vendor dependencies, laying out the vendored stores, snapshot scripts) runs on the host, outside the sandbox. Recipes are code: read third-party recipes before building them.

CONCURRENCY AND ATOMICITY
One package is built at a time by default; **-P** builds several. New packages are written under a temporary name and renamed into place, and one build at a time rebuilds the index. Do not run two dkbuild processes that build or prune on the same tree.

COMPATIBILITY
Linux 5.11 or newer (unprivileged overlayfs). x86_64 is built; aarch64 and riscv64 profiles exist but are unverified.

LIMITATIONS
No stage 2: builds run on the DKRescue root, so a forgotten dependency is not caught (SPEC.md 7.3). No cross builds (6). **{ git }** sources cannot be fetched (5.3).

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
