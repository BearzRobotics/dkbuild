#!/usr/bin/env python3
# dkbuild upstream (SPEC.md 10): which recipes have a newer upstream release.
# Embedded in dkbuild and run by `dkbuild upstream` with the host's python3.
# Reads the recipes itself (tomllib); checks only, changes nothing.
#
# Where a recipe's first source comes from decides how its releases are found:
#   git hosts (GitHub, GitLab, Codeberg, git.kernel.org, sourceware, ...)
#                      `git ls-remote --tags` of the repository (no API, no limits)
#   download.gnome.org the module's cache.json
#   PyPI, crates.io, npm, MetaCPAN, Hex-free JSON APIs
#   SourceForge        the project's file RSS
#   anything else      the HTTP directory listing the file is in (and the
#                      versioned directories above it: KDE, X.org, Xfce, GNU, ...)
# A tag or file name matches when it contains a version the way the recipe's
# own source names its version (prefix/suffix learned from that), pre-releases
# (alpha, beta, rc, dev, pre, preview, snapshot) skipped.
#
# upstream.toml at the tree root overrides that per package:
#   [gcc]                        # stay on the 15 series
#   series = "15."
#   [foo]
#   url = "https://github.com/x/foo"     # check this instead of the source
#   regex = "foo-([0-9.]+)\\.tar"        # tags/page text; group 1 = version
#   ignore = "^2\\.99"                   # versions never to report
#   skip = "reason"                      # don't check (vendored, pinned, ...)
#
# Results are cached in work/upstream/cache.json for 12 hours (--refresh
# ignores the cache); the last report is work/upstream/report.txt.
import concurrent.futures as cf
import html
import json
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

UA = "dkbuild-upstream-check/1 (+https://github.com/BearzRobotics/dkbuild)"
TTL = 12 * 3600
PRE = re.compile(r"(alpha|beta|rc|dev|pre|preview|snapshot|nightly|test|canary)", re.I)
ARCH_EXT = r"(?:\.tar\.(?:gz|xz|bz2|zst|lz|lzma)|\.tgz|\.tbz2?|\.txz|\.zip|\.tar)"


# ---------------------------------------------------------------- versions
def vkey(v):
    """Sort key: numeric components compare as numbers, letters after."""
    parts = re.findall(r"\d+|[a-zA-Z]+", v)
    return [(0, int(p), "") if p.isdigit() else (1, 0, p.lower()) for p in parts]


def newer(a, b):
    return vkey(a) > vkey(b)


def norm(v):
    """'V3-6-2' -> '3.6.2', 'v1.2.3' -> '1.2.3', '2_4' -> '2.4'."""
    v = re.sub(r"^[^0-9]*", "", v)
    return re.sub(r"(?<=\d)[-_](?=\d)", ".", v)


def plausible(v):
    return bool(re.fullmatch(r"\d+(\.\d+)*[a-z]?(\.\d+)*", v)) and not PRE.search(v)


# ------------------------------------------------------------------- http
import threading
HOST_SLOTS = {}
HOST_LOCK = threading.Lock()


def get(url, accept=None, timeout=30):
    """At most 3 requests at a time per host; 429/503 are retried after a pause."""
    host = urllib.parse.urlparse(url).netloc
    with HOST_LOCK:
        slot = HOST_SLOTS.setdefault(host, threading.Semaphore(3))
    req = urllib.request.Request(url, headers={"User-Agent": UA, **({"Accept": accept} if accept else {})})
    for attempt in range(4):
        with slot:
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return r.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                if e.code not in (429, 503) or attempt == 3:
                    raise
                wait = int(e.headers.get("Retry-After", "0") or 0) or 5 * (attempt + 1)
        time.sleep(min(wait, 60))


def git_tags(repo):
    out = subprocess.run(["git", "ls-remote", "--tags", "--refs", repo], capture_output=True, text=True,
                         timeout=90, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "git ls-remote failed")
    return [l.split("refs/tags/", 1)[1] for l in out.stdout.splitlines() if "refs/tags/" in l]


