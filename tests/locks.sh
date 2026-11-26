#!/bin/sh
# Two dkbuild processes must not build in one tree at once: the second would delete the first's build directory and
# share its half-written packages, and prune would delete what a build is using.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/locks
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
sed -i 's/^llvm-ar rcs libdkdemo.a dkdemo_s.o$/&\nsleep 6/' "$T/packages/d/dkdemo/package.toml"
./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" dkdemo > "$T/first.log" 2>&1 &
FIRST=$!
i=0; while ! grep -q 'building' "$T/first.log" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
fail=0
OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" dkdemo 2>&1) && { echo "FAIL: a second build ran in the tree during the first"; fail=1; }
echo "$OUT" | grep -q 'another dkbuild' || { echo "$OUT" | tail -4; echo "FAIL: the second build did not say why it stopped"; fail=1; }
OUT=$(./zig-out/bin/dkbuild --tree "$T" prune --key "$TEST_KEY" 2>&1) && { echo "FAIL: prune ran during a build"; fail=1; }
wait "$FIRST" || { tail -8 "$T/first.log"; echo "FAIL: the first build was disturbed"; fail=1; }
./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" dkdemo >/dev/null 2>&1 || { echo "FAIL: the lock outlived the build"; fail=1; }
./zig-out/bin/dkbuild --tree "$T" prune --key "$TEST_KEY" >/dev/null 2>&1 || { echo "FAIL: prune did not run afterwards"; fail=1; }
[ $fail = 0 ] && echo "ok: one build or prune per tree at a time"
exit $fail
