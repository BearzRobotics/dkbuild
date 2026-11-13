# Android NDK from source (plan, 2026-11-12)

Google's NDK release (ndk-r30) is assembled from prebuilts: its repo manifest
(platform/manifest, tag ndk-r30) checks out prebuilts/clang (Android's LLVM),
prebuilts/ndk/platform/sysroot (made by an internal platform build, 15178783),
prebuilts/simpleperf, cmake, ninja, python. All of those are open source, so
FenrirOS builds the same pieces itself:

| NDK part | Where it comes from here |
|---|---|
| clang, lld, llvm-* tools | the system LLVM (all backends: AArch64, ARM, X86, RISCV), through `<triple><api>-clang` wrappers; the NDK's own resource dir holds the Android compiler-rt |
| compiler-rt builtins, libunwind, libc++/libc++abi (`libc++_shared.so`, `libc++_static.a`) for aarch64, armv7a, i686, x86_64, riscv64 | built from the tree's LLVM source against the sysroot below (like llvm-runtimes-mingw-w64) |
| sysroot headers (bionic libc + kernel uapi, EGL/GLES/Vulkan, android/*, aaudio, camera, media, amidi, SLES/OMXAL, binder_ndk, NNAPI, jni, zlib, icu4c) | the AOSP repositories at android-17.0.0_r1 (API 37, as r30), installed by the rules in their Android.bp `ndk_headers` modules |
| sysroot stub libraries (libc.so, libm.so, libdl.so, liblog.so, libandroid.so, libvulkan.so, ... per API level 21..37) | generated from each library's `.map.txt` symbol file with ndkstubgen (build/soong/cc/ndkstubgen, Python) and compiled per arch and API, as the platform build does |
| crtbegin/crtend objects | compiled from bionic/libc/arch-common/bionic |
| libc.a, libm.a, libdl.a, libz.a (static executables) | phase 2: bionic built outside Soong (its libc/Android.bp source lists turned into a build file) |
| ndk-build, build/cmake/android.toolchain.cmake, meta/, sources/android (cpufeatures, native_app_glue), source.properties | platform/ndk at tag ndk-r30 |
| shader-tools (glslc) | the tree's shaderc |
| make | the system GNU make |
| simpleperf, lldb-server for devices | phase 2 (system/extras/simpleperf, LLVM's lldb-server cross-built) |

Sources: a `snapshot:android-ndk ndk-r30 android-17.0.0_r1` (new dkbuild snapshot
script) with shallow, sparse checkouts of platform/ndk, bionic,
frameworks/native, frameworks/av, frameworks/base (native/ only),
frameworks/wilhelm, system/logging, system/core (libsync), libnativehelper,
packages/modules/NeuralNetworks, external/icu (libandicu), external/zlib,
external/vulkan-headers, build/soong (ndkstubgen, symbolfile).

Differences from Google's NDK to state in the recipe: newer clang (the tree's,
not Android's fork), no static bionic until phase 2, no Windows/macOS hosts.
