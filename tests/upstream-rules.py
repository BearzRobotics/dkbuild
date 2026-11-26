#!/usr/bin/env python3
# The version rules of `dkbuild upstream` (src/scripts/upstream.py): pre-releases are never reported unless a package is
# opted in, and real releases with high numbers are not mistaken for them. No network. Run: python3 -B tests/upstream-rules.py
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("u", os.path.join(os.path.dirname(__file__), "..", "src", "scripts", "upstream.py"))
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)
bad=0
def eq(what,got,want):
    global bad
    ok=got==want; bad+= not ok
    print(('ok  ' if ok else 'FAIL'),what,'->',got,'' if ok else f'(wanted {want})')
eq('zfs 2.4.99 skipped',u.best(['2.4.4','2.4.99','2.4.3'],'2.4.4',{}),'2.4.4')
eq('xserver .99.904 skipped',u.best(['21.1.24','21.1.23','26.0.99.904'],'21.1.24',{}),'21.1.24')
eq('pango 1.90 skipped',u.best(['1.58.2','1.59.0','1.90.0'],'1.58.2',{}),'1.59.0')
eq('KDE 26.11.90 skipped',u.best(['26.08.3','26.08.2','26.11.90'],'26.08.2',{}),'26.08.3')
eq('kernel 5.10.99 kept',u.best(['5.10.%d'%i for i in range(90,100)],'5.10.95',{}),'5.10.99')
eq('2.1.90 after 2.1.89 kept',u.best(['2.1.88','2.1.89','2.1.90'],'2.1.88',{}),'2.1.90')
eq('2.1.101 kept',u.best(['2.1.98','2.1.99','2.1.101'],'2.1.98',{}),'2.1.101')
eq('registry high patch kept',u.best(['1.0.0','1.0.95'],'1.0.0',{},numbered=False),'1.0.95')
eq('rc words skipped',u.best(['1.2.0','1.3.0rc1','1.3.0-beta.2'],'1.2.0',{}),'1.2.0')
eq('opt-in gets rc',u.best(['1.2.0','1.3.0rc1','1.3.0-beta.2'],'1.2.0',{'prerelease':True}),'1.3.0rc1')
eq('opt-in gets .99',u.best(['2.4.4','2.4.99'],'2.4.4',{'prerelease':True}),'2.4.99')
eq('release beats its rc',u.best(['1.3.0rc2','1.3.0'],'1.2.0',{'prerelease':True}),'1.3.0')
eq('order dev<alpha<beta<rc<final',sorted(['1.0','1.0rc1','1.0beta1','1.0alpha1','1.0dev','1.0.1'],key=u.vkey),['1.0dev','1.0alpha1','1.0beta1','1.0rc1','1.0','1.0.1'])
eq('openssl letters still order',sorted(['1.1.1w','1.1.1','1.1.2'],key=u.vkey),['1.1.1','1.1.1w','1.1.2'])
vs,_=u.learn(['release.1.2.0-rc1','release.1.1.0','weird 1.3.0-beta'],'9.9.9')
eq('fallback does not turn rc into release',sorted(vs),['1.1.0'])
eq('tcpdump: a series already in use',u.best(['4.99.5','4.99.6','4.99.7'],'4.99.6',{}),'4.99.7')
eq('first .99 of that series kept too',u.best(['4.99.0','4.99.1'],'4.99.0',{}),'4.99.1')
eq('another series still marked',u.best(['4.99.6','4.99.7','4.100.0','5.99.1'],'4.99.6',{}),'4.100.0')
print('failures:',bad); sys.exit(bad>0)
