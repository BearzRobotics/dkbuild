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

## Written since (same day, after "most of this sounds like you just don't want to do the work")

| package | how | notes |
|---|---|---|
| libcurl-impersonate 2.3.1 | CMake superbuild, nine pinned sources | upstream's ExternalProject downloads become local files (sed on CMakeLists.txt, the hash checks stay); system libidn2+libunistring merged into the static archive CMake expects |
| python-curl-cffi 0.17.0 | sdist, links the static libcurl-impersonate.a | IMPERSONATE_BUILD_DIR points scripts/build.py at our package instead of the download |
| searxng (commit 2d500cb) | pip install, waitress | libraries it needed written too (python-valkey, -whitenoise, -waitress); inert service, placeholder secret_key |
| engine: `mavendeps` | src/build.zig, recipe.zig, maven-store.sh, SPEC.md 7.4 | the first build of a source runs the recipe's `restore` step (mvn commands) once with the network into the shared Maven-layout store; builds get `mvn` with that store as a file:// mirror. Not yet exercised on a real project |
| stormcrawler 3.7.0 | mavendeps, Java 25 | library jars only (a crawl is a Storm topology; Apache Storm itself is not in the tree) |
| nutch 1.23 | Ant + Ivy, Ivy pointed at the Maven store | patches/maven-resolution-poms.patch = generated Maven aggregator (one module per ivy.xml, files/ivy2pom.py); `-Drepo.maven.org=file:///dkdeps/maven/` and `-Divy.jar` |
| zookeeper 3.9.7 | mavendeps | inert service on 127.0.0.1:2181, no authentication (ZooKeeper's default) |
| openjdk26 26.0.2.1 | copy of openjdk25 recipe, built by JDK 25 | patches dry-run clean against jdk-26.0.2.1+1; needed by Marginalia (Gradle toolchain 26) |
| marginalia-search (commit 33ef7a1) | gradledeps + npmdeps (tailwindcss 3.4.17 lock in files/) | the aggregate "non-docker" distribution; models (incl. an 830 MB one) as sources; needs mariadb and zookeeper at run time; inert (install-dir helper + README) |

## Still not written

- **Typesense** v30.2: CMake. cmake/*.cmake download most third parties with `file(DOWNLOAD ...)` guarded by "if the
  tarball is not already in DEP_ROOT_DIR" (libfor, googletest 1.8.0, H2O, hnswlib, libiconv 1.15, jemalloc 5.3.0,
  kakasi, lru-cache, RocksDB 6.20.3, s2geometry, the three test text files): those are sources to pin and drop into
  DEP_ROOT_DIR before CMake runs, no source change. The hard part is ONNX Runtime 1.14 and onnxruntime-extensions
  0.6.0, which it builds from git with `git submodule update --remote` (branches, not pinned commits: 31 dependencies
  of cmake/deps.txt) and links as nine static libraries from the build directory. The tree has its own
  onnxruntime (1.30, wip/queue/packages/o/onnxruntime), so the plan is a patch that links Typesense's
  text_embedder*.cpp against that one (shared library, system headers) and builds the extensions' tokenizer
  operators from a pinned onnxruntime-extensions tarball; the 1.14 -> 1.30 C++ API differences are the risk.
  Next piece of work, in this order: pin and seed the ten download tarballs, then the onnxruntime port.
- **Vespa** 8.788.13: ~250 Maven modules (Java 21/25) plus a CMake C++ part (searchlib, vespamalloc, ...) and
  Bazel-built pieces; upstream builds in a dedicated container image (vespa-engine/vespa-build-almalinux-8).
  With `mavendeps` the Java side is now buildable offline in principle: Vespa's own `mvn install` order is
  documented in its README (the C++ part needs the Java-built config definitions). It also pulls Boost, ICU,
  protobuf, gRPC, OpenSSL, libzstd, lz4, xxhash, onnxruntime, RocksDB, a pinned Folly... : a large first build,
  next after Typesense.

Order I would take now: the first real build of the engine's mavendeps (stormcrawler is the smallest test), then
Typesense's seeded downloads and the onnxruntime port, then Vespa.
