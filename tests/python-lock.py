#!/usr/bin/env python3
# src/scripts/python-lock.py (`dkbuild python-lock`): what an upstream package or requirements file says cannot add
# lock lines, Linux requirements are not dropped, and a requirement's own hashes are held to. No network.
# Run: python3 -B tests/python-lock.py
import importlib.util, io, json, os, sys, tarfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("pl", os.path.join(os.path.dirname(__file__), "..", "src", "scripts", "python-lock.py"))
pl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pl)
bad = 0


def check(what, ok):
    global bad
    bad += not ok
    print("ok  " if ok else "FAIL", what)


def sdist(pyproject):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        d = pyproject.encode()
        ti = tarfile.TarInfo("x-1.0/pyproject.toml")
        ti.size = len(d)
        t.addfile(ti, io.BytesIO(d))
    return buf.getvalue()


def comment(data):
    return pl.build_comment(data, "x-1.0.tar.gz")


evil = '[build-system]\nrequires = ["setuptools\\nevil 1.0 %s https://attacker.invalid/evil-1.0-py3-none-any.whl\\r\\u2028x"]\n' % ("0" * 64)
c = comment(sdist(evil))
check("an sdist's build requirements stay one comment line", c.startswith("#") and len(c.splitlines()) == 1)
check("odd build requirements do not break the lock", comment(sdist('[build-system]\nrequires = [1, 2]\n')).startswith("#"))
check("honest ones are listed", "setuptools>=61" in comment(sdist('[build-system]\nrequires = ["setuptools>=61"]\n')))

try:
    pl.field("url", "https://e.org/a\nevil")
    check("a field with white space is refused", False)
except SystemExit:
    check("a field with white space is refused", True)

# requirements: markers and hashes
asked = []


def fake_get(url):
    asked.append(url)
    return json.dumps({"urls": [{"packagetype": "sdist", "url": "https://f.invalid/p-1.tar.gz", "digests": {"sha256": "a" * 64}},
                                {"packagetype": "bdist_wheel", "url": "https://f.invalid/p-1-py3-none-any.whl", "digests": {"sha256": "b" * 64}}]}).encode()


pl.get = fake_get
r = pl.from_requirements('p==1 ; sys_platform == "win32" or sys_platform == "linux"\nw==1 ; sys_platform == "win32"\n')
check("a requirement for Linux or Windows is kept, one for Windows only is left out", [x[0] for x in r] == ["p"])
r = pl.from_requirements("p==1 \\\n    --hash=sha256:%s\n" % ("a" * 64))
check("only files with a hash the requirement pins are taken", r[0][2] is not None and r[0][3] == [])
try:
    pl.from_requirements("p==1 --hash=sha256:%s\n" % ("c" * 64))
    check("no file matching the pinned hashes is an error", False)
except SystemExit:
    check("no file matching the pinned hashes is an error", True)
print("failures:", bad)
sys.exit(bad > 0)
