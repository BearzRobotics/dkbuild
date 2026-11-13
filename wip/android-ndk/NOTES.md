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

## Survey (2026-11-12): where every sysroot module is, at android-17.0.0_r1

Sparse, blob-less shallow clones (only Android.bp files) took seconds per
repository; the snapshot script can do the same, then widen each sparse
checkout to the `from`/`srcs`/`symbol_file` paths of the modules below and
pack only those. `ndk_headers` modules are simple (`from`, `to`, `srcs`
globs, `license`), so a small Python generator can install them as Soong does.

| Repository | ndk_headers / ndk_library |
|---|---|
| bionic | libc (9 header sets: libc, kernel uapi, per-arch asm), libc + libstdc++ stubs; libdl; libm |
| frameworks/native | android/*.h (top-level Android.bp), arect, binder_ndk, nativewindow, opengl (EGL, GLES 1-3, KHR: 5 header sets, 4 stubs), vulkan (libvulkan stub) |
| frameworks/av | camera2ndk, aaudio, mediandk |
| frameworks/base | amidi (headers + stub), libandroid and libjnigraphics (stubs; their headers are in frameworks/native) |
| frameworks/wilhelm | OpenSLES, OpenMAXAL |
| system/logging | liblog |
| system/core | libsync |
| system/extras | module_ndk_libs/libnativehelper (jni.h, libnativehelper) |
| packages/modules/NeuralNetworks | neuralnetworks |
| external/icu | libicu (headers + stub) |
| external/zlib | libz (headers + stub; libz.a built from the same source) |
| external/vulkan-headers | vulkan, vk_video headers |
| build/soong | cc/ndkstubgen, cc/symbolfile (the stub generator) |

Survey checkouts are in work/ndk/aosp (not in git).
