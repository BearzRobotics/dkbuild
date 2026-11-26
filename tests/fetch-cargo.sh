#!/bin/sh
# `dkbuild fetch` vendors Rust crates with the host's cargo, from an untrusted source: nothing the source's own
# cargo or rustup settings name may run, while the settings that decide which crates to vendor still count.
# Offline: the dependency is a local git repository. Skipped without cargo and git.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
if ! command -v cargo >/dev/null || ! command -v git >/dev/null; then echo "skipped: needs cargo and git on the host"; exit 0; fi
T=tests/trees/fetch-cargo
newtree "$T"
rm -rf "$T/src" "$T/ran" "$T/outside"; mkdir -p "$T/src" "$T/ran"
A=$PWD/$T
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

crate() { # crate DIR NAME VERSION
    mkdir -p "$1/src"; echo 'pub fn f() {}' > "$1/src/lib.rs"
    printf '[package]\nname = "%s"\nversion = "%s"\nedition = "2021"\n' "$2" "$3" > "$1/Cargo.toml"
}
crate "$A/src/dep-repo" dkdep 1.0.0
git -C "$A/src/dep-repo" init -q && git -C "$A/src/dep-repo" add -A && git -C "$A/src/dep-repo" commit -qm one || exit 1

crate "$A/src/other-repo" dkother 1.0.0
git -C "$A/src/other-repo" init -q && git -C "$A/src/other-repo" add -A && git -C "$A/src/other-repo" commit -qm one || exit 1

# project NAME: a crate depending on the local git repositories
project() {
    crate "$W/$1" "$1" 1.0.0
    printf '\n[dependencies]\ndkdep = { git = "file://%s/src/dep-repo" }\ndkother = { git = "file://%s/src/other-repo" }\n' "$A" "$A" >> "$W/$1/Cargo.toml"
}
# finish NAME: lock it (before any hostile setting is added), then `extra`, then pack and write the recipe
lock() { ( cd "$W/$1" && CARGO_HOME="$W/lockhome" cargo generate-lockfile -q ) || { echo "FAIL: cannot lock $1"; exit 1; }; }
pack() {
    tar -C "$W" -czf "$A/src/$1.tar.gz" "$1"
    mkdir -p "$T/packages/$(printf %.1s "$1")/$1"
    cat > "$T/packages/$(printf %.1s "$1")/$1/package.toml" <<EOR
name    = "$1"
version = "1"
release = 1
summary = "Test recipe"
license = "MIT"
options = ["cargodeps", "!check"]
source = [ { url = "file://$A/src/$1.tar.gz", sha256 = "$(sha256sum "$A/src/$1.tar.gz" | cut -d' ' -f1)" } ]
build = 'true'
install = 'true'
EOR
}
evil() { # evil FILE MARK: a program that records that it ran
    printf '#!/bin/sh\ntouch "%s/ran/%s"\nexit 1\n' "$A" "$2" > "$1"; chmod +x "$1"
}

# 1. .cargo/config.toml names the compiler, a wrapper and a credential provider.
project config; sed -i 's/edition = "2021"/edition = "2024"/' "$W/config/Cargo.toml"; lock config   # 2024: cargo asks rustc its version while resolving
mkdir -p "$W/config/.cargo"; evil "$A/evil.sh" config-rustc
printf '[build]\nrustc = "%s"\n\n[registry]\nglobal-credential-providers = ["%s"]\n' "$A/evil.sh" "$A/evil.sh" > "$W/config/.cargo/config.toml"
pack config

# 2. rust-toolchain.toml points rustup at a "toolchain" inside the source.
project toolchain; lock toolchain
mkdir -p "$W/toolchain/tc/bin" "$W/toolchain/tc/lib"; evil "$W/toolchain/tc/bin/cargo" toolchain-cargo; evil "$W/toolchain/tc/bin/rustc" toolchain-rustc
printf '[toolchain]\npath = "/proc/self/cwd/tc"\n' > "$W/toolchain/rust-toolchain.toml"
pack toolchain

# 3. An honest setting the vendoring depends on: [patch] in the project's config.
project patched
mkdir -p "$W/patched/.cargo"; crate "$W/patched/local-dkdep" dkdep 1.0.7
printf '[patch."file://%s/src/dep-repo"]\ndkdep = { path = "local-dkdep" }\n\n[build]\njobs = 1\n' "$A" > "$W/patched/.cargo/config.toml"
lock patched
pack patched

for p in config toolchain patched; do
    OUT=$(./zig-out/bin/dkbuild --tree "$T" fetch "$p" 2>&1); RC=$?
    [ -z "$(ls "$A/ran")" ] || { echo "FAIL: fetching '$p' ran a program named by the source: $(ls "$A/ran" | tr '\n' ' ')"; fail=1; rm -f "$A"/ran/*; }
    [ "$RC" = 0 ] || { echo "$OUT" | tail -8; echo "FAIL: fetching '$p' failed"; fail=1; }
done

# 4. The archive's top "directory" is a link to a directory outside: cargo must not work there.
mkdir -p "$A/outside/.cargo"; echo '[build]' > "$A/outside/.cargo/config.toml"; crate "$A/outside" outside 1.0.0
rm -rf "$W/linked"; ln -s "$A/outside" "$W/linked"; pack linked
./zig-out/bin/dkbuild --tree "$T" fetch linked >/dev/null 2>&1 && { echo "FAIL: a source whose top directory is a link was vendored"; fail=1; }
{ [ "$(cat "$A/outside/.cargo/config.toml")" = '[build]' ] && [ ! -e "$A/outside/vendor" ]; } || { echo "FAIL: vendoring changed a directory outside the source"; fail=1; }
[ "${fail:-0}" = 0 ] || exit 1
# what the build gets still has the project's own settings, then cargo vendor's
cfg=$(cat "$T"/cache/cargodeps/"$(sha256sum "$A/src/patched.tar.gz" | cut -d' ' -f1)".config.toml)
for want in local-dkdep 'jobs = 1' vendored-sources; do
    echo "$cfg" | grep -q "$want" || { echo "$cfg"; echo "FAIL: the build's cargo config lost a setting: $want"; exit 1; }
done
echo "ok: vendoring runs nothing the source names, and keeps the settings that choose the crates"
