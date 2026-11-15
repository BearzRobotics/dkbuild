# Package requests

Every request as the user made it, with its status, so nothing is lost
between sessions. The older lists are in roadmap.md ("Requested
applications") and wip/README.md; this file collects the requests from
2026-11-11 on. Status words: **written** (recipe exists, passes `dkbuild
check`, not necessarily built), **built**, **planned** (in the work order),
**blocked** (with the reason), **later** (not started).

## Rule for server packages (2026-11-11)

Server software is installed inert; setting it up is left explicitly to the
user:

- no service enabled or started by installing (dinit services are shipped,
  never enabled; nothing in /etc/dinit.d/boot.d);
- no default credentials, accounts, passwords or keys created by the package;
- no web server site, virtual host or listening port configured by the
  package: nginx/httpd configurations are examples in /usr/share/doc/<pkg>;
- no scheduled jobs active by default: cron entries are examples in
  /usr/share/doc/<pkg>, installed into /etc/cron.d by the user;
- configuration files ship as samples (or not at all); the README in
  /usr/share/doc/<pkg>/README.FenrirOS says what to do.

(A package may create its system user and empty state directories through
sysusers.d/tmpfiles.d: those open nothing.)

## Help desks (2026-11-11) — before Chromium

| Package | Status |
|---|---|
| osTicket | written (1.18.4) |
| GLPI | written (12.0.1) |
| FreeScout | written (1.8.250) |
| Znuny | written (7.3.8; 133 CPAN dists vendored) |
| Zammad | written (7.2.3), with what it needed: pnpm support (dkbuild), Ruby 3.4.12, a pub store (dkbuild), dart (3.10.3, stage 0 on Alpine's SDK), buf, dart-sass; its sass gem uses the system dart-sass |

## Electronics (2026-11-11)

| Package | Status |
|---|---|
| KiCad (+ libraries, 3D models), Qucs-S, Xschem, Logisim-evolution, Digital, KTechLab, Coulomb, Fritzing (older) | written |
| ngspice (older), GHDL, Icarus Verilog, GTKWave, Verilator, PulseView, sigrok (libsigrok, libsigrokdecode, sigrok-cli) | written |
| Issie | blocked: needs Electron 43 and .NET |

## Finance and business (2026-11-11)

Invoicing / ERP / accounting:

| Package | Purpose | License | Status |
|---|---|---|---|
| InvoicePlane | invoices, estimates, clients, payments | MIT | written (2026-11-12) |
| InvoiceShelf | invoices, estimates, expenses, payments | AGPL-3.0 | written (2026-11-12); needs PHP >= 8.4.1 |
| SolidInvoice | invoicing and quotes | MIT | written (2026-11-12); needs PHP >= 8.4.27 |
| Dolibarr | invoices, accounting, CRM, inventory | GPL-3.0+ | written (2026-11-12) |
| ERPNext | full ERP, accounting, inventory, HR | GPL-3.0 | blocked: ~100 python-* recipes; wants a Python lockfile store in dkbuild |
| GnuCash | desktop accounting | GPL-2.0+ | written (5.17, with OFX, AqBanking, SQL, Python) |
| Frappe Books | desktop accounting and invoicing | AGPL-3.0 | not planned: archived 2026-10-02 (Electron 22, yarn v1) |
| LedgerSMB | web double-entry accounting | GPL-2.0 | written (2026-11-12) |

Personal finance:

| Package | License | Status |
|---|---|---|
| KMyMoney | GPL-2.0+ | written (2026-11-12) (no KBanking: gwenhywfar has no Qt 6 GUI yet) |
| HomeBank | GPL-2.0+ | written (2026-11-12) |
| Skrooge | GPL-3.0+ | written (2026-11-12) |
| Firefly III | AGPL-3.0 | written (2026-11-12); needs PHP >= 8.5 |
| Beancount + Fava | GPL-2.0+ / MIT | written (2026-11-12) |
| Maybe Finance | check activity and licence first | not planned: archived July 2025 (a fork, Sure, exists) |

CRM:

| Package | License | Status |
|---|---|---|
| Twenty | AGPL-3.0 | blocked: yarn berry monorepo (npmdeps has no yarn) |
| SuiteCRM | AGPL-3.0 | written (2026-11-12) (inbound mail needs php imap) |
| Dolibarr | (above) | written (2026-11-12) |

## Project management and time tracking (2026-11-11)

| Package | License | Status |
|---|---|---|
| OpenProject | GPL-3.0 | written (2026-11-12, 17.9.7 on ruby4.0) |
| Leantime | AGPL-3.0 | written (2026-11-12) |
| Taiga | MPL-2.0 | blocked: many python-* recipes |
| Kimai | AGPL-3.0 | written (2026-11-12) |
| Vikunja | AGPL-3.0 | written (2026-11-12) |

## Documents and office (2026-11-11)

| Package | Status |
|---|---|
| Paperless-ngx | blocked: ~270 Python packages incl. PyTorch |
| Nextcloud (server; the desktop client is written) | written (2026-11-12) (35.0.3) |
| ONLYOFFICE | later (Euro-Office, the fork, is planned) |
| LibreOffice | written |
| Stirling PDF | written (2026-11-12) (MIT core flavour) |
| Joplin | blocked: yarn berry monorepo |
| BookStack | written (2026-11-12) |
| Mayan EDMS | blocked: many python-* recipes |

## Administration and network (2026-11-11)

| Package | Status |
|---|---|
| Zabbix | written (2026-11-12) |
| Netdata | blocked: Go modules in subdirectories (godeps), proprietary dashboard download |
| Uptime Kuma | written (2026-11-12) |
| Cockpit | blocked: needs systemd |
| Webmin | written (2026-11-12) |
| AdGuard Home | written (2026-11-12) |
| Pi-hole | written (2026-11-12) |
| OPNsense | not a package: a FreeBSD-based firewall OS (FenrirOS could have a firewall image/kernel flavour instead) |
| WireGuard | written (wireguard-tools; the module is in the kernel) |
| Syncthing | written (2026-11-12) |

Also asked for: FileZilla (written 2026-11-12: 3.71.1 with libfilezilla and
fzssh, from Arch's mirror of the release tarballs), Blender
(written), Remmina (written), Docker (written 2026-11-12: moby, docker-cli,
containerd, runc, buildx, compose, tini).

## Mail (2026-11-11)

Clients:

| Package | License | Status |
|---|---|---|
| Thunderbird | MPL-2.0 | written |
| Betterbird | MPL-2.0 | written (2026-11-12) |
| Evolution | LGPL-2.1+ | written (2026-11-12) |
| KMail | GPL-2.0+ | written (KDE PIM) |
| Claws Mail | GPL | written (2026-11-12) |
| aerc | MIT | written (2026-11-12) |
| NeoMutt | GPL-2.0 | written (2026-11-12) |

Servers and parts ("everything needed to run a mail server"):

| Package | Purpose | Status |
|---|---|---|
| Stalwart Mail Server | SMTP, IMAP, POP3, JMAP, CalDAV, CardDAV (Rust) — first choice | written (2026-11-12) (AGPL build) |
| Postfix | SMTP | written (2026-11-12) |
| Dovecot | IMAP/POP3 | written (2026-11-12) (+ Pigeonhole) |
| Rspamd | spam filtering | written (2026-11-12) |
| Roundcube, SnappyMail | webmail | written (2026-11-12) |
| SOGo | groupware | written (2026-11-12) (with GNUstep, SOPE) |
| OpenSMTPD, Exim | alternative MTAs | written (2026-11-12) |
| Mox | integrated mail server | written (2026-11-12) |
| listmonk | newsletters and mailing lists | written (2026-11-12) |

## Also 2026-11-11

| Package | Status |
|---|---|
| Passbolt (server) | written |
| fastfetch | written |
| GCC (all languages that do not shadow LLVM/Go) | written |
| Chromium (standalone) | written (157.0.8103.38, Chimera's port; with typescript-go, rustc-dev, xdg-utils) |
| Brave, Euro-Office | written (2026-11-13): Brave 1.99.57; Euro-Office Document Server 9.3.7-1; Libera Suite 0.7 as the desktop app |
| Proxmox VE | written (2026-11-13): 9.2, single node + HA + web UI, ~130 recipes; gaps in wip/proxmox/NOTES.md |

## System monitors and GNOME accounts (2026-11-12)

| Package | Status |
|---|---|
| htop | written (3.5.3; capabilities, delay accounting, sensors) |
| btop | written (1.4.8; GPU support, man page via go-md2man) |
| bottom (btm) | written (0.15.0; battery, NVIDIA, ZFS; man page and completions) |
| GNOME Online Accounts (libgoa, goa-daemon) | written (3.58.1, Kerberos via Heimdal), with librest 0.10.2; an optional dependency of dkde (being added there): add it to the dkde recipe with the release that uses it |

## Questions for the user (collected 2026-11-12, overnight)

1. **Kerberos for curl.** curl no longer supports Heimdal (its docs/HISTORY.md:
   "We drop support for krb-ftp, Heimdal, ..."); its GSSAPI (Negotiate/SPNEGO
   authentication, Kerberos FTP/IMAP/SMTP logins) needs MIT Kerberos or GNU
   GSS. FenrirOS's Kerberos is Heimdal (samba, mariadb, curl's old r5...).
   For now curl is built without GSSAPI, as Chimera's. Options: leave it;
   add MIT krb5 (it installs libgssapi_krb5/libkrb5 and krb5-config, which
   collide with Heimdal's: one or the other per system, or MIT in its own
   prefix just for curl); or switch the tree from Heimdal to MIT.
2. **Android NDK**: answered 2026-11-12: build it from source (Google's release is
   assembled from prebuilts, all open source). Plan in wip/android-ndk/NOTES.md.
3. **ast-grep** (written as a general tool while surveying Brave, which turned
   out not to need it at build time): keep it or drop it?

## Questions from the 2026-11-12 recipe batches

4. **FileZilla**: upstream source links expire, and 3.71 needs libfzssh-client
   (AGPL-3.0+ "with attribution"). Accept the licence, and use Debian's orig
   tarballs (one release behind) as the source?
   *Answered 2026-11-12: package it ("an old classic that everyone ships"); written from Arch's mirror, fzssh's attribution terms met.*
5. **PHP 8.4/8.5**: InvoiceShelf (8.4.1), SolidInvoice (8.4.27) and Firefly III
   (8.5) do not run on the tree's php 8.3.36. Upgrade php, or add php8.5 beside it?
   *Answered: upgrade if needed, else version it. php is 8.4.27 (all apps run on it); php8.5 beside it for Firefly III.*
6. **PHP imap** (SuiteCRM inbound mail): write PECL imap + c-client (uw-imap,
   unmaintained)?
7. **Default credentials created by the apps themselves** (not by the
   packages): BookStack's migration creates admin@admin.com/password, Zabbix's
   data.sql creates Admin/zabbix, Stalwart prints a temporary admin password at
   first start. The READMEs say to change them at once. Acceptable?
   *Answered: fine; users read the docs of the software they run. The packages themselves never set credentials.*
8. **Commercial/proprietary parts left out**: Stalwart Enterprise, Stirling PDF's
   proprietary flavour (login/teams), Netdata's NCUL1 dashboard, Zabbix's Java
   gateway (prebuilt jars). SOGo ActiveSync is shipped as a subpackage, but
   upstream says production use needs a Microsoft licence: keep it?
   *Answered: include commercial add-ons unless there is a compelling reason (e.g. the licence forbids redistribution); being reviewed per add-on.*
9. **Prebuilt pieces kept**: Roundcube's "complete" tarball, SnappyMail's
   vendors/, SOGo's committed UI, npm platform binaries (esbuild, rollup, SWC,
   lightningcss) in several web UIs. Webmin's FreeBSD/macOS helper binaries
   are dropped. OK?
   *Answered: yes, prebuilt web UIs may be kept.*
10. **Upstream services contacted by default**: Syncthing's discovery/relay
    servers, EDS's Google/Outlook/Yahoo OAuth ids, Betterbird branding,
    Stalwart's spam-rule/GeoIP downloads, Vikunja's licence check (only with a
    key). OK?
11. **Ruby 4.0** for OpenProject (beside 3.4, which Zammad pins)?
   *Answered: yes, if OpenProject needs it (ruby4.0 beside ruby 3.4, in progress).*
12. **A Python lockfile store** in dkbuild (uv.lock / hashed requirements) for
    Paperless-ngx, Mayan EDMS, Taiga, ERPNext; and **yarn support** in npmdeps
    for Twenty and Joplin. Worth building?
13. **Gwenhywfar Qt 6 / C++ GUIs** so KMyMoney gets KBanking?
14. **Postfix/Dovecot user names**: `_postfix`/`_postdrop`, `_dovecot`/`_dovenull`
    (the tree's convention) instead of upstream's?
15. **InvoicePlane's trademark clause** (no redistribution under the name
    "InvoicePlane" without permission): ship it under that name?
16. **Setuid** ping and fping (file capabilities cannot be shipped): OK?
17. **Syncthing's sysctl file** (raises socket buffer limits system-wide): keep?
18. **Metasploit** ships prebuilt payload binaries for other systems (glibc,
    aarch64), which the dependency scan reads as needs: it cannot be installed
    until dkbuild can exclude them from the scan.
19. **claude-code** and the stage-0 bootstrap packages need
    `so:libc.musl-x86_64.so.1` (Alpine's name for musl). Adding that alias to
    musl rebuilds the whole tree; a small separate package (a symlink) does not.
    Which?

## Questions from the 2026-11-12 follow-ups

20. **Zabbix Java gateway libraries**: logback, slf4j and dnsjava are pinned
    Maven Central jars (as the digital recipe), not built from source. OK?
21. **Stalwart's AGPL build** still compiles one SEL-licensed crate (scim-proto)
    and two one-line SEL snippets, unreachable without the enterprise feature.
    Acceptable, or patch them out?
22. **Zabbix APM collector**: port Chimera's grpc (all its libraries are in the
    tree) and turn it on?
23. **AppSignal agent** (OpenProject's optional monitoring): a closed binary
    from a commercial service; left out. Pin it as a source instead?

## Also 2026-11-12/13

| Package | Status |
|---|---|
| bashrs, brush | written |
| ShellCheck | written, with GHC 9.14.1 (seeded from Alpine) |
| cabal-install, pandoc, xmonad (+contrib), hledger (+ui, web), git-annex | written (hackagedeps store) |
| xmobar | blocked: no release (nor gtk2hs) builds with GHC 9.14 yet |
| xmessage (+ libXaw) | written (xmonad's error display) |

## Questions from the 2026-11-13 batches

Haskell:
24. git-annex's licence line: AGPL-3.0-or-later (as Alpine) or the fuller
    expression from its COPYRIGHT (GPL-3+, BSD-2/3, a GPL-2 file, jQuery, Bootstrap)?
25. pandoc's http feature and xmobar wait for GHC 9.14 releases of
    serialise/cborg and gtk2hs. Wait, or try allow-newer patches?
26. The GHC seed's URL is on Alpine edge and will disappear when Alpine
    rebuilds it (the cached copy stays, like the dart seed). OK?
Proxmox (details: wip/proxmox/NOTES.md):
27. Ship Proxmox's legacy 2 MB OVMF images (prebuilt edk2 2023.02) for VMs
    with old EFI disks?
28. pve-edk2-firmware enrolls Debian's PkKek-1 certificate (as Proxmox):
    keep, or a FenrirOS Secure Boot key?
29. corosync 3.2 drops unencrypted links and udp/udpu: OK?
30. Next parts: Ceph, ifupdown2 + FRR (Network panel, SDN), PBS client,
    vncterm. Which first?
31. extjs is the GPL-3.0 edition with upstream's prebuilt build/; licence
    lines of the 71 generated perl-* recipes need a look.
Brave:
32. Ship as "Brave" (trademark) or rebrand? Leo's licence unchecked.
33. Accept user-supplied Brave service keys (files/), so News, Sync, Leo,
    component updates work?
Euro-Office (details: wip/euro-office/NOTES.md):
34. V8 8.9.45 (2021) may need fixes for LLVM 23; build 9.3.7-1 now, or wait
    for the release on V8 14.6?
35. Document Server needs RabbitMQ: add Erlang, Elixir and rabbitmq-server?
36. Unbundle core's own zlib/freetype/libpng/libjpeg/openjpeg/libxml2/cryptopp?
37. Libera's own theme (ask Abilian for the artwork) or Euro-Office's?
38. core-fonts: ~10 font folders without a licence file; Symbola's licence.

## Answers (2026-11-13)

The user accepted Claude's suggestion for every open question:

1. curl: no GSSAPI for now (as Chimera); revisit only for a tree-wide move to MIT.
3. ast-grep: keep.
6. PHP imap: skip; SuiteCRM works without inbound mail.
10. Upstream services contacted by default: fine (as upstream ships them).
12. Python lockfile store and yarn in npmdeps: build both.
13. Gwenhywfar Qt 6 / KBanking: later.
14. Mail users: the tree's `_postfix`/`_dovecot` convention.
15. InvoicePlane: ship under its name.
16. Setuid ping/fping: OK.
17. Syncthing's sysctl file: an example in /usr/share/doc, not active.
18. Metasploit: a recipe option in dkbuild to leave files out of the dependency scan.
19. musl's Alpine soname: a small separate package (symlink), not musl itself.
20. Zabbix Java gateway's Maven jars: OK.
21. Stalwart: patch the SEL code out.
22. Zabbix APM collector: port grpc and turn it on.
23. AppSignal agent: left out.
24. git-annex: the full licence expression from COPYRIGHT.
25. pandoc http / xmobar: wait for GHC 9.14 releases.
26. GHC seed on Alpine edge: OK (cached).
27. Proxmox legacy 2 MB OVMF images: ship them.
28. Debian's PkKek-1 in pve-edk2-firmware: keep for now.
29. corosync 3.2: OK.
30. Proxmox next: ifupdown2 + FRR, then the PBS client, then Ceph.
31. extjs prebuilt build: OK; Claude checks the perl-* licence lines.
32. Brave: keep the name; Claude checks Leo's licence.
33. Brave service keys supplied by the user: yes.
34. Euro-Office: build 9.3.7-1 on V8 8.9 now.
35. RabbitMQ: add Erlang, Elixir, rabbitmq-server.
36. Euro-Office core: use the system libraries where it builds.
37. Libera Suite: Euro-Office's theme for now.
38. core-fonts: drop the folders without a clear licence.
Lomiri requested 2026-11-15 (https://gitlab.com/ubports/development/core/lomiri): the Ubuntu Touch / UBports desktop shell. QUEUED, nothing written yet. It is a large stack (Qt5/QML shell on Mir/MirAL plus the lomiri-ui-toolkit, content-hub, url-dispatcher, indicators, settings components, on-screen keyboard and many companions); upstream is moving to Qt6, and the tree has no Qt5 recipes. First step when it comes up: survey the ubports core group, list every dependency and what is missing, decide Qt5 vs the Qt6 branch.
Document search and AI stack requested 2026-11-15 (pasted list, in four priorities). QUEUED, nothing written yet. Priority 1, OCR and PDF tools: tesseract-ocr, tessdata-eng, ocrmypdf, mupdf, poppler, qpdf, ghostscript, unpaper, exiftool. Priority 2, search infrastructure: sqlite, sqlite-fts5, sqlite-vec, postgresql, pgvector, tantivy, qdrant. Priority 3, AI infrastructure: llama.cpp, ollama, fastembed, onnxruntime, sentence-transformers, huggingface-hub. Priority 4, document intelligence and RAG: docling, apache-tika, llama-index, haystack, langchain. Already in the tree (recipes; most built or waiting on this world run): tesseract + tesseract-data, ocrmypdf, mupdf, poppler, qpdf, ghostscript, unpaper, perl-image-exiftool, sqlite (built with --enable-fts5), postgresql, llama-cpp, ollama (+ python-ollama). Missing: sqlite-vec, pgvector, tantivy, qdrant, onnxruntime, fastembed, sentence-transformers (needs PyTorch, which is not packaged), huggingface-hub (+ tokenizers, safetensors), docling, apache-tika (Java), llama-index, haystack, langchain. Notes: no NVIDIA/ROCm on musl (see the GPU note), so onnxruntime and PyTorch are CPU or Vulkan builds; the Python AI libraries need the pydeps store.
RAG projects requested 2026-11-15 (links pasted, no instructions; read as "add to the wishlist", like the stack list above). QUEUED, nothing written, repositories not yet inspected. Applications and libraries: docling (github.com/docling-project/docling, already in the stack list), MinerU (opendatalab/mineru, PDF to Markdown), danswer (unoplat/danswer, a fork of the project now called Onyx), Verba (weaviate/Verba), kotaemon (Cinnamon/kotaemon), RAG-Anything (HKUDS/RAG-Anything). Legal RAG projects (probably examples or research code, to be checked for a release, a licence and a way to install): Fan-Luo/Legal-RAG, arulkumarann/legalRAG, defrecord/legal-rag-hy, azterizm/legal-rag-router; isaacus-dev/legal-rag-bench looks like a benchmark, not an application. Expected needs: PyTorch (not packaged), the pydeps store, vector databases (qdrant, pgvector, Weaviate, Vespa), and model downloads at run time, which the offline-build rule keeps out of the packages. First step when they come up: look at each repository (release tags, licence, dependencies) and decide which are packages and which are only worth listing.
snapd requested 2026-11-15 ("add snap to the repo"): Canonical's snap package manager. QUEUED, nothing written. Read as snapd (github.com/canonical/snapd, GPL-3.0; Go with a C part, snap-confine). Notes before writing: snapd is built around systemd units, mount namespaces and AppArmor/seccomp confinement; this system runs dinit and elogind (no systemd), so the service side (snapd.service, snapd.socket activation, mount units for /snap, the auto-refresh timers) needs dinit equivalents, and without AppArmor (not packaged here) snaps run with seccomp and the cgroup/namespace confinement only (devmode-like, or partial strict). Have: squashfs-tools, libseccomp, dinit, elogind. Missing: apparmor (userspace and the kernel LSM option), squashfuse (optional), the Go deps (godeps store handles them). Snaps carry their own base (core22/core24, glibc Ubuntu) so they run on a musl host, but the store is Canonical's proprietary backend. Question for when it comes up: is it for installing snaps from the Snap Store, and should it be inert by default like the server packages (service not enabled)?
snapd, addendum 2026-11-15: the user's boss uses SELinux as the main confinement method. snapd's strict confinement is AppArmor-based (plus seccomp); on an SELinux system snaps run in devmode or classic confinement (Fedora's snapd is the same), so packaging snapd for SELinux means no strict confinement either way and AppArmor would only matter if someone wanted it. Decision for when snapd comes up: package it without AppArmor (devmode/classic only), SELinux-friendly, inert by default.
SELinux requested 2026-11-15 (the user's boss runs Red Hat family systems, Alma and others, with SELinux as the main confinement). QUEUED, nothing written; none of it is in the tree. Pieces: userspace libraries and tools (libsepol, libselinux, libsemanage, checkpolicy, secilc, policycoreutils with setfiles/restorecon/load_policy/semanage, selinux-python, setools, mcstrans), a policy (Fedora/Red Hat's selinux-policy "targeted" and "mls" is the one his systems know; the upstream reference policy is the other choice), kernel options in `linux` and `linux-lts` (SECURITY_SELINUX, AUDIT, xattr labels on the root filesystem types, NETLABEL), SELinux-aware builds of coreutils (ls -Z, cp -a, install), util-linux, tar, shadow, openssh (labels at login), and init integration (dinit: load the policy and relabel early, no systemd). This system has no PAM, so the pam_selinux login hook has no home here yet: login labelling would go through dkconsole or greetd. Questions for when it comes up: Red Hat's policy or the reference policy; targeted only or MLS too; enforcing or permissive by default (permissive is the safe first image); where relabelling happens (installer, first boot). Related: snapd for SELinux systems (above) runs in devmode or classic.
SELinux decisions 2026-11-15: policy = Red Hat's selinux-policy (the user's boss runs AlmaLinux; Fedora's is the upstream of RHEL's), targeted first; permissive by default (enforcing is a setting the user flips once the system's labels are right). Relabelling: the user did not know; Claude's recommendation, to be confirmed when SELinux is written: the installer labels the files as it writes them (setfiles with the installed policy's file contexts, run on the target), and a first boot relabel (`/.autorelabel`, as RHEL does) stays as the fallback and for upgrades. Still open: MLS (targeted only to begin with).
SELinux installer work (2026-11-15): the installer is /stuff/git/dkinstaller (Zig, SPEC.md; steps in src/execute.zig, SPEC 5.6 "Install"). The user said Claude may change it. When SELinux is packaged: a step after the files are written that runs `setfiles` on the target with the installed policy's file contexts, writes /etc/selinux/config with SELINUX=permissive, and touches /.autorelabel as the first-boot fallback; SPEC and tests updated with it. Nothing changed in the installer yet (no SELinux packages exist).
dosemu2 requested 2026-11-15 (https://dosemu2.github.io/dosemu2/): the DOS emulator for Linux. QUEUED, nothing written, page not yet read. From memory, to verify against the project: GPL-2.0-or-later, C; runs DOS programs through KVM or its own CPU emulator; needs fdpp (the FreeDOS kernel clone, written to build with nasm and a C++ compiler; a companion project, packaged first) and a command shell (comcom64 or FreeCOM), plus the dosemu2 project's own support libraries (thunk_gen, ...) and the usual SDL/X11/slang/alsa/fluidsynth and ncurses optional dependencies, which are runtime dependencies here. Questions for when it comes up: whether it builds on musl x86_64 (32-bit code parts, `-m32`-style needs), and whether to ship a FreeDOS system image. dosbox-staging is already on the wishlist for the DOS games case.
PAM adopted system-wide, decided 2026-11-15 (user: SELinux needs it anyway, and the earlier no-PAM rule dated from building every package by hand): linux-pam and linux-pam-base (the system-auth, system-login, system-remote-login and system-services stacks) were already in the tree; now shadow (login, su, passwd, the account tools: files/pam.d), sudo, openssh (UsePAM yes), polkit (authfw=pam), cronie, cups and samba (pam_winbind) are built with PAM, each with its service file in /usr/lib/pam.d. Recipe releases bumped (shadow r6, sudo r4, openssh r5, polkit r5, cronie r2, cups r2, samba r7), NOT built or tested: the first image with these must be booted in QEMU (tests/qemu-iso.sh) and logged into on the console, over ssh, with su and with sudo before anyone relies on it (a mistake in a stack locks users out). Still to do for the PAM policy: dkconsole/greetd/SDDM check (they already use PAM), util-linux (login stays shadow's), the other daemons that can use PAM (dovecot, exim, vsftpd-like servers, forgejo/gitea), pam_selinux in system-login when SELinux lands, and removing "no PAM" wording elsewhere.
dosemu2 survey 2026-11-15 (read, not packaged): the project has no versioned releases (tags stop at dosemu-1.5.0): the packages elsewhere are built from the `devel` branch (a commit, 7e7f3da on 2026-10-25), so the recipe pins a commit. Build needs (debian/control): fdpp (its own project, 1.11, the FreeDOS kernel; also built from source here), djdev64 (stsp's 64-bit DJGPP development libraries), comcom64 (0.5, the command shell), binutils for i686 (this tree's binutils has all targets) and, besides the usual autotools: libslang, libgpm, alsa, SDL (2 or 3) + SDL_ttf, fontconfig, ladspa, fluidsynth, libao, libieee1284, libslirp, readline, json-c, libb64, libseccomp, libsearpc, valgrind. Several are missing here (djdev64, fdpp, comcom64, libb64, libsearpc, libieee1284, ladspa). Queued, not written; it is a chain of five new packages before dosemu2 itself.
Queue progress 2026-11-15 (wip/queue/README.md): Lomiri stack 86 recipes, SELinux userspace 9 (+ wip/queue/selinux/NOTES.md), AI/search 15 (+ wip/queue/ai-stack/NOTES.md): 107 recipes in all, none built.
ufw requested 2026-11-15 (https://code.launchpad.net/ufw): the Uncomplicated Firewall. WRITTEN in wip/queue/packages/u/ufw (0.36.2, Alpine's patches, inert dinit service, ships disabled), not built. iptables and nftables are already in the tree (ufw drives iptables); conntrack-tools too. Question for later: whether FenrirOS should offer an nftables-based firewall front end too (firewalld, which also drives nftables, is not packaged).
firewalld requested 2026-11-15, and a question: which firewall to ship in the DKDE ISO. WRITTEN in wip/queue/packages: firewalld 2.5.2 (+ python-nftables, python-libcap-ng; inert dinit service), not built. Recommendation given: firewalld in the default image (the Red Hat family's firewall, which the user's colleagues run on AlmaLinux; nftables backend; its D-Bus API is what NetworkManager and desktops use; zones fit a laptop moving between networks; policy is in selinux-policy), ufw available as the simple CLI alternative (iptables-based, Debian/Ubuntu's). Decision pending the user's answer; whichever is chosen the image enables the service (packages never do).
Decision 2026-11-15 (the lines are in images/dkde.toml as comments for now; dkde has its own firewalld front end under development, so no firewalld-gui there): the DKDE ISO ships firewalld (nftables backend, default zone `public`), its service enabled by the image (packages never enable services); ufw stays a queue package for those who prefer it. firewalld is split: `firewalld` (daemon, firewall-cmd, firewall-offline-cmd) and `firewalld-gui` (firewall-config, firewall-applet: GTK + NetworkManager typelib), the GUI part of the DKDE desktop and optional elsewhere. To do when the recipes move from wip/queue to packages/: add firewalld and firewalld-gui to desktop-dkde's rundeps, `services = [... "firewalld"]` in images/dkde.toml, and check that dkde's Network settings page and NetworkManager zone handling work with it.
snapd survey 2026-11-15 (not written, question for the user): snapd 2.78 (canonical/snapd; the release has a ready-made `snapd_2.78.vendor.tar.xz` with the Go dependencies, which would suit the offline build). The problem is not the build but what snapd needs to run: it mounts each snap through a systemd mount unit and runs snap services, timers and the refresh logic as systemd units (`systemctl`), and snap-confine expects cgroup and namespace behaviour set up by systemd. Distributions without systemd (Alpine, Void, Artix) have no supported snapd; the community attempts exist but are partial. This system runs dinit and elogind. Options: (a) leave snapd out and point snap users at Flatpak (in the tree, with the Flathub remote); (b) package snapd anyway as an inert, probably non-working package; (c) write a small systemd-compatibility layer for dinit (a large project). Claude's recommendation: (a), and ask again if a specific snap is needed.
Rescue disk, 2026-11-15 (user: cups and online accounts are optional; drop most of the extras, keep papirus-icon-theme and the Noto fonts with the emoji font): desktop-dkde is split. `desktop-dkde-core` is the desktop without cups, cups-filters, ocrmypdf, gnome-online-accounts-gtk, bluez, swaylock, qt6ct, kvantum, webp-pixbuf-loader, libmtp and chrony; `desktop-dkde` is core plus those (r5); images/rescue.toml installs the core. An image's `unwanted` list could not do it: it becomes an apk conflict (`!name`) and desktop-dkde depends on them. Other candidates the rescue disk may not need, not removed: bluez, swaylock, kvantum/qt6ct, papirus-icon-theme, fonts-noto and its emoji font, libmtp, chrony, webp-pixbuf-loader.
Firewall policy 2026-11-15 (user: favour nftables and firewalld; iptables and ufw are for those who prefer the older setup): firewalld has nftables as its only dependency and default backend; the paths of the iptables, ebtables and ipset tools are compiled in (/usr/sbin) but they are not dependencies, so an image does not get them: whoever wants the iptables backend or `direct` rules installs them and sets FirewallBackend=iptables (one package, by the user's choice); the iptables package's plain names (iptables, iptables-save, iptables-restore, ip6tables ...) now point to the nftables compat backend (xtables-nft-multi, r2), and iptables-legacy ... keep the old backend; ufw (queue) works on top of the iptables tools. The dkde ISO does not install iptables unless something asks for it (docker/moby does).
AI stack finished as far as it can be packaged natively, 2026-11-15 (wip/queue/ai-stack/NOTES.md): written: docling + OCR engines, MinerU, RAG-Anything, LightRAG, Apache Tika (prebuilt Apache release), PyTorch, transformers, sentence-transformers, torchvision and the rest of the Priority 1-4 list. Not packaged, and why: kotaemon (pins a Python 3.10-3.12 stack: a Python 3.12 venv, or podman/Incus, not docker), Verba (Python < 3.13 + a Weaviate server), danswer/Onyx (Vespa; multi-service: podman or Incus containers, not docker), the legal RAG repos (sample projects). A python3.12 package (beside 3.14, versioned names only) is in the queue, so these apps can run in a venv.
dosemu2, second survey 2026-11-15 (not written): comcom64's build (debian/control) needs `thunk-gen`, `djstub`, `dj64-dev` and `dj32-dev` (the dj64 project: a 64-bit DJGPP environment, repositories of stsp/dj64dev) and a DJGPP-style cross toolchain for the 32-bit DOS programs; fdpp (1.11, meson, nasm, clang) builds the FreeDOS kernel with its own thunks; dosemu2 itself (a `devel` commit, no release tags) needs fdpp, djdev64, comcom64, binutils for i686 and the libraries listed earlier (slirp, b64, searpc, fluidsynth, ladspa, ieee1284 ...). That is about eight new packages from several repositories plus a cross compiler: libieee1284 and libb64 are the easy parts (libieee1284 is in the queue). Waiting for a decision: spend the effort (a day of recipes, no guarantee the thunk and DJGPP parts build on musl), or leave DOS to dosbox-staging (in the tree) and wine. Claude's recommendation: dosbox-staging, and revisit if a DOS program needs dosemu2's host file integration.
