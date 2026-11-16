# generate dk-maven/ (an aggregator POM with one module per ivy.xml) from a source tree's ivy.xml files: python3 ivy2pom.py <srcdir> <outdir> [extra g:a:v ...]
import sys,os,re,glob,xml.etree.ElementTree as ET
src,out=sys.argv[1],sys.argv[2]; extra=sys.argv[3:]
props={}
for f in glob.glob(f'{src}/**/*.properties',recursive=True):
    for l in open(f,errors='replace'):
        m=re.match(r'\s*([A-Za-z0-9_.-]+)\s*=\s*(.*?)\s*$',l)
        if m and not l.lstrip().startswith('#'): props.setdefault(m.group(1),m.group(2))
def sub(s):
    for _ in range(5): s=re.sub(r'\$\{([^}]+)\}',lambda m:props.get(m.group(1),m.group(0)),s)
    return s
ivys=sorted(glob.glob(f'{src}/**/ivy.xml',recursive=True))
os.makedirs(out,exist_ok=True)
mods=[];unres=set()
esc=lambda s:s.replace('&','&amp;').replace('<','&lt;')
for i,f in enumerate(ivys):
    t=ET.parse(f).getroot(); deps=[]
    for d in t.iter('dependency'):
        org,name,rev=d.get('org'),d.get('name'),sub(d.get('rev') or '')
        if not (org and name and rev) or '${' in rev or rev.startswith('latest') or rev.startswith('['): unres.add((f,org,name,rev)); continue
        conf=d.get('conf') or ''
        scope='test' if conf.startswith('test') else 'compile'
        ex=[(e.get('org') or '*',e.get('name') or e.get('module') or '*') for e in d.findall('exclude')]
        if '->master' in conf: ex.append(('*','*'))
        deps.append((org,name,rev,scope,ex))
    if i==0 and extra:
        for e in extra:
            g,a,v=e.split(':'); deps.append((g,a,v,'compile',[]))
    mid=f'm{i:03d}'; mods.append(mid); os.makedirs(f'{out}/{mid}',exist_ok=True)
    rel=os.path.relpath(f,src)
    x=f'<?xml version="1.0"?>\n<!-- generated from {rel} by ivy2pom.py (FenrirOS): Maven resolves the same coordinates for the offline store -->\n<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>\n<groupId>dk.ivy</groupId><artifactId>{mid}</artifactId><version>1</version><packaging>pom</packaging>\n<dependencies>\n'
    for org,name,rev,scope,ex in deps:
        x+=f'<dependency><groupId>{esc(org)}</groupId><artifactId>{esc(name)}</artifactId><version>{esc(rev)}</version><scope>{scope}</scope>'
        if ex: x+='<exclusions>'+''.join(f'<exclusion><groupId>{esc(g)}</groupId><artifactId>{esc(a)}</artifactId></exclusion>' for g,a in ex)+'</exclusions>'
        x+='</dependency>\n'
    x+='</dependencies></project>\n'
    open(f'{out}/{mid}/pom.xml','w').write(x)
agg='<?xml version="1.0"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>\n<groupId>dk.ivy</groupId><artifactId>all</artifactId><version>1</version><packaging>pom</packaging>\n<modules>\n'+''.join(f'<module>{m}</module>\n' for m in mods)+'</modules></project>\n'
open(f'{out}/pom.xml','w').write(agg)
print(len(ivys),'ivy files;',len(unres),'unresolved:',sorted(unres)[:8])
