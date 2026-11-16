# Features switched off for now

Optional features stay ON, even heavy ones. A feature may be turned off only when it poses a serious
build problem, other distributions do not commonly enable it (or it cannot be had at all yet), and only
for now: it is written here with the reason, and in the recipe, so it can be brought back. (User policy,
2026-11-15.) Anything that is a choice between two backends, not a lost feature, is not listed here.

| Package | Switched off | Since | Why | To bring it back |
|---|---|---|---|---|
| gvfs | Google Drive backend (`-Dgoogle=false`) | 2026-11-16 | needs libgdata (not in the tree), and libgdata 0.18.1/0.19.0 needs libsoup 2.4; the tree has libsoup 3 only | package libsoup 2.74 beside libsoup 3, then libgdata (with `-Dgnome=false` or gcr-base-3, goa, gtk3), then `-Dgoogle=true` |
| quickshell | crash handler (`-DCRASH_HANDLER=OFF`) | 2026-11-15 | needs cpptrace, which fetches libdwarf at build time | package libdwarf and cpptrace, then turn it on |
| libwebsockets | HTTP/3 and QUIC (`-DLWS_WITH_HTTP3=OFF`) | 2026-11-16 | with HTTP/3 on, libwebsockets switches its TLS backend to GnuTLS, and its public header then clashes with OpenSSL's in every program that uses OpenSSL (mosquitto, kismet) | build the library against GnuTLS in a second package name, or wait for upstream to keep the backends apart; then turn HTTP/3 on |
| libmemcached-awesome | manual pages (`-DBUILD_DOCS_MAN=OFF`) | 2026-11-16 | the manual's reStructuredText fails with this Sphinx/docutils ("Inconsistent title style: skip from level 2 to 4"), which stops the build | fix the title levels in docs/source/bin/common/note_*.rst (a patch), then turn the man pages on |
