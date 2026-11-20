# Cockpit survey (2026-11-17), release 372 (cockpit-372.tar.xz, sha256 a74d28489341e880f73224174dd21e0b48ce7e78999801369855f74d6df4a53b, 16 MB; autotools, the JS bundles are already built in dist/)

Build needs: glib >= 2.68, json-glib, gnutls, krb5 (gssapi), PAM, libcrypt, and `libsystemd >= 235`
(configure checks `libsystemd.pc`, and `systemd.pc` for the unit directory unless
`--with-systemdunitdir` is given). The C code uses only sd-bus (src/session/client-certificate.c),
sd-login and sd-daemon (socket activation in ws/main.c, tls/server.c, tls/wsinstance-factory.c).
No sd-journal in C. elogind (in the tree, 255.17) provides those three APIs as libelogind; it has no
libsystemd.pc, so a `libsystemd.pc` shim pointing at elogind (Requires: libelogind) is needed, plus
`--with-systemdunitdir=/dev/null`-style configure arguments.

Runtime: cockpit-ws is started per connection by systemd socket units (src/systemd/*.socket,
cockpit-wsinstance-*@.service). dinit has socket-listen (it passes LISTEN_FDS), so one
`cockpit-ws` service that listens on 9090 is possible; the https-factory/instance split (one ws per
TLS certificate) can be run as a single instance. Login goes through PAM (`cockpit` PAM stack, which
PAM adoption already covers) and cockpit-session.

What would work without systemd: shell, terminal, files, accounts (users), network (NetworkManager is in the
tree), storage (udisks2 needed), metrics (PCP optional), packagekit (not here; an apk page would be new work).
What would not: Services, Logs (journal), Timers, and the System page's service list: they talk to
systemd over D-Bus and use journalctl. Those pages would show errors or be hidden.

Verdict: feasible but not simple (shim, a patch for the systemd unit dir, a dinit service, pages that break);
about a day with no guarantee. Not written. enforza-cockpit only needs `/usr/share/cockpit/enforza` and works
through cockpit-bridge, so it is usable once cockpit-ws and the bridge run.
