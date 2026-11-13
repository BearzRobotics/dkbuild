# Euro-Office: survey (2026-11-12), and the first recipes

Euro-Office (github.com/Euro-Office, "Your sovereign office") is the AGPL fork
of ONLYOFFICE (Docs and Desktop Editors) run by Nextcloud and partners. Target:
**Document Server 9.3.7-1** (latest stable, 2026-10-29). Desktop Editors:
latest stable is **9.3.6** (2026-10-22); see 3.

Recipes written (not built yet; `dkbuild check` passes, fetch results in the
report):
- packages/e/euro-office-v8 (V8 8.9.45 static, snapshot:euro-office)
- packages/e/euro-office-core (x2t and tools, snapshot:git + 9 pinned sources)
- packages/e/euro-office-documentserver (sdkjs, web-apps, server, fonts, ...)
- src/snapshot-euro-office.sh + its entry in src/fetch.zig
- packages/l/libera-suite (the desktop app, 3b) + python-pywebview,
  python-proxy-tools, python-bottle

## 1. Releases and how they pin the repositories

- The products are umbrella repositories with submodules:
  DocumentServer (core, core-fonts, sdkjs, sdkjs-forms, web-apps, server,
  dictionaries, document-templates, document-formats, document-server-package,
  document-server-integration) and DesktopEditors (core, core-fonts, sdkjs,
  sdkjs-forms, web-apps, dictionaries, document-templates, desktop-sdk,
  desktop-apps). plugins, editors-engine, docker-ci, release are not
  submodules.
- The `release` repo (release.sh + GitHub workflows) is the pinning
  mechanism: "Prepare release" pins every submodule to the latest commit of
  main (or of `stable-X.Y.Z` for later rounds), bumps VERSION/VERSION.txt,
  opens a release PR per product; "Tag release" checks that the submodules
  shared by both products are at the same commit, then tags every submodule
  and finally the products with the same `vX.Y.Z[-N|-rc.N]` tag, and creates
  `stable-X.Y.Z` branches. So a product tag fixes every submodule commit,
  and each submodule also carries that tag (annotated).
- Tag scheme: `v9.3.7` = release (packages 9.3.7-0), `v9.3.7-1` = patch build
  1 (deb/rpm 9.3.7-1), `v9.3.8-rc.1` = prerelease, `v9.3.4-hotfix.1` =
  prerelease. The sub-repos also still carry ONLYOFFICE's tags
  (`v9.3.0.140`, `v99.99.99.*`, `win-v4.3.0.*`, `upstream/v9.3.1`): ignore
  those, they sort above Euro-Office's in `sort -V`.
- A product can be released alone ("products ds|de"): DocumentServer has
  9.3.7 and 9.3.7-1, DesktopEditors skipped them (its latest is 9.3.6;
  both have v9.3.8-rc.1). DesktopEditors v9.3.6 pins core a4a1ba1 (= the
  DocumentServer v9.3.7 core), DocumentServer v9.3.7-1 pins core afb3f23
  (brotli bump on top). sdkjs, web-apps, fonts, dictionaries identical.
- Packaging: one tarball, `snapshot:git https://github.com/Euro-Office/DocumentServer v9.3.7-1`
  (existing snapshot kind: shallow clone + submodules at the recorded
  commits). Version in recipes: 9.3.7.1 (apk has no `-N`).

## 2. Document Server

Upstream builds everything in Docker (build/docker-bake.hcl and the
`.docker/*.bake.Dockerfile` of each submodule): core on Rocky 9 with clang
13 and vcpkg, sdkjs/web-apps/server on Ubuntu with nodesource Node, then
document-server-package's Makefile makes deb/rpm.

### core (C++, CMake since Euro-Office; LICENSE AGPL-3.0-only)

