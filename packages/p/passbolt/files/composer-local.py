#!/usr/bin/env python3
# Points every package of a composer.lock at its archive in a local directory,
# named by its commit (as the recipe's sources are), and drops the VCS
# fallback, so `composer install` reads the lock and never the network:
#   composer-local.py composer.lock /build/sources
import json
import os
import sys

lock_path, src_dir = sys.argv[1], sys.argv[2]
with open(lock_path) as f:
    lock = json.load(f)
n = 0
for pkg in lock.get("packages", []):
    dist = pkg.get("dist") or {}
    ref = dist.get("reference")
    path = os.path.join(src_dir, ref or "")
    if not ref or not os.path.isfile(path):
        sys.exit(f"{pkg['name']}: no archive {path}")
    dist["url"] = path
    dist["type"] = "zip"
    dist["shasum"] = ""
    pkg.pop("source", None)
    n += 1
with open(lock_path, "w") as f:
    json.dump(lock, f, indent=4)
    f.write("\n")
print(f"composer-local: {n} packages from {src_dir}")
