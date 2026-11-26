#!/usr/bin/env python3
# dkbuild python-lock (SPEC.md 7.4): writes a recipe's files/python.lock from
# a project's lockfile. Embedded in dkbuild, run with the host's python3:
#
#   dkbuild python-lock <uv.lock | pylock.toml | requirements.txt> [-o files/python.lock]
#
# Input:
#   uv.lock          uv's lockfile (sdist and wheel URLs with sha256)
#   pylock.toml      PEP 751 lockfiles (pdm, pip lock, uv export)
#   anything else    requirements lines pinned with ==  (pip-compile, poetry
#                    export, `pip freeze`); the files' sha256 come from PyPI.
#
# Which file is pinned for each package: the pure-Python wheel
# (py3-none-any / py2.py3-none-any) when there is one, since it holds the
# same Python files as the source; otherwise the source distribution, which
# the build compiles. Packages with neither (Windows- or macOS-only ones in a
# cross-platform lock) are left out with a note. The project itself (uv's
# editable/virtual entries) is not a dependency and is skipped.
#
# For each source distribution the lock gets a comment with its
# build-system.requires (read from the sdist's pyproject.toml, as data): the
# build runs pip without build isolation, so those build tools must be
# hostdeps (python-setuptools, python-hatchling, maturin, ...) or pinned in
# the lock too.
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import time
import tomllib
import urllib.error
import urllib.request
import zipfile

UA = "dkbuild-python-lock/1"
PYPI = "https://pypi.org/pypi"
# requirement markers for systems that are not FenrirOS
FOREIGN = re.compile(r"""(sys_platform|platform_system|os_name)\s*==\s*['"](win32|cygwin|darwin|Windows|Darwin|nt)['"]""")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError:
            raise
        except OSError:
            if attempt == 4:
                raise
            time.sleep(3 * (attempt + 1))


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def pure_wheel(fname):
    m = re.search(r"-([^-]+)-([^-]+)-([^-]+)\.whl$", fname)
    return bool(m) and m.group(3) == "any" and m.group(2) == "none" and m.group(1) in ("py3", "py2.py3")


def choose(name, version, sdist, wheels):
    """sdist: (url, sha) or None; wheels: [(url, sha)]. Returns (url, sha) or None."""
    for url, sha in wheels:
        if pure_wheel(url.rsplit("/", 1)[-1]):
            return url, sha
    return sdist


def from_uv(text):
    data = tomllib.loads(text)
    out = []
    for p in data.get("package", []):
        src = p.get("source", {})
        if "registry" not in src:
            continue  # the project itself, path or git dependencies
        sd = p.get("sdist")
        sdist = (sd["url"], sd["hash"].split(":", 1)[1]) if sd and "url" in sd else None
        wheels = [(w["url"], w["hash"].split(":", 1)[1]) for w in p.get("wheels", []) if "url" in w]
        out.append((p["name"], p["version"], sdist, wheels))
    return out


def from_pylock(text):
    data = tomllib.loads(text)
    out = []
    for p in data.get("packages", []):
        if "version" not in p:
            continue
        marker = p.get("marker", "")
        if marker and FOREIGN.search(marker) and "linux" not in marker:
            continue
        sd = p.get("sdist")
        sdist = (sd["url"], sd["hashes"]["sha256"]) if sd and sd.get("url") else None
        wheels = [(w["url"], w["hashes"]["sha256"]) for w in p.get("wheels", []) if w.get("url")]
        out.append((p["name"], p["version"], sdist, wheels))
    return out


def from_requirements(text):
    out = []
    for raw in text.replace("\\\n", " ").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        req, _, marker = line.partition(";")
        if marker and FOREIGN.search(marker):
            continue
        m = re.match(r"([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*==\s*([^\s;]+)", req.strip())
        if not m:
            sys.exit(f"python-lock: not pinned with ==: {line}")
        name, ver = m.group(1), m.group(3)
        info = json.loads(get(f"{PYPI}/{name}/{ver}/json"))
        sdist, wheels = None, []
        for f in info["urls"]:
            if f.get("yanked"):
                continue
            if f["packagetype"] == "sdist":
                sdist = (f["url"], f["digests"]["sha256"])
            elif f["packagetype"] == "bdist_wheel":
                wheels.append((f["url"], f["digests"]["sha256"]))
        out.append((name, ver, sdist, wheels))
    return out


def build_requires(data, fname):
    """build-system.requires from an sdist's top-level pyproject.toml (read as data)."""
    try:
        if fname.endswith(".zip"):
            z = zipfile.ZipFile(io.BytesIO(data))
            names = [n for n in z.namelist() if n.count("/") == 1 and n.endswith("/pyproject.toml")]
            raw = z.read(names[0]) if names else None
        else:
            t = tarfile.open(fileobj=io.BytesIO(data))
            mem = [m for m in t.getmembers() if m.isfile() and m.name.count("/") == 1 and m.name.endswith("/pyproject.toml")]
            raw = t.extractfile(mem[0]).read() if mem else None
        if raw is None:
            return ["setuptools (no pyproject.toml)"]
        return tomllib.loads(raw.decode()).get("build-system", {}).get("requires", ["setuptools"])
    except Exception as e:  # a damaged or odd archive: say so, don't fail the lock
        return [f"? ({type(e).__name__})"]


def main():
    args = sys.argv[1:]
    cache = args.pop(0)
    out_path = None
    if "-o" in args:
        i = args.index("-o")
        out_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit("usage: dkbuild python-lock <uv.lock | pylock.toml | requirements.txt> [-o files/python.lock]")
    src = args[0]
    with open(src) as f:
        text = f.read()
    base = os.path.basename(src)
    if base == "uv.lock":
        pkgs = from_uv(text)
    elif base.startswith("pylock.") and base.endswith(".toml"):
        pkgs = from_pylock(text)
    else:
        pkgs = from_requirements(text)

    store = os.path.join(cache, "python")
    os.makedirs(store, exist_ok=True)
    lines = ["# made by dkbuild python-lock from " + base,
             "# <name> <version> <sha256> <url>"]
    seen = set()
    for name, ver, sdist, wheels in sorted(pkgs, key=lambda p: norm(p[0])):
        key = (norm(name), ver)
        if key in seen:
            continue
        seen.add(key)
        pick = choose(name, ver, sdist, wheels)
        if pick is None:
            print(f"python-lock: {name} {ver}: no source distribution or pure-Python wheel; left out", file=sys.stderr)
            continue
        url, sha = pick
        fname = url.rsplit("/", 1)[-1].split("#", 1)[0]
        if "/" in fname or "'" in fname or not url.startswith("https://"):
            sys.exit(f"python-lock: {name}: unusable URL {url}")
        path = os.path.join(store, fname)
        if os.path.exists(path):
            with open(path, "rb") as f:
                data = f.read()
        else:
            data = get(url)
        got = hashlib.sha256(data).hexdigest()
        if got != sha:
            sys.exit(f"python-lock: {fname}: sha256 {got} does not match the lockfile's {sha}")
        if not os.path.exists(path):
            with open(path + ".part", "wb") as f:
                f.write(data)
            os.replace(path + ".part", path)
        lines.append(f"{norm(name)} {ver} {sha} {url}")
        if not fname.endswith(".whl"):
            lines.append("#   sdist; build-system: " + ", ".join(build_requires(data, fname)))
        print(f"{name} {ver}: {fname}", file=sys.stderr)
    text = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
