# Lomiri (UBports desktop shell): survey, 2026-11-15

Source of the facts below: the `debian/control` of gitlab.com/ubports/development/core/lomiri
(main, tag 0.6.2 is the newest), the project list of the `core` group (about 100 repositories,
all active in November 2026), read once; nothing here has been built or checked against a
checkout. Treat the dependency list as a first guess to verify package by package.

## What the shell build needs (Build-Depends of lomiri 0.6.2)

- **Qt 5** (not packaged here): qtbase (with private headers), qtdeclarative (private headers),
  qtsvg, qtxmlpatterns, qtmultimedia, QtQuick Controls and the QML modules
  (folderlistmodel, settings, statemachine, layouts, xmllistmodel), Qt SQL SQLite driver.
  More Qt 5 modules come with the other components (qtwayland, qtsensors, qtfeedback,
  qtpim/qtcontacts, qtlocation, qttools, qtgraphicaleffects).
- **Mir** (mir 2.x with MirAL and Miroil) and **qtmir** (the Qt 5 platform plugin that makes
  Lomiri a Mir shell). Mir needs wayland, EGL/GLES and libevdev/udev, boost, protobuf, yaml-cpp.
- **PAM** (libpam) and **LightDM** (liblightdm-qt5): the lock screen and the greeter. This
  system has no PAM (it logs in on dkconsole/greetd); see the decision below.
- **systemd** (libsystemd-dev) and **udev**: logind session integration. elogind is in the tree
  (it provides sd-login), systemd itself is not and will not be; what Lomiri uses beyond
  sd-login has to be checked.
- Lomiri's own libraries: lomiri-api, lomiri-schemas, lomiri-app-launch, lomiri-ui-toolkit
  (the QML components), lomiri-settings-components, lomiri-url-dispatcher, lomiri-thumbnailer,
  lomiri-indicator-network and the Ayatana indicators, lomiri-connectivity-qt,
  lomiri-shell-notifications, liblomirigestures, deviceinfo, libusermetrics, geonames,
  gsettings-qt, qmenumodel, qqc2-suru-style, suru icons, lomiri-wallpapers, cmake-extras,
  dbus-test-runner, qtdbustest and qtdbusmock (test helpers the build asks for).
- Small system libraries: glib, libgnome-desktop-4, libpulse, libudev, libevdev, libx11, libxcb, libxi, xwayland.
- AppArmor (dh-apparmor) only as a Debian packaging helper: optional.

## Around the shell (separate repositories in the group)

lomiri-keyboard (on-screen keyboard, on maliit-framework), lomiri-system-settings
(+ plugins), lomiri-content-hub, lomiri-download-manager, lomiri-history-service,
media-hub, repowerd (power management), trust-store, biometryd, process-cpp and net-cpp,
ciborium, lomiri-online-accounts, the apps (mediaplayer, addressbook, messaging, printing,
morph-browser: needs QtWebEngine 5, very large; skipped at first), phone-only parts
(telephony-service, ofono, nfcd, android/hybris platform support: not wanted on a PC).

## Order I would write them in

1. Qt 5 base set (qtbase, qtdeclarative, qtsvg, qtxmlpatterns, qtmultimedia, qtquickcontrols2,
   qtgraphicaleffects, qtwayland, qttools, qtsensors), plus the small helpers
   (cmake-extras, gsettings-qt, qmenumodel, dbus-test-runner, libqtdbustest/qtdbusmock).
2. lomiri-api, lomiri-schemas, deviceinfo, geonames, libusermetrics, lomiri-ui-toolkit,
   lomiri-url-dispatcher, lomiri-app-launch, lomiri-thumbnailer.
3. Mir 2.x + MirAL/Miroil, qtmir.
4. The login and session side (see the decision).
5. lomiri itself, then keyboard, settings, indicators, content-hub, download-manager, apps.

## Decisions needed from the user (asked 2026-11-15)

- **PAM:** Lomiri's lock screen and greeter use PAM and LightDM. Options: (a) package linux-pam
  and LightDM just for Lomiri (PAM would be a new part of the system), (b) patch the shell to
  authenticate through another way (more work, a fork to maintain), (c) run Lomiri on its own
  without lock screen authentication (not a real desktop).
- **systemd pieces:** check how much of logind/user-session behaviour elogind covers; the
  Alpine/postmarketOS Lomiri packages run on OpenRC and are a useful reference for the
  non-systemd path.
- **Qt 5 scope:** Qt 5 stays only for Lomiri (the tree is Qt 6 for dkde); QtWebEngine 5
  (morph-browser) is left out.

## Update 2026-11-15 (later): what Alpine's packaging showed, and what is written

