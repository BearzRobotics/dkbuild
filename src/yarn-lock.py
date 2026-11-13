#!/usr/bin/env python3
# dkbuild yarn-lock (SPEC.md 7.4): makes a recipe's files/yarn.package-lock.json
# from a project's yarn.lock, so the npm store (npmdeps) can fetch and check
# its packages. Embedded in dkbuild, run with the host's python3:
#
#   dkbuild yarn-lock <yarn.lock> [-o files/yarn.package-lock.json]
#
# yarn 1 lockfiles carry each package's tarball URL and integrity hash; they
# are copied. yarn 2+ ("berry") lockfiles carry neither (their checksums are of
# yarn's own zip files), so each `name@npm:version` resolution's tarball URL
# and sha512 integrity are read from the npm registry's metadata for that
# version, once, here; the fetch then checks the tarballs against them.
# Workspace, link, portal and file entries are the project's own; patch:
# entries are yarn's patches over another entry (which is listed). Git and
# URL resolutions cannot be pinned this way: they are reported and the
# command fails.
#
# The output has package-lock.json's shape (lockfileVersion 3, "packages"
# with resolved + integrity), which is all npmdeps reads. In the build, the
# store is served to yarn as a registry on 127.0.0.1 (pnpm-registry.js).
import concurrent.futures
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "dkbuild-yarn-lock/1"
REGISTRY = "https://registry.npmjs.org"


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError:
            raise
        except OSError:
            if attempt == 4:
                raise
            time.sleep(2 * (attempt + 1))


def entries(text):
    """(header, {key: value}) for each top-level entry of a yarn.lock."""
    out, head, body = [], None, {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            if head is not None:
                out.append((head, body))
            head, body = line.rstrip(":"), {}
        elif line.startswith("  ") and not line.startswith("   "):
            m = re.match(r"\s+([^:\s]+):?\s+(.*)$", line)
            if m:
                body[m.group(1).strip('"')] = m.group(2).strip().strip('"')
    if head is not None:
        out.append((head, body))
    return out


def v1(text):
    pkgs = {}
    for head, body in entries(text):
        url, integ, ver = body.get("resolved"), body.get("integrity"), body.get("version")
        if not url:
            continue
        url = url.split("#", 1)[0]
        name = re.match(r'"?(@?[^@"]+)@', head).group(1)
        if not integ:
            sys.exit(f"yarn-lock: {name} {ver} has no integrity hash in yarn.lock")
        pkgs[f"{name}@{ver}"] = (url, integ, ver)
    return pkgs


def berry(text):
    want, bad = {}, []
    for head, body in entries(text):
        if head.startswith("__metadata"):
            continue
        res = body.get("resolution", "")
        m = re.match(r"(@?[^@]+)@(\w+):(.*)$", res)
        if not m:
            continue
        name, proto, ref = m.groups()
        if proto in ("workspace", "link", "portal", "file", "patch"):
            continue
        if proto != "npm":
            bad.append(res)
            continue
        if ref.startswith("@") or ":" in ref:
            bad.append(res)  # an alias to another name or an odd reference
            continue
        want[f"{name}@{ref}"] = (name, ref)
    if bad:
        sys.exit("yarn-lock: resolutions that are not npm packages (pin them another way):\n  " + "\n  ".join(bad))

    def meta(item):
        key, (name, ver) = item
        d = get_json(f"{REGISTRY}/{urllib.parse.quote(name, safe='@')}/{ver}")
        dist = d["dist"]
        if "integrity" not in dist:
            sys.exit(f"yarn-lock: {name} {ver}: the registry gives no integrity hash")
        return key, (dist["tarball"], dist["integrity"], ver)

    pkgs = {}
    with concurrent.futures.ThreadPoolExecutor(16) as ex:
        for key, val in ex.map(meta, sorted(want.items())):
            pkgs[key] = val
            print(f"{key}", file=sys.stderr)
    return pkgs


def main():
    args = sys.argv[1:]
    out_path = None
    if "-o" in args:
        i = args.index("-o")
        out_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit("usage: dkbuild yarn-lock <yarn.lock> [-o files/yarn.package-lock.json]")
    with open(args[0]) as f:
        text = f.read()
    pkgs = berry(text) if "__metadata:" in text else v1(text)
    lock = {"name": "dkbuild-yarn-lock", "lockfileVersion": 3, "requires": True,
            "packages": {"": {}}}
    for key in sorted(pkgs):
        url, integ, ver = pkgs[key]
        lock["packages"][f"node_modules/{key}"] = {"version": ver, "resolved": url, "integrity": integ}
    text = json.dumps(lock, indent=1, sort_keys=False) + "\n"
    if out_path:
        with open(out_path, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    print(f"yarn-lock: {len(pkgs)} packages", file=sys.stderr)


if __name__ == "__main__":
    main()
