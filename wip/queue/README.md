# Queue: recipes written outside the main tree

Recipes for the requested packages that are not part of the world build yet
(`docs/requests.md`, `docs/roadmap.md` "Applications"). dkbuild reads only
`packages/`, so nothing here builds in a world run. When the main tree builds
consistently, a recipe is moved to `packages/<letter>/<name>/`, fetched, built and
fixed there.

- Layout: `wip/queue/packages/<letter>/<name>/package.toml` (+ `patches/`, `files/`),
  as in `packages/`. `profiles`, `upstream.toml` and `keys` are links to the main
  tree's, so the tool can read this directory as a tree.
- Check a recipe: `./zig-out/bin/dkbuild --tree wip/queue check <name>`. (This checks
  the recipe's syntax and fields; it cannot check that the dependencies named in it
  exist in the main tree, nor that it builds.)
- A recipe here has its source checksum from a real download, but nothing else is
  tested: expect first-build fixes. Its header comment says "Not built (queued)".
- Shell fragments follow the same rules as in `packages/` (POSIX sh for dash, linted
  with shellcheck).
- Move with `git mv wip/queue/packages/x/name packages/x/name` and update this file.

Written so far (2026-11-15):
- pgvector, sqlite-vec.
- Qt 5.15 for Lomiri (KDE's 5.15 branch via Alpine's snapshots and patches; installs in /usr/lib/qt5 beside
  Qt 6): qt5-qtbase (clang mkspec), qt5-qtsvg, qt5-qtdeclarative, qt5-qtxmlpatterns, qt5-qtmultimedia,
  qt5-qtquickcontrols2, qt5-qtgraphicaleffects, qt5-qtwayland, qt5-qttools, qt5-qtsensors. Checked
  (recipe fields, Alpine's patches apply and match their checksums, qtbase's mkspec seds tried on the
  real files); nothing compiled. Still needed for Lomiri from Qt 5: qtfeedback, qtpim/qtcontacts,
  qtlocation, qtquickcontrols (1), qtscript? (to check against each Lomiri component).
- Lomiri: the stack of 78 recipes listed in `lomiri/NOTES.md` (Qt 5, foundation libraries, components, Mir, qtmir, the shell, indicators, settings, keyboard); what is left is the session (dinit), the telephony decision, the apps and branding.