Builds (top CMakeLists.txt, non-wasm): x2t (+ its library x2tlib and ~20
shared libraries: kernel, kernel_network, graphics, UnicodeConverter,
PdfFile, XpsFile, DjVuFile, DocxRenderer, HtmlFile2, EpubFile, Fb2File,
HWPFile, OFDFile, IWorkFile, StarMathConverter, ooxmlsignature,
doctrenderer, ...), docbuilder, allfontsgen, allthemesgen, pluginsmanager,
CMapSerialize (cmap.bin), x2ttester. Output dirs EO_CORE_OUTPUT_DIR (bin:
goes to server/FileConverter/bin) and EO_CORE_TOOLS_DIR (server/tools),
RPATH $ORIGIN.

Third party: common.cmake runs Common/3dParty/build_3rdparty.py at configure
time, which runs each `<dep>/nc-build.py` (git clones at pinned commits, plus
an optional Nextcloud/S3 prebuilt cache only used with credentials):

| dep | upstream pin | here |
|---|---|---|
| boost | 1.83.0 (git, static) | system boost 1.91 (shared), patch |
| icu | 74.2 (copied next to x2t) | system icu 78, patch |
| openssl | 1.1.1f (static) | system openssl 3.6 (asio already patched for 3) |
| v8 | 8.9.45 (gclient + depot_tools, clang 13) | euro-office-v8 |
| harfbuzz | 894a1f7 + core's patch, compiled in by file list | pinned source, same patch |
| brotli | db24a98, compiled in | pinned source |
| html | gumbo aa91b27, katana be6df45 + patches | pinned sources, same patches |
| md | md4c 481fbfb | pinned source |
| socketio | socket.io-client-cpp da77914 + asio 230c0d2, websocketpp 56123c8, rapidjson a36110e, 5 patches, a no-TLS copy | pinned sources, same steps |
| hyphen, hunspell, openssl-hash, icu-wasm | wasm build only | not needed natively |
| cef, qt | desktop only | see 3 |
| vcpkg (hunspell, gtest, vulkan) | manifest mode | not used: native core needs none of it (gtest only for EO_BUILD_TESTS) |

The recipe skips build_3rdparty.py (THIRD_PARTY_PREPARED=ON) and lays the
pinned sources out as its install directory. System ICU/Boost/OpenSSL/V8
paths: patches/system-libraries.patch (common.cmake).

Also bundled *inside* core's tree and compiled in by file list (not touched
yet; unbundling = rewriting those CMake file lists, candidates in order of
security value): zlib 1.2.11 + minizip (OfficeUtils), freetype 2.10.4,
libpng/libjpeg/jasper/jbig/mng/libpsd/raw (cximage), openjpeg 2.4.0, libxml2
(DesktopEditor/xml), cryptopp, agg 2.4, djvulibre parts, pole, katana.
Prebuilt: Common/3dParty/libvlc/build/{linux_64,linux_arm64,win_*} (308 MB of
glibc/Windows libvlc + plugins, used by the desktop media player only; never
installed by the recipes).

Assumptions: glibc builds (Rocky 9, glibc 2.34 window), clang 13 for V8,
`CRYPTOPP_DISABLE_ASM`, x86_64 and aarch64 both supported upstream (V8 has
arm64 fixes). Nothing x86-only found in the native build.

### V8: euro-office-v8