# ------------------------------------------------- matching names to versions
def learn(names, current):
    """From names (tags, files), the versions in them, shaped like the one
    that carries `current`: same prefix and suffix around the version."""
    cur_n = norm(current)
    shape = None
    for n in names:
        i = n.find(current)
        if i < 0:
            # The recipe's version may be spelled differently in tags (3-6-2).
            alt = current.replace(".", "-"), current.replace(".", "_")
            for a in alt:
                i = n.find(a)
                if i >= 0:
                    current_sp = a
                    break
            else:
                continue
        else:
            current_sp = current
        pre, suf = n[:i], n[i + len(current_sp):]
        # The version must be whole: not the start of 1.10.11 or the end of 21.10.
        if not re.search(r"[0-9.]$", pre) and not re.match(r"^(?:[0-9]|[._-][0-9])", suf):
            shape = (pre, suf)
            break
    out = []
    for n in names:
        if shape:
            pre, suf = shape
            if not (n.startswith(pre) and n.endswith(suf)) or len(n) <= len(pre) + len(suf):
                continue
            raw = n[len(pre):len(n) - len(suf)] if suf else n[len(pre):]
        else:
            m = re.search(r"\d+(?:[._-]\d+)+[a-z]?", n)
            if not m:
                continue
            raw = m.group(0)
        v = norm(raw)
        if plausible(v):
            out.append(v)
    return out, shape is not None or cur_n in out


def best(versions, current, ov):
    cand = [v for v in set(versions) if plausible(v)]
    if ov.get("series"):
        cand = [v for v in cand if v.startswith(ov["series"])]
    if ov.get("ignore"):
        cand = [v for v in cand if not re.search(ov["ignore"], v)]
    # A different scheme (dates as versions next to 1.x) is not comparable.
    cur = norm(current)
    if cur and cur[0].isdigit():
        width = len(cur.split(".")[0])
        cand = [v for v in cand if abs(len(v.split(".")[0]) - width) <= 1]
    if not cand:
        return None
    return max(cand, key=vkey)


# ----------------------------------------------------------------- sources
GIT_HOSTS = ("github.com", "codeload.github.com", "gitlab.com", "codeberg.org", "git.kernel.org",
             "sourceware.org", "gitlab.freedesktop.org", "gitlab.gnome.org", "invent.kde.org",
             "git.sr.ht", "bitbucket.org", "salsa.debian.org", "git.savannah.gnu.org", "gitea.com")


def git_repo(url):
    u = urllib.parse.urlparse(url)
    p = [x for x in u.path.split("/") if x]
    h = u.netloc
    if h in ("github.com", "codeload.github.com") and len(p) >= 2:
        return f"https://github.com/{p[0]}/{p[1].removesuffix('.git')}"
    if "/-/" in u.path:  # GitLab: /group/sub/repo/-/archive/...
        return f"https://{h}{u.path.split('/-/')[0]}.git"
    if h == "codeberg.org" and len(p) >= 2:
        return f"https://codeberg.org/{p[0]}/{p[1]}.git"
    if h == "git.kernel.org" and ".git" in u.path:
        return "https://git.kernel.org" + u.path[:u.path.index(".git") + 4]
    if h == "git.sr.ht" and len(p) >= 2:
        return f"https://git.sr.ht/{p[0]}/{p[1]}"
    if h == "bitbucket.org" and len(p) >= 2:
        return f"https://bitbucket.org/{p[0]}/{p[1]}.git"
    if len(p) >= 2 and h in GIT_HOSTS:
        return f"https://{h}/{p[0]}/{p[1]}.git"
    return None


def from_git(repo, current, ov):
    tags = git_tags(repo)
    if ov.get("regex"):
        vs = [m.group(1) for t in tags for m in [re.search(ov["regex"], t)] if m]
        vs = [norm(v) for v in vs]
    else:
        vs, _ = learn(tags, current)
    return best(vs, current, ov)


