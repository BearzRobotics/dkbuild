# Brave: survey (2026-11-11), before the recipe

Target: Brave 1.99.56 (release channel), Chromium 157.0.8103.50: the same
major as packages/c/chromium (157.0.8103.38), so Chimera's patches are the
starting point.

## What Brave's own checkout (`npm run init` / `npm run sync`) does

- gclient: chromium/src at the tag in brave-core's package.json
  (config.projects.chrome.tag), brave-core as src/brave.
- brave-core DEPS, Linux deps (git, pinned commits):
  vendor/bat-native-tweetnacl, vendor/gn-project-generators,
  vendor/web-discovery-project, third_party/bip39wally-core-native,
  third_party/ethash/src, third_party/bitcoin-core/src (v25.0),
  third_party/argon2/src, third_party/reclient_configs/src (not needed),
  third_party/playlist_component/src, third_party/rust/futures_retry/v0_5/crate,
  components/brave_wallet/browser/zcash/rust/librustzcash/src.
- Hooks that matter on Linux: web_discovery_project npm install,
  generate_licenses, brave_lastchange (build/util/LASTCHANGE),
  brave_version_gni, generate_chromium_src_clang_format. Not needed:
  download_opengrep (linting), agent skills.
- EXTRA_DEPS (Brave's S3 bucket, prebuilt):
  * rust-toolchain overlay: Rust's wasm32-unknown-unknown std + rust-lld
    (tools/cr/toolchains/build_rust_toolchain.py). Here: upstream's
    rust-std-<ver>-wasm32-unknown-unknown component (same release as our
    rust), a `rust-wasm` recipe or subpackage, like Chimera's rust-wasm.
  * node binary (system nodejs instead), node_modules-42138ce.tar.gz
    (what is it? check brave/third_party/node: probably tools' modules;
    pnpm from the lockfile instead), ast-grep (check whether the build
    runs it: the top-level `rewrite/` directory suggests source rewriting).
- Patches: 1254 for chromium/src (patches/*.patch), plus catapult (12),
  devtools-frontend (14), ffmpeg (8), search_engines_data (1), tflite (1),
  v8 (2). Applied with `git apply` (build/commands/lib/gitPatcher.js).
  Conflicts with Chimera's patches are expected: apply Brave's first, then
  Chimera's, and fix the overlaps by hand.
- JS: brave-core has pnpm-lock.yaml + pnpm-workspace.yaml (dkbuild's pnpm
  support); the WebUI is built by webpack inside GN actions.
- Rust: third_party/rust/chromium_crates_io has vendor/ checked in (like
  Chromium's), so no cargodeps for the crates themselves.
- GN args: build/commands/lib/buildArgs.ts + config.ts (API keys default
  empty; brave_services_key etc. need values or stubs: check what an
  unofficial build uses).

## Plan

1. snapshot:brave (like snapshot:electron): Chromium tarball for
   157.0.8103.50 + brave-core v1.99.56 + its DEPS repos + Brave's patches
   applied + hooks' generated files, one tarball. Or: those as separate
   sources and the patching in the recipe (1300 patches, but no snapshot to
   maintain). Decide after a trial.
2. rust-wasm (upstream wasm32 std).
3. Recipe from packages/c/chromium (crubit, gnrt, typescript-go, unbundling).

## ast-grep: not needed to build

rewrite/ has 857 "plaster" files (tools/cr/plaster.py, docs/plaster.md):
ast-grep/regex rules Brave's developers run to *generate* the patch files in
patches/, which are checked in. A checkout applies only patches/ (git apply,
build/commands/lib/gitPatcher.js), so the build does not run ast-grep. (An
ast-grep recipe was written before this was clear; it stays as a tool.)
