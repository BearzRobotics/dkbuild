#!/usr/bin/env python3
# cpan-order.py resolved.json sources.txt order.txt: dkbuild source lines and
# a dependency-first build order of the distributions resolve-cpan.py found.
import json, sys
d = json.load(open(sys.argv[1]))
mod2dist = {m: k for k, v in d.items() for m in v["modules"]}
deps = {k: sorted({mod2dist[m] for m in v["deps"] if m in mod2dist and mod2dist[m] != k}) for k, v in d.items()}
order, state = [], {}
def visit(k, stack=()):
    if state.get(k) == 2: return
    if state.get(k) == 1:
        print("cycle:", " -> ".join(stack + (k,)), file=sys.stderr); return
    state[k] = 1
    for x in deps[k]: visit(x, stack + (k,))
    state[k] = 2; order.append(k)
for k in sorted(d): visit(k)
with open(sys.argv[2], "w") as f:
    for k in sorted(d, key=str.lower):
        v = d[k]
        if not v.get("checksum"): print("no checksum:", k, file=sys.stderr)
        f.write(f'    {{ url = "{v["url"]}", sha256 = "{v["checksum"]}", unpack = false }},  # {k} {v["version"]}\n')
with open(sys.argv[3], "w") as f:
    f.write("# CPAN distributions in build order (dependencies first), as sources of this recipe\n")
    for k in order: f.write(d[k]["url"].rsplit("/", 1)[1] + "\n")
