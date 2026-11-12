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
| Zammad | in progress. Done: pnpm support (dkbuild), Ruby 3.4.12. User chose (2026-11-11) Dart Sass from source: needs a Dart SDK (stage 0 from a prebuilt SDK, then self-hosting; its source a gclient snapshot like Electron's), a pub (Dart package) store in dkbuild, `buf` (protobuf tool, Go), dart-sass, and the sass-embedded gem patched to use the system dart-sass |

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
| InvoicePlane | invoices, estimates, clients, payments | MIT | later |
| InvoiceShelf | invoices, estimates, expenses, payments | AGPL-3.0 | later |
| SolidInvoice | invoicing and quotes | MIT | later |
| Dolibarr | invoices, accounting, CRM, inventory | GPL-3.0+ | later |
| ERPNext | full ERP, accounting, inventory, HR | GPL-3.0 | later |
| GnuCash | desktop accounting | GPL-2.0+ | planned (after the help desks; Alpine has a port) |
| Frappe Books | desktop accounting and invoicing | AGPL-3.0 | later |
| LedgerSMB | web double-entry accounting | GPL-2.0 | later |

Personal finance:

| Package | License | Status |
|---|---|---|
| KMyMoney | GPL-2.0+ | later |
| HomeBank | GPL-2.0+ | later |
| Skrooge | GPL-3.0+ | later |
| Firefly III | AGPL-3.0 | later |
| Beancount + Fava | GPL-2.0+ / MIT | later |
| Maybe Finance | check activity and licence first | later |

CRM:

| Package | License | Status |
|---|---|---|
| Twenty | AGPL-3.0 | later |
| SuiteCRM | AGPL-3.0 | later |
| Dolibarr | (above) | later |

## Project management and time tracking (2026-11-11)

| Package | License | Status |
|---|---|---|
| OpenProject | GPL-3.0 | later |
| Leantime | AGPL-3.0 | later |
| Taiga | MPL-2.0 | later |
| Kimai | AGPL-3.0 | later |
| Vikunja | AGPL-3.0 | later |

## Documents and office (2026-11-11)

| Package | Status |
|---|---|
| Paperless-ngx | later |
| Nextcloud (server; the desktop client is written) | later |
| ONLYOFFICE | later (Euro-Office, the fork, is planned) |
| LibreOffice | written |
| Stirling PDF | later |
| Joplin | later |
| BookStack | later |
| Mayan EDMS | later |

## Administration and network (2026-11-11)

| Package | Status |
|---|---|
| Zabbix | later |
| Netdata | later |
| Uptime Kuma | later |
| Cockpit | blocked: needs systemd |
| Webmin | later |
| AdGuard Home | later |
| Pi-hole | later |
| OPNsense | not a package: a FreeBSD-based firewall OS (FenrirOS could have a firewall image/kernel flavour instead) |
| WireGuard | written (wireguard-tools; the module is in the kernel) |
| Syncthing | later |

Also asked for: FileZilla (later), Blender (written), Remmina (written),
Docker (later; podman, buildah and skopeo are written).

## Mail (2026-11-11)

Clients:

| Package | License | Status |
|---|---|---|
| Thunderbird | MPL-2.0 | written |
| Betterbird | MPL-2.0 | later |
| Evolution | LGPL-2.1+ | later |
| KMail | GPL-2.0+ | written (KDE PIM) |
| Claws Mail | GPL | later |
| aerc | MIT | later |
| NeoMutt | GPL-2.0 | later |

Servers and parts ("everything needed to run a mail server"):

| Package | Purpose | Status |
|---|---|---|
| Stalwart Mail Server | SMTP, IMAP, POP3, JMAP, CalDAV, CardDAV (Rust) — first choice | later |
| Postfix | SMTP | later |
| Dovecot | IMAP/POP3 | later |
| Rspamd | spam filtering | later |
| Roundcube, SnappyMail | webmail | later |
| SOGo | groupware | later |
| OpenSMTPD, Exim | alternative MTAs | later |
| Mox | integrated mail server | later |
| listmonk | newsletters and mailing lists | later |

## Also 2026-11-11

| Package | Status |
|---|---|
| Passbolt (server) | written |
| fastfetch | written |
| GCC (all languages that do not shadow LLVM/Go) | written |
| Proxmox VE | planned (after Brave and Euro-Office) |
