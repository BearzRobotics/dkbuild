#!/usr/bin/env python3
# Points dependencies of a package.json that npm would clone from git at local
# directories instead: local-git-deps.py <package.json> name=file:<dir>...
# Each named dependency must exist in (dev)dependencies; the file is rewritten
# in place.
import json
import sys

path = sys.argv[1]
with open(path) as f:
    pkg = json.load(f)
for arg in sys.argv[2:]:
    name, spec = arg.split("=", 1)
    found = False
    for key in ("dependencies", "devDependencies", "optionalDependencies"):
        deps = pkg.get(key) or {}
        if name in deps:
            deps[name] = spec
            found = True
    if not found:
        sys.exit(f"{path}: no dependency {name}")
with open(path, "w") as f:
    json.dump(pkg, f, indent=2)
    f.write("\n")
