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

Written so far (2026-11-15): pgvector, sqlite-vec. Lomiri: survey in `lomiri/NOTES.md` (no recipes yet).