- Version 8.9.45 (January 2021!). Fetched with depot_tools pinned at
  f394ab2 + `gclient sync --no-history --shallow`; GN built from source at
  281ba2c (a current GN no longer reads V8 8.9's build files); args:
  monolith, no i18n, no wasm, pointer compression, embedded snapshot, system
  clang (clang_base_path), use_custom_libcxx=false, use_sysroot=false. Plus
  two patches, two stub BUILD.gn (gmock, cppgc) and four enum-bitfield
  narrowings for clang >= 20.
- Here: `snapshot:euro-office v8 8.9.45 281ba2c…` (src/snapshot-euro-office.sh):
  V8 + only the DEPS entries a monolith reads (build, buildtools,
  base/trace_event/common, googletest, icu, jinja2, markupsafe, zlib,
  tools/clang) at DEPS's commits, read from DEPS with Python's ast (nothing
  runs), no gclient, no CIPD, no hooks (clang/sysroot/binutils downloads);
  writes build/config/gclient_args.gni as gclient would; GN source
  included. The recipe builds GN, then v8_monolith with Euro-Office's args.
- Risk: V8 8.9 with LLVM 23 + libc++ 23 + musl + Python 3.14 (jinja2 2019,
  markupsafe). Euro-Office only tested clang 13 (Linux) and Apple clang.
  Expect a round of fixes after the first build.
- **Euro-Office main moved to V8 14.6.202.34 on 2026-10-29** (core
  Common/3dParty/v8/nc-build.py on main: depot_tools a200396, system libc++,
  no sandbox, clang_base prepared from the system LLVM), with doctrenderer
  adapted. Not in any release yet (9.3.8-rc.1 still has 8.9.45). Once a
  release ships it, euro-office-v8 should move to 14.6 (the snapshot script
  takes the tag; DEPS of 14.x adds more entries: check the list then).

### sdkjs (+ sdkjs-forms), web-apps

- sdkjs: webpack 5 + terser (migrated from Grunt/Closure; no Java), npm
  packages from build/npm-shrinkwrap.json (lockfile v3, all integrity hashes).
  `SDK_ADDONS=<sdkjs-forms>` `npm run build` -> $BUILD_ROOT/sdkjs.
  Needs core's WebAssembly builds (core-wasm.bake.Dockerfile: emsdk 5.0.4,
  `emcmake cmake core` builds drawingfile, fonts, zlib, hash, spell with
  openssl-hash (OpenSSL 4.0.1), hunspell 1.7.2, brotli, harfbuzz, hyphen,
  ICU (wasm)). sdkjs also has those wasm files checked in (from ONLYOFFICE,
  Feb/Mar 2026): the recipe uses the checked-in ones for now. Building them
  needs emscripten (in the tree, 6.0.3) plus pinned ICU/OpenSSL/hunspell
  sources: a later euro-office-core-wasm recipe.
