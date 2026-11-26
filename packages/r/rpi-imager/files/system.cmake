# FenrirOS: the tree's own libraries, in place of the copies upstream's dependencies/*.cmake clone and build
# (xz, zstd, nghttp2, zlib, bzip2, libarchive, curl, libusb). Sets the variables the rest of CMakeLists.txt uses.
# yescrypt stays upstream's: it is part of the source.
find_package(PkgConfig REQUIRED)

find_package(LibLZMA REQUIRED)
find_package(ZLIB REQUIRED)

pkg_check_modules(ZSTD REQUIRED IMPORTED_TARGET libzstd)
set(ZSTD_LIBRARIES PkgConfig::ZSTD)
set(ZSTD_INCLUDE_DIR ${ZSTD_INCLUDEDIR})

find_package(LibArchive REQUIRED)

find_package(CURL REQUIRED)
set(CURL_INCLUDE_DIR ${CURL_INCLUDE_DIRS})

pkg_check_modules(USB REQUIRED IMPORTED_TARGET libusb-1.0)
set(LIBUSB_LIBRARIES PkgConfig::USB)
set(LIBUSB_INCLUDE_DIR ${USB_INCLUDE_DIRS})
