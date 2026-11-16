# Search engines (requested 2026-11-16)

The list: YaCy, Marginalia Search, Apache Nutch, Apache StormCrawler, Vespa, SearXNG, Meilisearch,
Typesense, Apache Lucene (and fail2ban, which was already in the tree). Written 2026-11-16, in wip/queue
because the main tree is mid-run; none of it is built or fetched yet (expect first-build fixes).

## Written

| package | how | notes |
|---|---|---|
| meilisearch 1.57.0 | cargodeps | mini-dashboard zip is a source, patch makes build.rs read it (MEILI_DASHBOARD_ZIP); MEILI_NO_VERGEN=1; EE code (LICENSE-EE) built as upstream's default; inert service, loopback config, dev mode, analytics off |
| lucene 10.6.0 | gradledeps (Gradle 9.8.0 source, openjdk21) | upstream's assembleBinaryTgz installed whole in /usr/share/lucene, jars linked in /usr/share/java/lucene, `lucene-luke` launcher. Lucene's Gradle build is strict (validation, forbidden-apis, javadoc): first-build fixes likely |
| yacy 1.941 | Ant, jars through a synthetic Gradle project | build.xml resolves with Ivy over the network. patches/offline-libs-from-gradle.patch adds build.gradle (the 86 coordinates of ivy.xml, generated from it; `->master` = non-transitive, excludes kept) that gradledeps resolves; `gradle copyYacyLibs` fills lib/; the patch makes `resolve` use lib/ and drops the ivy.jar download. Inert service, data in ~/yacy-data |

## Not written, and why (each is a piece of work, not an oversight)

- **SearXNG** (git master; no tagged releases, version = commit date). Pure Python, the web assets are
  committed (searx/static/themes/simple is built), requirements.txt pins 17 packages: python-lock would
  take it (pydeps, like pgadmin4). The blocker is `curl_cffi` (a hard import in webapp.py and
  extended_types.py): it needs libcurl-impersonate (curl built with BoringSSL and browser-impersonation
  patches, from lexiforest/curl-impersonate), which is not in the tree. Plan: libcurl-impersonate
  (+ boringssl, nghttp2, brotli, zstd as it asks), then python-curl-cffi, then searxng. Server: granian is
  a Rust sdist (maturin, crates not vendorable through pydeps); use waitress (pure wheel) with
  `searx.webapp:app`. Defaults to bind 127.0.0.1, secret_key must be set by the admin (inert).
- **Apache Nutch** 1.23 (tag release-1.23; the 2.x line is dead). Ant + Ivy like YaCy, but each of the ~50
  plugins has its own ivy.xml and `ant runtime` retrieves per plugin: the synthetic-Gradle trick works,
  with a generator over every ivy.xml and a patch of build-ivy.xml. Larger than YaCy's.
- **Apache StormCrawler** 3.7.0: Maven (pom.xml, ~20 modules, Java 25: openjdk25 is in the tree). No Maven
  package in the tree and no offline Maven resolution in the engine (only Gradle's). Options: a `mavendeps`
  engine option (resolve with `mvn dependency:go-offline` in a networked first step, like gradledeps), or
  package apache-maven first. It is a library/framework for Storm topologies; the useful artifact is a set
  of jars and archetypes, and it needs Apache Storm at run time (not in the tree).
- **Marginalia Search** (v24.10.0 tag is old; master is the maintained line): Gradle, 87 subprojects,
  plugins (shadow, jmh, jib), recent Java. Needs the services around it at run time (MariaDB, a message
  broker/ZooKeeper-like service registry), so a package alone does not run: a decision on how far to go.
- **Typesense** v30.2: CMake, but cmake/*.cmake download and build ~12 third parties (onnxruntime,
  onnxruntime_ext, H2O, RocksDB, s2, jemalloc, iconv, hnsw, kakasi, lrucache, GoogleTest, test resources)
  with ExternalProject. Each is a source to pin and a download to replace with a local path; some exist as
  packages (rocksdb, jemalloc). onnxruntime is the heavy one.
- **Vespa** 8.788.13: ~250 Maven modules (Java 21/25) plus a CMake C++ part (searchlib, vespamalloc...) and
  Bazel-built pieces; upstream builds with a dedicated container image. Not practical to package natively
  yet; needs Maven support in the engine first.

Order I would take: Maven support in the engine (StormCrawler, Vespa's Java side), libcurl-impersonate chain
(SearXNG), then the Ivy generator for Nutch, then Typesense's third parties.