- web-apps: webpack, less, svgo, sharp (0.35, prebuilt @img/* packages incl.
  libvips, for image optimisation), build/package-lock.json v3.
  `translation/merge_and_check.py` then `THEME=euro-office node
  scripts/build-pipeline.js` -> $BUILD_ROOT/web-apps. No network.
  `npm test` (mocha-headless-chrome) not run.

### server (Node)

- DocService, FileConverter, Metrics, AdminPanel (server + React client),
  SpellChecker; each its own package.json. Locks: npm-shrinkwrap.json v1
  (Common, DocService, FileConverter, Metrics, SpellChecker, root) and
  package-lock.json v1 (AdminPanel). Upstream's Dockerfile actually runs
  `npm install` (not ci). The recipe vendors v3 conversions of exactly those
  versions (files/*.package-lock.json; verified 0 version differences, all
  with integrity) via npmdeps.
- Upstream compiles each service with @yao-pkg/pkg into one binary: pkg
  downloads prebuilt Node binaries (glibc) at build time. Here: plain node
  on the system Node.js 26 (upstream uses 24), dinit services run
  `node sources/server.js` etc.
- Native modules: sharp 0.32.6 (DocService; rebuilt from source against
  system libvips 8.18), oracledb 6.9 (prebuilt glibc thick-mode binaries,
  removed; thin mode is pure JS), modern-syslog (optional dep of statsd, not
  built), win-ca (Windows). SpellChecker needs nodehun from a Git URL
  (ONLYOFFICE/nodehun) with native code: not built (upstream's images don't
  either).
- Runtime services needed: PostgreSQL/MySQL/MSSQL/Oracle/Dameng (schemas
  in server/schema), **RabbitMQ** (default `queue.type`; ActiveMQ/AMQP 1.0
  alternative), optionally Redis (editorDataStorage defaults to memory),
  nginx. FenrirOS has postgresql, mariadb, redis/valkey, nginx; **no
  RabbitMQ / Erlang**.
- Config: server/Common/config/default.json + production-linux.json in
  /etc/euro-office/documentserver (NODE_CONFIG_DIR); local.json for site
  settings. default.json carries placeholder secrets ("secret",
  "verysecretstring", dbPass "onlyoffice"); JWT disabled by default.
  Upstream's postinst generates a JWT secret; we don't (inert), README says
  how.

### Other DocumentServer submodules

- core-fonts: ~160 MB of fonts with per-directory LICENSE.txt (OFL, Apache,
  GPL+FE, Arphic, IPA, Ubuntu Font Licence, ...). No licence file for:
  ASC.ttf (ONLYOFFICE's own), fonts-beng-extra, fonts-telu-extra, freefont,
  kacst, kacst-one, samyak, samyak-fonts, tibetan-machine, wqy-zenhei;
  ancient-scripts has Symbola (George Douros; versions after 2017 have a
  restrictive licence: check which). Upstream has a `feat/missinglicences`
  branch. Many of these exist as separate font packages: could be replaced by
  system fonts (allfontsgen can scan /usr/share/fonts).
- dictionaries (hunspell dictionaries, various licences incl. GPL/LGPL/MPL),
  document-templates (Apache-2.0), document-formats (Apache-2.0).
- document-server-package: deb/rpm/exe packaging; m4 templates for systemd
  units, nginx confs, helper scripts. The recipe renders the nginx confs and
  documentserver-generate-allfonts.sh from it.
- document-server-integration: example apps (Node, PHP, Java, ...). Not
  packaged.

### Network during upstream's build, and how it is pinned here

| what | upstream | here |
|---|---|---|
| core third party | git clones in build_3rdparty.py | pinned tarballs / snapshot / system libs |
| V8 + deps | depot_tools, gclient, CIPD, hooks | snapshot:euro-office |
| vcpkg | git clone + registry | not used |
| npm (sdkjs, web-apps, server) | npm ci / npm install | npmdeps (+ recipe lockfiles) |
| sharp 0.32 prebuilt libvips | prebuild-install download | built from source |
| pkg Node binaries | pkg-fetch | not used |
| Qt (desktop) | aqtinstall from download.qt.io | system qt6 (see 3) |
| CEF (desktop) | Spotify CDN prebuilt | open (see 3) |

## 3. Desktop Editors (not written)

- Repos: desktop-sdk (ChromiumBasedEditors: the Qt/CEF glue library and the
  AI-agent plugin, has npm lockfiles), desktop-apps (win-linux Qt app,
  common/loginpage built with npm), plus the shared core/sdkjs/web-apps
  (sdkjs and web-apps built with SDK_PLATFORM=desktop / --desktop=true).
- Qt: 6.10.1 via aqtinstall (prebuilt); components Core Gui Widgets
  PrintSupport Svg LinguistTools Multimedia MultimediaWidgets OpenGLWidgets +
  private modules. The tree has qt6 6.12.0: usable (private headers are in
  qt6-qtbase-devel? check), a QT6_ROOT override exists.
- CEF: **9.3.6 (and 9.3.8-rc.1) use CEF 109.1.18 (Chromium 109, Jan 2023)**,
  downloaded prebuilt from cef-builds.spotifycdn.com (glibc). Euro-Office
  main switched to CEF 156.0.15 (Chromium 156) on 2026-10-31
  (core#206, desktop-apps#109), plus a Wayland/X11 fix still open
  (desktop-apps#126).
  - The tree's chromium is 157.0.8103.38. CEF is Chromium + CEF's own
    patches + its own GN targets, built by CEF's automate-git.py against an
    exact Chromium version: it cannot be taken from packages/c/chromium's
    binaries. A `cef` recipe could reuse that recipe's source handling,
    musl/system-lib patches and GN setup, with CEF's branch for 157 (7xxx)
    applied on top: a second full Chromium build, plus desktop-sdk patched
    for CEF 157's API if main targets 156.
  - CEF 109 from source: no (two-year-old Chromium, would need its own
    musl/LLVM-23 patch set).
  - Therefore Desktop Editors waits for: a release on CEF 156+ (likely the
    next one), then a cef recipe at the matching Chromium (or the tree's
    chromium moved to CEF's version).
- Also: libvlc prebuilt in core (media player): system vlc would be needed
  (the tree has no vlc).

## 3b. Libera Suite: the desktop app instead (recipe written)

Libera Suite (Abilian, docs.liberasuite.eu, github.com/abilian/libera-suite)
runs Euro-Office's editors in a GTK 3 + WebKitGTK window (pywebview), with a
Python host (Apache-2.0) that implements `window.AscDesktopEditor` over a
loopback HTTP server and runs x2t for every open/save/print. No CEF, no Qt.
This replaces DesktopEditors for FenrirOS: packages/l/libera-suite (0.7.0,
payload 0.7.1), plus new python-pywebview 6.2.1, python-proxy-tools 0.1.0,
python-bottle 0.13.4.

- Releases: PyPI is authoritative (libera 0.7.0 = host sdist; libera-core
  0.7.1 = sdist with pins.toml, the patch queues and the build scripts, plus
  prebuilt glibc x2t wheels; libera-web 0.7.1 = wheel only, the built
  editors). GitHub main is behind (0.7.0b1, 7 core patches and 1 web-apps
  patch fewer, no 0.6/0.7 tags), so the recipe takes both sdists from PyPI.
- Pins (build/upstream/pins.toml): core 5a33ce6, sdkjs 0cde84e, web-apps
  51c706e (Euro-Office DesktopEditors 9.3.5-2), core-fonts 2de9068,
  document-templates 5548517, dictionaries 08d46f8, libxml2 2.9.14 (7846b0a,
  replacing core's ~2.9.4 copy: billion-laughs).
- Patch queue: 112 core (ODF reader/writer fixes, PDF password/forms,
  signatures and `libera-sign`, hostile-document fixes, CSV/RTF/Unicode,
  a DOCTRENDERER_CACHE_DIR the host uses), 5 sdkjs, 13 web-apps, 2 libxml2.
  All apply with `git apply` to the pinned trees (checked here); one
  web-apps patch deletes binary favicons, so `patch` alone cannot apply it.
- Reuse decision: Libera **builds its own payload**, not euro-office-core /
  -documentserver: other pins (9.3.5-2 vs 9.3.7-1), its patches are needed
  by the host (0034, 0190) and the editors must be built with
  SDK_PLATFORM=desktop (the Document Server builds the server platform).
  Carrying Libera's 130 patches in euro-office-core would change the Document
  Server's converter too and would need a rebase onto 9.3.7-1 (not tried to
  completion). Shared: euro-office-v8 (core 5a33ce6 pins the same V8 8.9.45 and
  GN 281ba2c), the system ICU/Boost/OpenSSL approach (its own copy of the
  patch, files/fenriros-system-libraries.patch, on top of Libera's queue;
  Libera's 0024 already provides EO_CORE_OPENSSL_DIR), and the third-party
  source pins (brotli is a47d747 at this core, not db24a98).
- Host install: the libera sdist with pip on the system Python;
  /usr/bin/libera sets LIBERA_PAYLOAD=/usr/lib/libera-suite/payload (the
  host's own setting for a payload folder) and runs `python3 -m libera`;
  desktop entry and icon system-wide. The payload is laid out as dist.sh
  stages it (bin/ with x2t, libera-sign, tools/allfontsgen and a relative
  DoctRenderer.config; sdkjs, web-apps, empty, dictionaries, fonts-src,
  payload.json with the source pins). The host makes the font index and V8
  code cache per user in ~/.local/share/libera.
- Changes: the update check (daily request to cdn.abilian.com) is opt-in
  (sed in setup); the "libera" web-apps theme is not public, so the editors
  carry Euro-Office's theme (THEME=euro-office); sdkjs's checked-in wasm
  used.
- Python deps in the tree: python-gobject, webkitgtk (2.54, GTK3, soup3 =
  WebKit2 4.1, what the host asks for first), gtk+3, python-typing-extensions;
  added pywebview (its sdist's Windows/Android binaries removed),
  proxy_tools, bottle. No uv, no wheels.

## 4. Licences, prebuilt binaries, branding

- Code: AGPL-3.0-only (Euro-Office removed ONLYOFFICE's Section 7 "logo"
  additional terms: scripts/strip-logo-clause-*), GUI elements/icons and
  texts CC-BY-SA-4.0 (per the headers); third-party list in each repo's
  3DPARTY.md (core: boost, icu, freetype, harfbuzz, hyphen MPL, hunspell
  MPL, gumbo, katana, cximage (own licence), openjpeg, socket.io, curl,
  cryptopp, openssl, v8, brotli, cef, glew, ixwebsocket, libheif, libde265
  LGPL, libvlc LGPL, md4c, pole, x265 GPL (desktop), glm, mdds, librevenge,
  libodfgen, libetonyek MPL (Apple formats)).
- Prebuilt in the sources: sdkjs wasm modules (kept), libvlc (not
  installed), web-apps' mobile output copied from the tree (deploy-mobile),
  sharp's npm platform packages for the web-apps build, node-oracledb
  binaries (removed).
- Fonts: see core-fonts above (missing licence files; Symbola).
- Branding/trademark: ONLYOFFICE is a trademark of Ascensio System SIA;
  Euro-Office already rebrands (THEME=euro-office, COMPANY_NAME=Euro-Office)
  and nothing in the recipes uses the ONLYOFFICE name except upstream file
  names (onlyoffice-docs-formats.json) and default DB names in default.json.
  The "Euro-Office" name/logo: no trademark policy found in the org.

## 5. Recipe split and order

1. euro-office-v8 (snapshot; build-only static library).
2. euro-office-core (needs euro-office-v8, boost, icu, openssl, zlib).
3. euro-office-documentserver (needs euro-office-core at build for
   allfontsgen, libvips; npmdeps).
4. Later: euro-office-core-wasm (emscripten; replaces sdkjs's checked-in
   wasm), unbundling core's in-tree libraries, rabbitmq-server (Erlang +
   Elixir), cef + euro-office-desktopeditors.

## Open questions for the user

1. V8 8.9.45 (2021) is what 9.3.7-1 needs; main has V8 14.6. Package
   9.3.7-1 now (expect V8 fixes for LLVM 23) or wait for the release with
   V8 14.6 / package a main snapshot?
2. RabbitMQ: the Document Server needs it (or ActiveMQ). Add Erlang + Elixir +
   rabbitmq-server recipes?
3. sdkjs's checked-in WebAssembly (from ONLYOFFICE): keep, or build
   euro-office-core-wasm with emscripten?
4. sharp's prebuilt musl packages (incl. libvips) for web-apps' build-time
   image optimisation: keep (as esbuild/rollup elsewhere), or build sharp
   from source there too?
5. core-fonts: several fonts without licence files, Symbola's licence; ship
   all, drop those, or use system font packages instead?
6. Core's in-tree copies of zlib, freetype, libpng, libjpeg, openjpeg,
   libxml2, ...: unbundle (CMake rewrites) or keep as upstream does?
7. Desktop Editors: Libera Suite is written as FenrirOS's desktop app; drop
   the CEF-based DesktopEditors plan (a CEF 156+ build from source, a second
   Chromium build), or keep it for later?
9. Libera's own web-apps theme ("libera" artwork) is not in its public
   sources: ask Abilian for it, or keep Euro-Office's theme in the editors?
10. Libera's update check made opt-in: OK, or turn it off entirely?
8. Layout: upstream's /var/www/euro-office/documentserver kept (its config
   names those paths); OK?

## dkbuild issue found on the way

Two new snapshots fetched at the same time (each recipe still at the
placeholder sha256 of 64 zeros) share one temporary file,
`cache/sources/0000…0000.part`: the DocumentServer snapshot was stored under
a sha256 whose content was another agent's pve-qemu snapshot. The
DocumentServer tarball was then packed by hand with src/snapshot-git.sh to a
private path and put in cache/sources under its own sha256 (69ccd4b…). The
same run had also left four submodules (dictionaries, document-formats,
document-templates, sdkjs-forms) registered but not checked out after
GitHub's resets, and snapshot-git.sh still marked the work directory done;
fixed by hand with `git submodule update --force`. Suggested fixes: name the
.part after the snapshot id, not the recipe's sha256; have snapshot-git.sh
check that each submodule has its files.