def from_gnome(url, current, ov):
    mod = urllib.parse.urlparse(url).path.split("/")[2]
    data = json.loads(get(f"https://download.gnome.org/sources/{mod}/cache.json"))
    vers = data[2].get(mod, [])
    vers = list(vers.keys()) if isinstance(vers, dict) else list(vers)
    # The older GNOME scheme (GTK, GLib, Pango: X.Y.Z with X < 40): an odd
    # minor is a development series. Kept only when the recipe follows one.
    c = current.split(".")
    if len(c) >= 2 and c[0].isdigit() and int(c[0]) < 40 and c[1].isdigit() and int(c[1]) % 2 == 0:
        vers = [v for v in vers if not (len(v.split(".")) >= 2 and v.split(".")[1].isdigit() and int(v.split(".")[1]) % 2 == 1)]
    return best(vers, current, ov)


def from_pypi(url, current, ov):
    fn = os.path.basename(urllib.parse.urlparse(url).path)
    m = re.match(r"(.+?)-" + re.escape(current) + ARCH_EXT + "$", fn) or re.match(r"(.+?)-\d", fn)
    name = m.group(1)
    data = json.loads(get(f"https://pypi.org/pypi/{name}/json"))
    return best(list(data["releases"].keys()), current, ov)


def from_crates(url, current, ov):
    name = urllib.parse.urlparse(url).path.split("/")[2]
    data = json.loads(get(f"https://crates.io/api/v1/crates/{name}"))
    return best([v["num"] for v in data["versions"] if not v.get("yanked")], current, ov)


def from_npm(url, current, ov):
    p = urllib.parse.urlparse(url).path.split("/-/")[0].strip("/")
    data = json.loads(get(f"https://registry.npmjs.org/{p}"))
    return best(list(data.get("versions", {}).keys()), current, ov)


def from_cpan(url, current, ov):
    fn = os.path.basename(urllib.parse.urlparse(url).path)
    m = re.match(r"(.+?)-v?" + re.escape(current) + ARCH_EXT + "$", fn) or re.match(r"(.+?)-v?\d", fn)
    dist = m.group(1)
    data = json.loads(get(f"https://fastapi.metacpan.org/v1/release/{dist}"))
    v = str(data["version"]).lstrip("v")
    # Decimal versions (perl's 5.044000) when the recipe uses dotted ones.
    m = re.fullmatch(r"(\d+)\.(\d{3})(\d{3})", v)
    if m and current.count(".") == 2:
        v = f"{int(m.group(1))}.{int(m.group(2))}.{int(m.group(3))}"
    return best([v], current, ov)


def from_sourceforge(url, current, ov):
    u = urllib.parse.urlparse(url)
    p = [x for x in u.path.split("/") if x]
    proj = p[1] if p[0] in ("project", "projects", "sourceforge") else p[0]
    rss = get(f"https://sourceforge.net/projects/{proj}/rss?path=/&limit=100")
    names = [os.path.basename(html.unescape(x).rstrip("/").removesuffix("/download"))
             for x in re.findall(r"<link>([^<]+)</link>", rss)]
    return from_names(names, os.path.basename(u.path), current, ov)


def from_names(names, current_file, current, ov):
    if ov.get("regex"):
        vs = [norm(m.group(1)) for n in names for m in [re.search(ov["regex"], n)] if m]
        return best(vs, current, ov)
    i = current_file.find(current)
    if i < 0:
        vs, _ = learn(names, current)
        return best(vs, current, ov)
    pre = current_file[:i]
    # What follows the version, without the archive extension (tcl's "-src").
    suf = re.sub(ARCH_EXT + "$", "", current_file[i + len(current):])
    pat = re.compile(re.escape(pre) + r"v?([0-9][0-9A-Za-z._-]*?)" + re.escape(suf) + ARCH_EXT + "$")
    vs = [norm(m.group(1)) for n in names for m in [pat.match(n)] if m]
    return best(vs, current, ov)


def listing(url):
    text = get(url)
    return [html.unescape(urllib.parse.unquote(h)).rstrip("/").split("/")[-1]
            for h in re.findall(r'href="([^"?#]+)"', text)]


