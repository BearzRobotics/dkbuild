# Work in progress

Recipes being ported that must not build yet (dkbuild only reads packages/).

- chromium: base for native Brave. Chimera lets two post_patch steps use the network (crubit via tools/rust/build_crubit.py, and `cargo build` of tools/crates/gnrt); those crates have to be vendored at fetch time first. Then brave-core on top.
- openjdk21: moved back to packages/ and ported (2026-11-09).
- electron 42.11.18 and code-oss 1.138.0: moved to packages/ (2026-11-11) for their first fetch; Electron 43 and the newest Code - OSS come after these build.

Requested software that is not a recipe yet, and what each needs (2026-11-10):

- metasploit: written (2026-11-10) with the gem store (`gemdeps`).
- frida: its build downloads a prebuilt toolchain and SDK (glibc) from
  build.frida.re; on musl both have to be built from source first
  (releng/deps.py), as a snapshot.
- anki: its build (a Rust "ninja" runner) downloads Node, Python wheels and
  crates as it goes; needs a snapshot that pre-runs those, or the npm, crate and
  Python stores wired into its build.
- geogebra: the GitHub repository is a mirror of a large Gradle/GWT web build;
  the desktop app is an Electron shell (waits on electron).
- euro-office: an OnlyOffice fork (~30 repositories; core builds V8 and Qt
  pieces with downloads). A snapshot of its build-tools checkout first.
- brave: chromium (here in wip) plus brave-core on top; with electron's snapshot
  tooling, a `snapshot:brave` for brave-browser's gclient checkout.
- pdfium: a gclient checkout like Chromium's (snapshot:electron's approach).
- mattercontrol: no longer builds for Linux (net6.0-windows, WinForms). Options:
  Wine, or the old 1.7.x on Mono (no Mono in the tree).

From the IT list (2026-11-10):

- openkiosk: an application directory (codeberg.org/openkiosk_mirror/openkiosk_src,
  no tags: pin a commit) placed into the Firefox source tree, plus
  openkiosk-core-changes.patch from openkiosk_build, built with
  --enable-application=openkiosk. It tracks mozilla-release, the branch our
  firefox recipe builds: derive the recipe from firefox's.
- rustdesk (client): the desktop app is Flutter, whose SDK ships only glibc
  builds (the older Sciter UI needs a prebuilt glibc library). rustdesk-server
  (hbbs/hbbr) is written.
- bitwarden desktop: Electron (waits on electron). The official server
  needs Microsoft SQL Server; vaultwarden is written and the Bitwarden apps
  work with it.
- keepass2: a .NET Framework WinForms program, on Linux only through Mono (not
  in the tree; Alpine packages mono for musl). KeePassXC is written.

From the education list (2026-11-11). Written: GCompris, Tux Paint (+stamps),
Tux Math, Tux Typing, BamBam, KAlgebra, KmPlot, Qalculate!, Stellarium, KStars,
Kalzium, FreeCAD, KLettres, Parley, Kiten, Klavaro, Marble, KGeography; games
0 A.D., DOSBox Staging, Prism Launcher (Minecraft). Not yet:

- phet: PhET's HTML5 simulations are single files
  (phet.colorado.edu/sims/html/<sim>/<version>/<sim>_all.html, CC-BY-4.0, all
  languages inside). A recipe with one source per simulation, pinned by
  version, an index page and a desktop entry that opens it in the browser.
  Needs the list of simulations and their current versions first.
- scratch: Scratch Desktop is an Electron app (waits on electron). Without
  Electron: scratch-gui built to static files (npm store) and opened in
  Firefox, like PhET.
- gdevelop: an Electron app (newIDE/electron-app; waits on electron).
- childsplay: dead since 2013, Python 2 and pygame 1; GCompris covers its
  activities. Not planned.
- gbrainy: C# on Mono (GTK#); waits on Mono, like KeePass 2.

Optional features the early, minimal recipes still leave out (from a sweep
against Chimera's templates, 2026-11-11; the desktop-critical ones are done):

- Done 2026-11-11: curl (HTTP/3, c-ares, brotli, LDAP, GSSAPI), elfutils
  debuginfod (+ libmicrohttpd), gtk4 colord/sysprof/iso-codes (GTK 4.24 has no
  ffmpeg backend any more; libtiff is required there now), gtk+3 iso-codes,
  avahi-ui (avahi's GTK and Python parts, split out because of the cups cycle).
- PAM in cups, heimdal, kbd, qemu, samba, shadow: deliberately off (login
  stays shadow-based); revisit only if a feature needs it.
- gnutls: unbound (DANE). libgit2: libssh2, heimdal. rsync: acl. re2,
  libpsl, icu extras. frei0r, mlt, openimageio: opencv. sane-backends:
  libgphoto2, v4l-utils. wine: samba (NTLM). (Done 2026-11-11: lcms2 with TIFF
  and its utilities, libwebp-tools, transmission's Qt client.)
- PipeWire: libmysofa, libcamera, ROC (no recipes yet). LDAC (ldacbt) and
  WebRTC echo cancelling (webrtc-audio-processing) were added 2026-11-11.
- android-tools: adb's mDNS discovery is on (2026-11-11): the
  `cargolock=<dir>` option vendors from the Cargo.lock a recipe keeps in
  files/ (made once with cargo generate-lockfile, then pinned).
