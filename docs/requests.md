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
