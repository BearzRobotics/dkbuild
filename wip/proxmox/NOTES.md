# Proxmox VE on FenrirOS — status notes

Map: github.com/SaumonNet/proxmox-nixos (Proxmox VE on NixOS) for versions,
patches and the non-Debian problems; Proxmox's own repositories at
git.proxmox.com (no tags: every recipe pins the commit that bumped the
Debian version, via `snapshot:git <repo> <commit>`).

## Written (packages/)

Proxmox components (all pinned to their "bump version" commits of 2026-11):

| recipe | version | notes |
|---|---|---|
| pve-common | 9.2.9 | systemd/journal/dpkg patches; ships the systemctl stand-in `/usr/libexec/pve-fenrir/systemctl`; generates syscall.ph with h2ph |
| pve-apiclient | 3.4.3 | |
| pve-access-control | 9.2.0 | PAM service file proxmox-ve-auth |
| pve-cluster | 9.1.9 | pmxcfs (needs fuse2, libqb, corosync, rrdtool), IPCC, pvecm; dinit pve-cluster; www-data via sysusers |
| pve-rs (+ pve-rs-common) | 0.16.1 | Rust/perlmod; Proxmox crates from git (patch + files/Cargo.lock); no libapt-pkg |
| proxmox-frr-templates | 0.1.2 | build dependency of pve-rs |
| pve-http-server | 6.0.7 | |
| pve-storage | 9.1.16 | PVE::RADOS stand-in (no Ceph) |
| pve-guest-common | 6.0.8 | |
| qemu-server | 9.2.15 | cgroup patch; dinit qmeventd, query-machine-capabilities, pve-dbus-vmstate@ |
| pve-container | 6.1.20 | dinit templates pve-container@, pve-container-debug@ |
| pve-firewall | 6.0.7 | legacy iptables/ebtables by name; dinit pve-firewall, pvefw-logger |
| proxmox-firewall-data | 0.1 | |
| pve-network | 1.6.9 | dinit template dnsmasq@ for SDN DHCP |
| pve-manager | 9.2.27 | apk updates API (files/APT.pm), syslog reader (files/mini-journalreader), UI patch, dinit services, README.FenrirOS |
| pve-ha-manager | 5.2.5 | dinit watchdog-mux, pve-ha-crm, pve-ha-lrm |
| pve-docs | 9.2.14 | HTML docs + all man pages + doc generator; no PDF/EPUB |
| proxmox-widget-toolkit (+ -dev) | 5.2.13 | esbuild instead of uglifyjs, no biome lint |
| proxmox-i18n | 3.11.0 | pve-i18n only |
| proxmox-acme (+ -plugins) | 1.7.3 | |
| proxmox-termproxy | 2.1.0 | Rust; Cargo.lock in files/ |
| pve-lxc-syscalld | 2.0.2 | Rust; Cargo.lock in files/; sd_notify without libsystemd |
| pve-xtermjs | 6.0.0 | |
| novnc-pve | 1.7.0 | |
| extjs | 7.0.0.9 | prebuilt GPL Ext JS (upstream's build/ files) |
| proxmox-ve | 9.2 | meta package |

Web/other dependencies: bootstrap5 5.3.9, fonts-font-awesome 4.7.0,
fonts-font-logos 1.0.1, qrcodejs (esbuild-minified), marked 18.2.0,
source-highlight 3.1.9 (asciidoc's filter, from cports).

CPAN modules (71 recipes, packages/p/perl-*, generated from MetaCPAN with a
script; each "Packaged for Proxmox VE"): AnyEvent(-HTTP), Authen-PAM,
Class-MethodMaker, Clone, Crypt-OpenSSL-{Bignum,Guess,RSA,Random},
Devel-{CheckLib,Cycle}, Digest-HMAC, Encode-Locale, File-{chdir,Listing,
ReadBackwards,Slurp,Which}, Filesys-Df, HTML-{Parser,Tagset},
HTTP-{Cookies,Daemon,Date,Message,Negotiate}, IO-{HTML,Multiplex,Stringy},
JSON-XS, Linux-Inotify2, Locale-PO, LWP-{MediaTypes,Protocol-https},
libwww-perl, MIME-Base32, Net-{DBus,DNS,HTTP,IP,Subnet}, NetAddr-IP,
perl-ldap, Pod-Parser, POSIX-strptime, Socket6, String-ShellQuote,
Term-ReadLine-Gnu, TimeDate, Try-Tiny, Types-Serialiser, UUID,
WWW-RobotRules, XML-{LibXML,NamespaceSupport,SAX,SAX-Base,Twig},
YAML-LibYAML, common-sense, Canary-Stability, Convert-ASN1, Capture-Tiny,
FFI-CheckLib, Alien-{Build,Build-Plugin-Download-GitLab,Libxml2} (XML::LibXML
uses the system libxml2), ExtUtils-{Config,Helpers,InstallPaths},
Module-Build-Tiny.

Written by helper agents (see their reports): libqb, kronosnet, corosync,
rrdtool (+ rrdtool-perl, rrdcached service), libnetfilter-log, ipset,
ebtables (legacy), libfaketime, cstream, dtach, lzop,
thin-provisioning-tools, virtiofsd, open-iscsi (+ open-isns), cifs-utils,
fuse2, lksctp-tools (kronosnet SCTP); pve-qemu,
proxmox-backup-qemu, pve-edk2-firmware (real edk2 build), python-virt-firmware, sndio,
libbsd, libmd. pve-qemu's snapshot sha256 is still a placeholder: its fetch
(QEMU with all ROM submodules, several GB) was still running at hand-off; put
the sha256 it prints (work/agent-scratch/pve-qemu/fetch-pveqemu.log) in the recipe.

## systemd / Debian assumptions patched

- `systemctl` (start/stop/restart/reload/enable/disable/is-active/show/kill/
  reset-failed/list-jobs, units name@instance and name@*): every Perl call is
  pointed (sed in each recipe, with a comment) at pve-common's stand-in
  `/usr/libexec/pve-fenrir/systemctl`, which maps to `dinitctl` (reload = SIGHUP
  for the PVE daemons and sshd, restart otherwise) and handles "*.scope" units
  as cgroup directories.
- Transient systemd scopes for VMs (`enter_systemd_scope` over D-Bus):
  cgroup v2 directories `qemu.slice/<vmid>.scope` created directly, with
  cpu.weight / cpu.max; `wait_for_unit_removed`, `is_unit_active` on cgroups;
  qemu-server's runtime CPU limit/weight changes write the cgroup.
- timedatectl (get/set/list timezones): /etc/localtime, /etc/timezone, tzdata.zi.
- journalctl (node syslog in the API) and proxmox-mini-journalreader (web UI
  System Log): /var/log/messages.
- dpkg --print-architecture: uname mapping.
- APT (updates, versions, pveversion, pveupgrade, pveupdate): apk.
- libsystemd sd_notify (pve-lxc-syscalld): pure Rust.
- libapt-pkg (pve-rs's proxmox-apt cache): feature disabled.
- systemd units: dinit services/templates for every PVE daemon and helper
  (shipped, never enabled).
- update-alternatives to the legacy iptables/ebtables: commands called by
  their -legacy names.
- Debian paths: /usr/share/perl5 -> Perl's vendor dir (plugins dirs too),
  /usr/share/misc/pci.ids -> /usr/share/hwdata, /usr/lib/<triplet>-linux-gnu
  -> /usr/lib, /sbin/{ip,bridge,tc} -> /usr/bin, /usr/sbin/dnsmasq ->
  /usr/bin, PAM service proxmox-ve-auth written.
- CPAN Crypt::OpenSSL::RSA 0.41 signs PSS/SHA-256 by default: PVE tickets
  select PKCS#1 v1.5/SHA-1 explicitly (from proxmox-nixos).

## Still open (systemd/Debian assumptions not handled)

- **Shutdown detection for HA**: pve-ha-lrm asks `systemctl list-jobs` for
  shutdown.target/reboot.target; the stand-in reports no jobs, so a planned
  shutdown looks like a node failure to HA (fencing/recovery policy). Needs a
  dinit-side signal (e.g. a shutdown hook writing a flag file) and a patch.
- **Container reboot from inside**: Debian's unit runs
  pve-container-stop-wrapper after lxc-start exits (EXIT_CODE) and restarts
  on the reboot flag; dinit does not run the stop command after the process
  exits, so a container rebooting itself stays stopped.
- **Network configuration**: no ifupdown2 (Proxmox fork, Python). The Network
  panel writes /etc/network/interfaces(.new) which nothing applies;
  pvenetcommit is not shipped; SDN needs ifupdown2 and FRR. Packaging
  Proxmox's ifupdown2 (git.proxmox.com/git/ifupdown2.git) is the fix.
- **Disk API "create directory storage"** writes systemd .mount units; ZFS
  pool creation enables zfs-import@<pool>.service: both do nothing here
  (would need fstab / dinit equivalents).
- **pve-firewall-commit / pvenetcommit / pve-daily-update** are dinit
  scripts or a sample cron line instead of systemd units/timers.
- **watchdog-mux's module** (WATCHDOG_MODULE from /etc/default/pve-ha-manager)
  is not read (no env-file in the dinit service; softdog default).
- **proxmox-log** writes to journald when present (tracing-journald);
  without it logs go to stderr/syslog — untested.
- **LXC**: Proxmox uses its fork lxc-pve (patches for its hooks/cgroup
  handling); this uses upstream LXC without AppArmor. Needs testing.
- **pveceph / Ceph**: no Ceph (huge C++ build); PVE::RADOS is a stand-in.
  pveceph also uses AptPkg::Cache and apt-get (Debian-only installer).
- **pvereport** runs Debian commands (dpkg, apt, journalctl...); partly broken.

## Not written yet, and why

- **ifupdown2** (Proxmox's Python fork) and **FRR**: network/SDN (above).
- **Ceph / librados2-perl**: Ceph itself.
- **proxmox-backup-client / proxmox-backup-file-restore**: PBS storage and
  file restore (Rust, proxmox-backup.git workspace; same crate approach as
  pve-rs).
- **proxmox-websocket-tunnel** (Rust): remote (cross-cluster) migration.
- **vncterm** (needs Debian's unifont.hex and wchardata.c, a patched
  libvncserver 0.9.14 bundled in the repo) and **spiceterm** (spice server):
  the old VNC/SPICE text consoles; xterm.js (termproxy) is the default console.
- **pve-yew-mobile-gui** (Rust → wasm, Yew): the mobile web UI.
- **proxmox-firewall** (Rust nftables firewall, optional successor of
  pve-firewall), **pve-esxi-import-tools** (Rust), **proxmox-mail-forward**,
  **ksm-control-daemon/ksmtuned**, **pve-zsync**.
- **pve-ha-simulator** (needs Perl Gtk3).
- **Shell completions** of all CLI tools: generated by loading the whole PVE
  stack at build time, which is circular between packages (Debian bootstraps
  it). Could be a final "pve-completions" recipe depending on everything.
- **PDF/EPUB admin guide**: dblatex + TeX Live.
