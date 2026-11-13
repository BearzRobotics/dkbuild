#!/usr/bin/env python3
# dkbuild hackage-lock (SPEC.md 7.4): writes a recipe's files/hackage.lock from
# a cabal freeze file (`cabal freeze`'s cabal.project.freeze, or Stackage's
# cabal.config), or from plain "<name> <version>" / "<name>-<version>" lines.
# Embedded in dkbuild, run with the host's python3:
#
#   dkbuild hackage-lock <freeze file> [-o files/hackage.lock]
#
# For every pinned package: the tarball from Hackage (into cache/hackage/, as
# the fetch would put it) and its sha256, and the newest revision of its
# .cabal with that revision's sha256 (Hackage's revisions list). The packages
# GHC itself provides (base, ghc-prim, ...) are left out: they are never
# downloaded. Flags and other freeze settings are not part of the lock; a
# recipe passes flags to cabal itself.
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

UA = "dkbuild-hackage-lock/1"
HACKAGE = "https://hackage.haskell.org/package"
# Shipped with GHC and not buildable from Hackage (or not on it).
GHC_ONLY = {"base", "ghc", "ghc-prim", "ghc-bignum", "ghc-internal", "ghc-boot", "ghc-boot-th",
            "ghc-heap", "ghci", "integer-gmp", "rts", "template-haskell", "ghc-platform",
            "ghc-toolchain", "system-cxx-std-lib", "ghc-experimental", "ghc-compact"}


def get(url, accept=None):
    """Retried: Hackage downloads break off now and then (IncompleteRead, DNS)."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, **({"Accept": accept} if accept else {})})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, http.client.HTTPException, OSError):
            if attempt == 4:
                raise
            time.sleep(3 * (attempt + 1))


def pins(text):
    out = {}
    for m in re.finditer(r"(?:any\.)?([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*([0-9][0-9.]*)", text):
        out[m.group(1)] = m.group(2)
    if out:
        return out
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            out[parts[0]] = parts[1]
        else:
            m = re.fullmatch(r"(.+)-([0-9][0-9.]*)", parts[0])
            if m:
                out[m.group(1)] = m.group(2)
    return out


def main():
    args = sys.argv[1:]
    cache = args.pop(0)
    out_path = None
    if "-o" in args:
        i = args.index("-o")
        out_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit("usage: dkbuild hackage-lock <freeze file> [-o files/hackage.lock]")
    with open(args[0]) as f:
        want = pins(f.read())
    store = os.path.join(cache, "hackage")
    os.makedirs(store, exist_ok=True)
    lines = ["# made by dkbuild hackage-lock from " + os.path.basename(args[0]),
             "# <name> <version> <tarball sha256> <revision> <revised .cabal sha256 or ->"]
    for name in sorted(want, key=str.lower):
        ver = want[name]
        if name in GHC_ONLY:
            continue
        pid = f"{name}-{ver}"
        tb = os.path.join(store, pid + ".tar.gz")
        if not os.path.exists(tb):
            data = get(f"{HACKAGE}/{pid}/{pid}.tar.gz")
            with open(tb + ".part", "wb") as f:
                f.write(data)
            os.replace(tb + ".part", tb)
        with open(tb, "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        revs = json.loads(get(f"{HACKAGE}/{pid}/revisions/", "application/json"))
        last = max(revs, key=lambda r: r["number"]) if revs else {"number": 0}
        if last["number"] == 0:
            lines.append(f"{name} {ver} {sha} 0 -")
        else:
            cf = os.path.join(store, f"{pid}-r{last['number']}.cabal")
            if not os.path.exists(cf):
                data = get(f"{HACKAGE}/{pid}/revision/{last['number']}.cabal")
                with open(cf + ".part", "wb") as f:
                    f.write(data)
                os.replace(cf + ".part", cf)
            with open(cf, "rb") as f:
                csha = hashlib.sha256(f.read()).hexdigest()
            if csha != last["sha256"]:
                sys.exit(f"{pid}: revision {last['number']} does not match Hackage's sha256 for it")
            lines.append(f"{name} {ver} {sha} {last['number']} {csha}")
        print(f"{pid} r{last['number']}", file=sys.stderr)
    text = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