Alpine Linux (testing/ and community/, postmarketOS's route) packages Lomiri 0.6.2 on musl, with
elogind and no systemd, and with a patch that disables the LightDM integration. So the earlier
open questions are settled: **no LightDM** is needed, the shell uses PAM (linux-pam, now adopted
system-wide: docs/pam-qemu-test.md), and the systemd pieces are patched out (Alpine's
`0003-No-systemd.patch`, `-DUSE_SYSTEMD=OFF` in the services, lomiri-url-dispatcher's
`remove-systemd.patch`). The recipes follow Alpine's, with its patches (checksums verified).

Written in `wip/queue/packages/` (none built; each passes `dkbuild --tree wip/queue check`):

- Qt 5.15 (KDE branch): qt5-qtbase (clang mkspec), svg, declarative, xmlpatterns, multimedia,
  quickcontrols, quickcontrols2, graphicaleffects, wayland, tools, sensors, location, pim, systems, feedback.
- Foundation libraries: cmake-extras, properties-cpp, process-cpp, net-cpp, dbus-cpp, dbus-test-runner,
  gsettings-qt, libqtdbustest, libqtdbusmock, geonames, lomiri-schemas, lomiri-api, qmenumodel,
  libayatana-common, lomiri-url-dispatcher, lomiri-deviceinfo, lomiri-libusermetrics, libapparmor
  (library only), libnih, leveldb, persistent-cache-cpp, click, telepathy-glib, raptor2,
  python-isodate, python-rdflib, zeitgeist.
- Lomiri components: lomiri-ui-toolkit, lomiri-ui-extras, qqc2-suru-style, suru-icon-theme,
  lomiri-settings-components, lomiri-sounds, lomiri-app-launch, lomiri-trust-store,
  lomiri-download-manager, lomiri-content-hub, lomiri-thumbnailer, lomiri-notifications,
  repowerd, biometryd.
- The compositor: mir 2.28 (Rust parts through cargodeps; its Wayland generator uses libxml++2, in the tree) and qtmir.

Still to write for a working shell: **lomiri** itself (0.6.2; Alpine's seven patches), lomiri-indicator-network
(Qt 5, NetworkManager, ofono-less?), lomiri-system-settings (+ its plugins; it is a *build* dependency of
lomiri), the Ayatana indicators (session, power, datetime, display, sound, keyboard, bluetooth, messages,
notifications), the on-screen keyboard (maliit-framework, lomiri-keyboard), gsettings-desktop-schemas
and gnome-desktop checks, accountsservice, lomiri-telephony-service (a runtime dependency of the shell
in Alpine; phone features: telepathy-qt, ofono, history-service, libphonenumber; to be made optional
or written), wallpapers and the session scripts (a dinit service and a Wayland session entry), the
apps (calculator, clock, terminal, gallery, docviewer, filemanager, weather), and the Mir
EGL/GBM platform check on this Mesa. Packages Alpine has that this tree does not: libucontext (not
needed: capnproto is not used by Mir 2.28's build), umockdev/py3-dbusmock (tests only, tests are off).

## Update 2026-11-15 (end): the shell itself is written

Added: lomiri 0.6.2 (Alpine's seven patches, `-DNO_TESTS=ON`), lomiri-system-settings (Alpine's two patches),
lomiri-indicator-network (needs ofono and libqofono: written, with ell, which ofono wants), the Ayatana
indicators (session, power, datetime, display, sound, keyboard, bluetooth, messages, notifications; librda),
maliit-framework and maliit-keyboard (without presage word prediction and without the anthy and libpinyin
engines, which are not packaged), libqofono, ofono (inert: no dinit service). 78 recipes in all; every name in
their build, host and run dependencies resolves to a recipe in `packages/` or `wip/queue/` (checked by script),
none has been built.

Still open before a Lomiri session can start (not recipes of upstream software):
- **lomiri-telephony-service** and **lomiri-history-service** (Alpine's lomiri depends on the telephony service;
  they pull telepathy-qt, telepathy-mission-control, libphonenumber, qtpim/qtfeedback (written)): decide to
  drop the runtime dependency (Lomiri starts without phone features) or write them.
- A **dinit session**: a service that starts the D-Bus session bus, the indicator services, lomiri-thumbnailer,
  lomiri-url-dispatcher, repowerd and the shell on a seat (seatd/elogind), and a Wayland session entry for
  greetd/SDDM; Alpine's `ubuntu-touch-session` (ubports/core/ubuntu-touch-session) is the starting point.
- **gsettings-desktop-schemas, gnome-desktop-4, accountsservice, upower, polkit agent**: in the tree; check that
  gnome-desktop provides gnome-desktop-4.pc.
- Lomiri's **wallpapers** and a **FenrirOS launcher logo** (Alpine replaces Ubuntu's `home.svg`).
- The **apps** (lomiri-calculator-app, clock, terminal, gallery, docviewer, filemanager, weather, mediaplayer,
  morph-browser needs QtWebEngine 5: skipped) follow Alpine the same way.
- Missing optional pieces named in the recipes: presage, anthy, libpinyin (maliit-keyboard), AppArmor itself
  (libapparmor only), FreeTDS (qt5-qtbase's TDS plugin).

## Update 2026-11-15 (session and apps)

Written: `lomiri-session` (our own script, no systemd: the environment of Lomiri's wrapper, a D-Bus
session, the indicator services in the background, the shell in the foreground; dash- and shellcheck-clean;
plus the `lomiri.desktop` Wayland session entry), `desktop-lomiri` (the meta package, as desktop-dkde is),
and the apps calculator, clock (+ u1db-qt), terminal (+ qmltermwidget) and filemanager. 85 recipes in all.

Left out on purpose: lomiri-docviewer-app (needs poppler's Qt 5 binding and LibreOfficeKit), lomiri-gallery-app
(libmediainfo, not packaged), lomiri-weather-app and morph-browser (QtWebEngine 5), lomiri-camera-app,
lomiri-telephony-service / history-service (phone). repowerd is a system service with no dinit file yet.
First build will tell about everything else: the indicator service paths in the session script, the apps'
libintl links (Alpine's patches), and Mir on this Mesa (EGL/GBM).

## Update 2026-11-15 (telephony, input engines)

Added: telepathy-farstream, telepathy-qt (Qt 5), telepathy-mission-control, lomiri-history-service and
lomiri-telephony-service (a runtime dependency of the shell on Alpine; now in lomiri's and desktop-lomiri's
rundeps, as Alpine has it: the shell starts without a modem or a Telepathy connection manager), and the maliit keyboard's
optional engines: presage (word prediction), anthy (Japanese), libpinyin (+ kyotocabinet) (Chinese), so maliit-keyboard
is built with all of them. qt5-qtbase now builds the TDS plugin (freetds). libphonenumber and libieee1284 are in
too (the second is for dosemu2). 129 recipes in the queue.
