#!/usr/bin/env python3
# Points dependencies of a package.json that npm would clone from git at local
# directories instead: local-git-deps.py <package.json> name=file:<dir>...
# Each named dependency must exist in (dev)dependencies; the file is rewritten
# in place. A package-lock.json beside it loses its entries resolved from git
# (the named packages and their own git dependencies, such as webidl-tools'
# webidl2): npm would otherwise fetch those from GitHub as the lock says,
# instead of taking the local directories.
import json
import os
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

lock = os.path.join(os.path.dirname(path), "package-lock.json")
if os.path.exists(lock):
    with open(lock) as f:
        data = json.load(f)
    packages = data.get("packages") or {}
    drop = [k for k, v in packages.items() if str(v.get("resolved", "")).startswith("git+")]
    for k in drop:
        del packages[k]
    with open(lock, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"{lock}: dropped {', '.join(drop) or 'nothing'}")
