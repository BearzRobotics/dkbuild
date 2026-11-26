#!/bin/sh
# `dkbuild prune` must not delete anything while it cannot see the whole tree: a recipe that fails to load would
# look like one that is gone, and its vendored dependencies (which may not be downloadable again) with it.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/prune
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" dkdemo >/dev/null 2>&1 || { echo "FAIL: building the test package"; exit 1; }
sed -i 's/^options = \["!check"\]$/options = ["!check", "cargodeps"]/' "$T/packages/d/dkdemo/package.toml"
grep -q cargodeps "$T/packages/d/dkdemo/package.toml" || { echo "FAIL: could not give the recipe cargodeps"; exit 1; }
# its vendored data, and an entry no recipe uses
mkdir -p "$T/cache/cargodeps" "$T/cache/crates/used-1111" "$T/cache/crates/unused-2222"
echo "used used-1111" > "$T/cache/cargodeps/$DEMO_SHA.list"
prune() { ./zig-out/bin/dkbuild --tree "$T" prune --key "$TEST_KEY" 2>&1; }

# 1. a typo in the recipe
cp "$T/packages/d/dkdemo/package.toml" "$T/recipe.good"
sed -i 's/^summary = /sumary = /' "$T/packages/d/dkdemo/package.toml"
OUT=$(prune) && { echo "$OUT"; echo "FAIL: prune ran with a recipe that does not load"; exit 1; }
[ -f "$T/cache/cargodeps/$DEMO_SHA.list" ] && [ -d "$T/cache/crates/used-1111" ] \
    || { echo "$OUT"; echo "FAIL: prune deleted the vendored data of a recipe that failed to load"; exit 1; }
echo "$OUT" | grep -q "sumary" || { echo "$OUT"; echo "FAIL: prune did not say what is wrong"; exit 1; }

# 2. fixed: only what nothing uses goes
cp "$T/recipe.good" "$T/packages/d/dkdemo/package.toml"
OUT=$(prune) || { echo "$OUT"; echo "FAIL: prune failed on a good tree"; exit 1; }
[ -d "$T/cache/crates/used-1111" ] && [ ! -e "$T/cache/crates/unused-2222" ] || { echo "$OUT"; echo "FAIL: prune kept or removed the wrong crates"; exit 1; }

# 3. a list that cannot be read: the store must not be pruned without it
mkdir -p "$T/cache/crates/unused-3333"
chmod 000 "$T/cache/cargodeps/$DEMO_SHA.list"
OUT=$(prune); RC=$?
chmod 644 "$T/cache/cargodeps/$DEMO_SHA.list"
{ [ "$RC" != 0 ] && [ -d "$T/cache/crates/used-1111" ]; } || { echo "$OUT"; echo "FAIL: prune went on without a dependency list it could not read"; exit 1; }
echo "ok: prune deletes nothing while a recipe or a dependency list cannot be read"
