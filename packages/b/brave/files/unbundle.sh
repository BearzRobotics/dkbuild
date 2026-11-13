#!/bin/sh
# FenrirOS: packages/c/chromium's unbundle.sh (Chimera's script with `gfind` as
# `find`), and Brave's tree (./brave: its patches/third_party/ffmpeg, its
# node_modules) left alone: only Chromium's bundled copies are removed.

_lib="$1"

echo "Removing buildscripts for system provided $_lib"
find . -type f -path "*third_party/$_lib/*" \
    \! -path "*third_party/$_lib/chromium/*" \
    \! -path "*third_party/$_lib/google/*" \
    \! -path './brave/*' \
    \! -path './base/third_party/icu/*' \
    \! -path './third_party/libxml/*' \
    \! -path './third_party/pdfium/third_party/freetype/include/pstables.h' \
    \! -path './third_party/harfbuzz-ng/utils/hb_scoped.h' \
    \! -path './third_party/crashpad/crashpad/third_party/zlib/zlib_crashpad.h' \
    \! -regex '.*\.\(gn\|gni\|isolate\|py\)' \
    -delete