def from_directory(url, current, ov):
    """The directory the file is in, and versioned directories above it:
    .../stable/frameworks/6.31/kcoreaddons-6.31.0.tar.xz lists frameworks/,
    picks the newest 6.x directory, then lists that for the file."""
    u = urllib.parse.urlparse(url)
    parts = u.path.split("/")
    fname = parts[-1]
    dirs = parts[:-1]
    # Versioned directory components (they contain a prefix of the version).
    vidx = [i for i, d in enumerate(dirs) if d and re.fullmatch(r"v?\d+(\.\d+)*[a-z]?", d)
            and norm(current).startswith(norm(d).split(".")[0])]
    if ov.get("regex"):
        base = f"{u.scheme}://{u.netloc}{'/'.join(dirs)}/"
        page = get(ov.get("url") or base)
        vs = [norm(m) for m in re.findall(ov["regex"], page)]
        return best(vs, current, ov)
    if not vidx:
        names = listing(f"{u.scheme}://{u.netloc}{'/'.join(dirs)}/")
        return from_names(names, fname, current, ov)
    i = vidx[0]
    parent = f"{u.scheme}://{u.netloc}{'/'.join(dirs[:i])}/"
    sub = [d for d in listing(parent) if re.fullmatch(r"v?\d+(\.\d+)*[a-z]?", d)]
    old = dirs[i]
    same_depth = len(norm(old).split("."))
    sub = [d for d in sub if len(norm(d).split(".")) == same_depth and plausible(norm(d))]
    if ov.get("series"):
        sub = [d for d in sub if norm(d).startswith(ov["series"]) or ov["series"].startswith(norm(d) + ".")]
    if not sub:
        return None
    newest = max(sub, key=lambda d: vkey(norm(d)))
    rest = "/".join(dirs[i + 1:])
    found = []
    # The newest directory may hold only pre-releases: try the last three.
    for d in sorted(sub, key=lambda d: vkey(norm(d)), reverse=True)[:3]:
        path = f"{u.scheme}://{u.netloc}{'/'.join(dirs[:i] + [d])}/{rest + '/' if rest else ''}"
        try:
            names = listing(path)
        except Exception:
            continue
        v = from_names(names, fname, current, ov)
        if v:
            found.append(v)
        if d == newest and v:
            break
    return best(found, current, ov) if found else None


def check(pkg):
    name, current, url, ov = pkg["name"], pkg["version"], pkg["url"], pkg["ov"]
    if ov.get("url"):
        url = ov["url"]
    if url.startswith("snapshot:"):
        w = url.split()
        if w[0] == "snapshot:git" and len(w) >= 3:
            return from_git(w[1], current, ov), "git " + w[1]
        raise LookupError("snapshot source: give upstream.toml a url")
    h = urllib.parse.urlparse(url).netloc
    if h == "download.gnome.org":
        return from_gnome(url, current, ov), "gnome"
    if h in ("files.pythonhosted.org", "pypi.org", "pypi.io"):
        return from_pypi(url, current, ov), "pypi"
    if h in ("static.crates.io", "crates.io"):
        return from_crates(url, current, ov), "crates.io"
    if h == "registry.npmjs.org":
        return from_npm(url, current, ov), "npm"
    if h in ("cpan.metacpan.org", "www.cpan.org", "cpan.org"):
        return from_cpan(url, current, ov), "metacpan"
    if "sourceforge" in h:
        return from_sourceforge(url, current, ov), "sourceforge"
    repo = git_repo(url)
    if repo:
        return from_git(repo, current, ov), "git " + repo
    if url.endswith(".git") or ov.get("git"):
        return from_git(url, current, ov), "git " + url
    return from_directory(url, current, ov), "listing"


