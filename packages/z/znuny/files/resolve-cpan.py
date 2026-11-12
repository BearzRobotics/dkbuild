#!/usr/bin/env python3
# Resolves CPAN modules to distributions (runtime/configure/build requires,
# not tests), skipping core modules of Perl 5.40.1 and dists the tree has.
import json, subprocess, sys, urllib.request, urllib.parse, collections

TREE_DISTS = {"Moo","JSON","IO-Socket-SSL","Net-SSLeay","URI","Template-Toolkit","XML-Parser","Role-Tiny",
              "Sub-Quote","Class-Method-Modifiers","Path-Tiny","Parse-Yapp","gettext"}
API = "https://fastapi.metacpan.org/v1"

def get(path):
    with urllib.request.urlopen(API + path) as r:
        return json.load(r)

def core(mods):
    if not mods: return set()
    code = 'use Module::CoreList; for (@ARGV) { my ($m,$v)=split /\\|/; print "$m\\n" if Module::CoreList::is_core($m, ($v||undef), 5.040001) }'
    out = subprocess.run(["perl","-e",code]+[f"{m}|{v}" for m,v in mods], capture_output=True, text=True).stdout
    return set(out.split())

want = sys.argv[1:]
queue = collections.deque((m, "0") for m in want)
seen_mod, dists, deps = set(), {}, collections.defaultdict(set)
while queue:
    batch = []
    while queue:
        m, v = queue.popleft()
        if m in seen_mod or m == "perl": continue
        seen_mod.add(m); batch.append((m, v))
    cores = core(batch)
    for m, v in batch:
        if m in cores: continue
        try:
            mod = get("/module/" + urllib.parse.quote(m))
        except Exception as e:
            print(f"# unresolved {m}: {e}", file=sys.stderr); continue
        dist = mod["distribution"]
        if dist in TREE_DISTS or dist == "perl": continue
        if dist not in dists:
            rel = get(f"/release/{mod['author']}/{mod['release']}"); rel = rel.get("release", rel)
            dists[dist] = {"release": mod["release"], "version": rel.get("version"), "url": rel["download_url"],
                           "checksum": rel.get("checksum_sha256")}
            for d in rel.get("dependency", []):
                if d["relationship"] == "requires" and d["phase"] in ("runtime","configure","build"):
                    queue.append((d["module"], d.get("version") or "0"))
                    deps[dist].add(d["module"])
        dists[dist].setdefault("modules", set()).add(m)
json.dump({k: dict(v, modules=sorted(v["modules"]), deps=sorted(deps[k])) for k, v in dists.items()},
          sys.stdout, indent=1)
