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