# --------------------------------------------------------------------- main
def main():
    args = sys.argv[1:]
    tree = args.pop(0)
    refresh = "--refresh" in args
    show_all = "--all" in args
    notify = "--notify" in args
    jobs = 16
    names = [a for a in args if not a.startswith("--")]

    over = {}
    if os.path.exists(os.path.join(tree, "upstream.toml")):
        with open(os.path.join(tree, "upstream.toml"), "rb") as f:
            over = tomllib.load(f)
    pkgs = []
    pdir = os.path.join(tree, "packages")
    for letter in sorted(os.listdir(pdir)):
        for n in sorted(os.listdir(os.path.join(pdir, letter))):
            if names and n not in names:
                continue
            p = os.path.join(pdir, letter, n, "package.toml")
            try:
                with open(p, "rb") as f:
                    r = tomllib.load(f)
            except (OSError, tomllib.TOMLDecodeError):
                continue
            src = r.get("source") or []
            url = src[0].get("url", "") if src and isinstance(src[0], dict) else ""
            pkgs.append({"name": r["name"], "version": r["version"], "url": url, "ov": over.get(r["name"], {})})

    wdir = os.path.join(tree, "work", "upstream")
    os.makedirs(wdir, exist_ok=True)
    cpath = os.path.join(wdir, "cache.json")
    try:
        with open(cpath) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    now = time.time()

    def one(p):
        if p["ov"].get("skip"):
            return p, None, "skipped: " + str(p["ov"]["skip"]), None
        if not p["url"]:
            return p, None, "", "no source url"
        key = json.dumps([p["url"], p["version"], p["ov"]], sort_keys=True)
        c = cache.get(key)
        if c and not refresh and now - c["t"] < TTL:
            return p, c["v"], c["how"], c.get("err")
        try:
            v, how = check(p)
            err = None if v else "no versions found"
        except Exception as e:  # noqa: BLE001 - every failure is reported, none is fatal
            v, how, err = None, "", f"{type(e).__name__}: {e}"[:160]
        cache[key] = {"t": now, "v": v, "how": how, "err": err}
        return p, v, how, err

    results = []
    with cf.ThreadPoolExecutor(jobs) as ex:
        futs = [ex.submit(one, p) for p in pkgs]
        for i, fu in enumerate(cf.as_completed(futs), 1):
            results.append(fu.result())
            if sys.stderr.isatty():
                print(f"\rchecked {i}/{len(pkgs)}", end="", file=sys.stderr, flush=True)
    if sys.stderr.isatty():
        print(file=sys.stderr)
    with open(cpath + ".tmp", "w") as f:
        json.dump(cache, f)
    os.replace(cpath + ".tmp", cpath)

    results.sort(key=lambda r: r[0]["name"])
    upd = [(p, v, how) for p, v, how, err in results if v and newer(v, norm(p["version"]))]
    failed = [(p, err) for p, v, how, err in results if err]
    skipped = [p for p, v, how, err in results if how.startswith("skipped")]
    lines = []
    w = max([len(p["name"]) for p, _, _ in upd] + [8])
    lines.append(f"{len(upd)} update(s) available ({len(pkgs)} recipes checked, "
                 f"{len(failed)} not checkable, {len(skipped)} skipped)\n")
    for p, v, how in upd:
        lines.append(f"  {p['name']:<{w}}  {p['version']:>14} -> {v:<14}  ({how})")
    if show_all and failed:
        lines.append("\nnot checkable (add an entry to upstream.toml):")
        for p, err in failed:
            lines.append(f"  {p['name']:<{w}}  {p['version']:>14}  {err}  [{p['url'][:90]}]")
    report = "\n".join(lines) + "\n"
    with open(os.path.join(wdir, "report.txt"), "w") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M\n") + report)
        if not show_all and failed:
            f.write("\nnot checkable:\n" + "\n".join(f"  {p['name']}: {err}" for p, err in failed) + "\n")
    sys.stdout.write(report)
    if not show_all and failed:
        print(f"(`dkbuild upstream --all` lists the {len(failed)} not checkable; report: work/upstream/report.txt)")
    if notify and upd:
        body = ", ".join(f"{p['name']} {v}" for p, v, _ in upd[:30]) + (" ..." if len(upd) > 30 else "")
        subprocess.run(["notify-send", "-a", "dkbuild", f"{len(upd)} package update(s) upstream", body],
                       check=False)


if __name__ == "__main__":
    main()
