# BlackArch tools (requested 2026-11-16)

"Pen testing is something I've always wanted to learn. https://blackarch.org/tools.html As many of these tools as we can
package we should, but we shouldn't kill ourselves to do so."

The list has 2,869 tools (2026-11-16). Method: the page is parsed; GitHub metadata (language, licence, last push,
latest release, stars) fetched with `gh api graphql`; candidates = active since 2025, 100+ stars, a tagged release,
not already in the tree, a licence that allows redistribution. Recipes are generated from the source tree's own
build files by small scripts (a template per language), then `dkbuild --tree wip/queue check`. NOTHING here is
built or fetched yet: they sit in wip/queue/packages until the main tree is stable; expect first-build fixes.
Generated recipes say so in their first comment line.

Already in the tree (so not redone): nmap, john, hydra, sqlmap, nikto, aircrack-ng, wireshark, metasploit, masscan,
bettercap, radare2, rizin, cutter, gdb, pwndbg, ghidra, gobuster, ffuf, hashcat, zaproxy, socat, tcpdump, netexec,
binwalk, yara, kismet, amass, nuclei, tor, fping, sslscan, clamav, testdisk, ddrescue, chntpw, z3, imhex, ...

## Written (wip/queue/packages)

- 59 Go tools (godeps, template of ffuf): the ProjectDiscovery set (subfinder, httpx, naabu, katana, dnsx, tlsx, asnmap,
  mapcidr, uncover, proxify, cloudlist, interactsh, alterx, chaos-client, cvemap), trufflehog, grype, chisel, gowitness,
  gau, hakrawler, cariddi, kiterunner, brutespray, puredns, shuffledns, zgrab2, hetty, goshs, pspy, fscan, ...
- 12 Rust tools (cargodeps): feroxbuster, dalfox, chainsaw, x8, rusthound(+ce), avml, jwt-hack, ares, rustcat, dirble, urx.
- 15 C/C++ tools (generated from cmake/autotools/make; build dependencies guessed from the #includes): massdns,
  3proxy, can-utils, osslsigncode, passivedns, duplicut, bkcrack, libtins, pkt2flow, tcpcopy, nfdump, hashdeep, dcfldd,
  shellinabox, sha1collisiondetection.
- 21 Python tools (pip install of the source tarball, dependencies from the tree's python-* packages) and the pure-Python
  libraries they needed that the tree lacked (python-colorama, -tldextract, -requests-ntlm, -stem, ...): sherlock,
  impacket (impacket-ba), dirsearch, wafw00f, arjun, commix, certipy, detect-secrets, websockify, knock, ghauri,
  waymore, waybackpack, bloodyad, coercer, exabgp, cloud-enum, snallygaster, socialscan, apkleaks, enum4linux-ng.

## Left out on purpose (not killing ourselves)

- Licence forbids redistribution (non-commercial or none): stunner (CC BY-NC-SA), shosubgo (no licence).
- Command-and-control and implant frameworks (sliver, merlin, emp3r0r, havoc, adaptix, empire, ...) and malware
  collections (thezoo): large, and not what a first pen-testing toolbox needs; ask if you want them.
- Windows-only tools (mimikatz, PowerShell frameworks, .NET tools): nothing to run them on.
- Needs a network of services or a GPU/ML stack (bbot, garak, giskard, pentestgpt, prowler, scoutsuite, pacu, checkov,
  mobsf, archivebox): their dependency trees are large; each is its own piece of work.
- Python tools whose dependencies are compiled libraries not in the tree (pycares/aiodns for maigret and theharvester,
  pycurl for wfuzz, mutf8 and cryptography-heavy sets for androguard, nassl for sslyze, dulwich for git-dumper, selenium,
  uv-build for geoip2/dnstwist): each needs its library first (a library recipe is small; the compiled ones are the cost).
- No release tag (only branches) or no build file: xsstrike, lazagne, photon, spiderfoot, jwt-tool, responder, ...
  (a pinned commit can be used instead; ask).
- Large C/C++ projects: zeek, rr, klee, triton, lief, pmacct, sdrangel, edb, dynamorio.
- cook (go.mod in a subdirectory: godeps only looks at the top), nextnet (no go.mod).

## Next, if you want more

1. Move what is here to packages/ once the world run is stable, fetch, build, fix.
2. The aiodns/pycares and pycurl libraries unlock maigret, theharvester, wfuzz (and the OSINT group).
3. A wordlists package: seclists (74k stars, MIT), payloadsallthethings, rockyou-style lists: no build, just data.
4. Wireless: hcxtools/hcxdumptool, reaver, pixiewps, bully, mdk4, wifite are not in the BlackArch list (Arch main
   repos have them) but belong in the same toolbox; also ettercap, medusa, ncrack, hping3, arp-scan, dsniff, foremost,
   volatility3, sleuthkit, autopsy: check which are in the tree first.
