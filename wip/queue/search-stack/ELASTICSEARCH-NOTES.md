# Elasticsearch 8 from source (asked 2026-11-17, for the Ahmia stack)

Why 8.x: the Ahmia Python client is elasticsearch 8.17.1, which refuses other servers (OpenSearch fails its
product check). Newest 8.x release when surveyed: v8.19.25 (v9.x exists; the 8.x client is not meant for it).

## Facts found (all from the v8.19.25 tag and the artifact hosts, checked 2026-11-17)

- Build tool: Gradle 9.7.1 (`gradle/wrapper/gradle-wrapper.properties`, sha256 acd53f1edaf02f1a8ff99879f8a34b302661a057d9b063ae9e35b552f804d20a),
  so a `gradledeps` recipe with `gradle-9.7.1-bin.zip` as a source, like lucene.
- Compiler JDK: Java 21 or newer (openjdk21 or openjdk25 are in the tree); Lucene 9.12.2 and Netty 4.1.138 come
  with it. Dependency list in build-tools-internal/version.properties (jackson, log4j, bouncycastle 1.86, aws sdk v2,
  opensaml, protobuf, ...): `gradledeps` fetches them once with the network.
- Licence: AGPL-3.0-only OR SSPL-1.0 OR Elastic-2.0 (x-pack is under Elastic-2.0, the rest triple/Apache). The 8.x client
  and security (TLS + passwords, which Ahmia needs) are in the default distribution; there is no OSS-only archive in 8.x.
- Distribution archives in 8.x: only `linux-tar` / `linux-aarch64-tar` (plus darwin/windows). There is NO "no-jdk" archive
  like 7.x had. Task: `:distribution:archives:linux-tar:assemble`.

## Blockers to solve at the first build

1. Bundled JDK: `distribution/build.gradle` applies `elasticsearch.jdk-download` and pulls `bundled_jdk = 27.0.1.0.3`
   (OpenJDK 27 early/GA builds from the ES JDK archive) into the tarball. The tree has openjdk17/21/25/26, no 27.
   Options: (a) supply that JDK tarball as a recipe source and point the plugin at it; (b) patch the archive
   task not to bundle one and make `bin/elasticsearch` use `ES_JAVA_HOME` (openjdk25 or newer, which ES 8.19 accepts:
   not verified); (b) is the better fit for a package manager. Needs a look at BundledJdkPlatforms and the
   `jdks { }` blocks in distribution/build.gradle, then a patch (documented in the recipe).
2. Machine-learning native code: x-pack/plugin/ml declares `org.elasticsearch.ml:ml-cpp:8.19.25:deps@zip` and `:nodeps@zip`,
   resolved from `-Dbuild.ml_cpp.repo` (default https://prelert-artifacts.s3.amazonaws.com; pattern
   maven/org/elasticsearch/ml/ml-cpp/[revision]/ml-cpp-[revision](-[classifier]).zip). Both zips answer HTTP 200 at
   that host for 8.19.25. They are Elastic's prebuilt C++ binaries (Elastic-2.0). Plan: both as recipe sources, laid out in
   that Maven structure in a directory the build reads through the property. (The ML engine itself is not needed by
   Ahmia; the plugin is part of the default distribution and the build is simplest with it.)
3. Gradle toolchains: the build asks for several Java versions (the compiler JDK, the runtime baseline, test JDKs).
   Set `-Dorg.gradle.java.installations.paths=...` to the tree's JDKs and auto-download off, like the lucene recipe.
4. The build is large (about 700 Gradle projects): expect hours, several GB of cache, and first-build fixes for the
   precommit tasks (forbidden-apis, dependency licence checks, `git` for the build metadata: the lucene recipe already
   has `git` in hostdeps).
5. Runtime shape for the package: /usr/share/elasticsearch (the tarball's contents), config in /etc/elasticsearch,
   data in /var/lib/elasticsearch, user elasticsearch, inert dinit service. First start generates the `elastic` password
   and the HTTP CA (`config/certs/http_ca.crt`, which ahmia-site and ahmia-crawler point ES_CA_CERTS at).
   Needs vm.max_map_count >= 262144 (sysctl, shipped as a sysctl.d file).

## Status (2026-11-17, later)

Recipe written: wip/queue/packages/e/elasticsearch. Blocker 1 solved on paper: patches/no-bundled-jdk.patch (no bundled JDK
registered or copied; $ES_HOME/jdk is a link to openjdk21; Java 17 is the build and runtime minimum, read from
build-tools-internal/src/main/resources). Without a .git directory the build info says "unknown", so no git repo is needed.
Blocker 2: left to gradledeps (store lookup of ml-cpp); fallback in the recipe header. Not built.
