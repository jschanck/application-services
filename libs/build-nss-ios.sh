#!/usr/bin/env bash

# This script cross-compiles the NSS library for iOS.

set -euvx

if [[ "${#}" -ne 4 ]]
then
    echo "Usage:"
    echo "./build-nss-ios.sh <ABSOLUTE_SRC_DIR> <DIST_DIR> <ARCH> <IOS_MIN_SDK_VERSION>"
    exit 1
fi

NSS_SRC_DIR=${1}
DIST_DIR=${2}
ARCH=${3}
IOS_MIN_SDK_VERSION=${4}

if [[ -d "${DIST_DIR}" ]]; then
  echo "${DIST_DIR} folder already exists. Skipping build."
  exit 0
fi

if [[ "${ARCH}" == "x86_64" ]]; then
  OS_COMPILER="iPhoneSimulator"
  TARGET="x86_64-apple-darwin"
  GYP_ARCH="x64"
  EXTRA_TARGET="x86_64-apple-ios-simulator"
elif [[ "${ARCH}" == "arm64" ]]; then
  OS_COMPILER="iPhoneOS"
  TARGET="aarch64-apple-darwin"
  GYP_ARCH="arm64"
  EXTRA_TARGET="arm64-apple-ios"
elif [[ "${ARCH}" == "arm64-sim" ]]; then
  # We need to build nss for M1 sims ahead of time
  OS_COMPILER="iPhoneSimulator"
  TARGET="aarch64-apple-darwin"
  GYP_ARCH="arm64"
  # ARCH is used further down the line, but arm64-sim doesn't exist so we swap it back
  # to the original
  ARCH="arm64"
  EXTRA_TARGET="arm64-apple-ios-simulator"
else
  echo "Unsupported architecture"
  exit 1
fi

DEVELOPER=$(xcode-select -print-path)
CROSS_TOP="${DEVELOPER}/Platforms/${OS_COMPILER}.platform/Developer"
CROSS_SDK="${OS_COMPILER}.sdk"
TOOLCHAIN_BIN="${DEVELOPER}/Toolchains/XcodeDefault.xctoolchain/usr/bin"
ISYSROOT="${CROSS_TOP}/SDKs/${CROSS_SDK}"
CC="${TOOLCHAIN_BIN}/clang -target ${EXTRA_TARGET} -arch ${ARCH} -isysroot ${ISYSROOT} -mios-version-min=${IOS_MIN_SDK_VERSION}"

# Build NSPR
NSPR_BUILD_DIR=$(mktemp -d)
pushd "${NSPR_BUILD_DIR}"
"${NSS_SRC_DIR}"/nspr/configure \
  STRIP="${TOOLCHAIN_BIN}/strip" \
  RANLIB="${TOOLCHAIN_BIN}/ranlib" \
  AR="${TOOLCHAIN_BIN}/ar" \
  AS="${TOOLCHAIN_BIN}/as" \
  LD="${TOOLCHAIN_BIN}/ld" \
  CC="${CC}" \
  CCC="${CC}" \
  --target "${TARGET}" \
  --enable-64bit \
  --disable-debug \
  --enable-optimize
make
popd

# Build NSS
BUILD_DIR=$(mktemp -d)
rm -rf "${NSS_SRC_DIR}/nss/out"

# NSS 3.121 gcm.gyp sets HAVE_PLATFORM_GCM for x86_64 iOS
# simulator because 'target_arch=="x64" and OS!="win"' matches iOS.
# `intel-gcm-wrap` is not built for iOS and no lib provides 
# platform_gcm_support for this target, causing a linker error. 
# Until Bug 2019090 is fixed upstream, this will patch `gcm.gyp` to exclude iOS.
sed -i '' \
  's/target_arch=="x64" and OS!="win"/target_arch=="x64" and OS!="win" and OS!="ios"/g' \
  "${NSS_SRC_DIR}/nss/lib/freebl/gcm.gyp"

# Held in one variable so that the dependency dump further down describes the
# same configuration as the build.
GYP_FLAGS=(
  --depth "${NSS_SRC_DIR}/nss/"
  --generator-output=.
  -DOS=ios
  -Dnspr_lib_dir="${NSPR_BUILD_DIR}/dist/lib"
  -Dnspr_include_dir="${NSPR_BUILD_DIR}/dist/include/nspr"
  -Dnss_dist_dir="${BUILD_DIR}"
  -Dnss_dist_obj_dir="${BUILD_DIR}"
  -Dhost_arch="${GYP_ARCH}"
  -Dtarget_arch="${GYP_ARCH}"
  -Dstatic_libs=1
  -Ddisable_dbm=1
  -Dsign_libs=0
  -Denable_sslkeylogfile=0
  -Ddisable_tests=1
  -Ddisable_libpkix=1
  -Diphone_deployment_target="${IOS_MIN_SDK_VERSION}"
  -Dpython=python3
)
gyp -f ninja "${NSS_SRC_DIR}/nss/nss.gyp" "${GYP_FLAGS[@]}"

GENERATED_DIR="${NSS_SRC_DIR}/nss/out/Release-$(echo ${OS_COMPILER} | tr '[:upper:]' '[:lower:]')/"
ninja -C "${GENERATED_DIR}"

mkdir -p "${DIST_DIR}/include/nss"
mkdir -p "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libcertdb.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libcerthi.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libcryptohi.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libfreebl_static.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libgcm.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libmozpkix.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libnss_static.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libnssb.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libnssdev.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libnsspki.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libnssutil.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libpk11wrap_static.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libpkcs12.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libpkcs7.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libsmime.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libsoftokn_static.a" "${DIST_DIR}/lib"
cp -p -L "${BUILD_DIR}/lib/libssl.a" "${DIST_DIR}/lib"
# HW specific.
if [[ "${ARCH}" == "x86_64" ]]; then
  cp -p -L "${BUILD_DIR}/lib/libghash-aes-x86_c_lib.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libhw-acc-crypto-avx.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libhw-acc-crypto-avx2.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libsha-x86_c_lib.a" "${DIST_DIR}/lib"
elif [[ "${ARCH}" == "arm64" ]]; then
  cp -p -L "${BUILD_DIR}/lib/libghash-aes-aarch64_c_lib.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libarmv8_c_lib.a" "${DIST_DIR}/lib"
fi
cp -p -L "${NSPR_BUILD_DIR}/dist/lib/libplc4.a" "${DIST_DIR}/lib"
cp -p -L "${NSPR_BUILD_DIR}/dist/lib/libplds4.a" "${DIST_DIR}/lib"
cp -p -L "${NSPR_BUILD_DIR}/dist/lib/libnspr4.a" "${DIST_DIR}/lib"

cp -p -L -R "${BUILD_DIR}/public/nss/"* "${DIST_DIR}/include/nss"
cp -p -L -R "${NSPR_BUILD_DIR}/dist/include/nspr/"* "${DIST_DIR}/include/nss"

# pkg-config metadata for the static link, so that consumers don't have to
# rediscover how NSS splits itself into archives. nss/build.sh writes these for
# the platforms it drives, but this script calls gyp directly, so nothing here
# produces them. Skipped on an NSS too old to supply the templates.
NSS_PC_IN="${NSS_SRC_DIR}/nss/pkg/pkg-config/nss-static.pc.in"
NSS_STATIC_LIBS_PY="${NSS_SRC_DIR}/nss/coreconf/static_libs.py"
NSPR_PC="${NSPR_BUILD_DIR}/config/nspr.pc"
if [[ -f "${NSS_PC_IN}" && -f "${NSS_STATIC_LIBS_PY}" && -f "${NSPR_PC}" ]]; then
  mkdir -p "${DIST_DIR}/lib/pkgconfig"

  # configure generates NSPR's .pc, but only `make install` puts it in place and
  # its paths point at --prefix rather than at this dist. NSPR's headers are
  # copied in beside NSS's, so includedir is shared.
  NSPR_VERSION=$(sed -n 's/^Version: *//p' "${NSPR_PC}")
  sed -e "s|^prefix=.*|prefix=${DIST_DIR}|" \
      -e "s|^exec_prefix=.*|exec_prefix=\${prefix}|" \
      -e "s|^libdir=.*|libdir=\${exec_prefix}/lib|" \
      -e "s|^includedir=.*|includedir=${DIST_DIR}/include/nss|" \
      -e "s|-L[^ ]*|-L\${libdir}|" \
      -e "s|-I[^ ]*|-I\${includedir}|" \
      "${NSPR_PC}" > "${DIST_DIR}/lib/pkgconfig/nspr.pc"

  # Ask gyp for the dependency graph of the build just done, rather than
  # repeating the archive list above in link order. static_libs.py keeps only
  # the targets it finds built, so pointing it at the dist restricts the result
  # to the archives actually copied there.
  gyp -f dump_dependency_json -Goutput_dir="${BUILD_DIR}" \
    "${NSS_SRC_DIR}/nss/nss.gyp" "${GYP_FLAGS[@]}"
  NSS_STATIC_LIBS=$(python3 "${NSS_STATIC_LIBS_PY}" \
    "${BUILD_DIR}/dump.json" "${DIST_DIR}/lib")

  NSS_H="${NSS_SRC_DIR}/nss/lib/nss/nss.h"
  NSS_VMAJOR=$(sed -n 's/^#define NSS_VMAJOR \([0-9]*\).*/\1/p' "${NSS_H}")
  NSS_VMINOR=$(sed -n 's/^#define NSS_VMINOR \([0-9]*\).*/\1/p' "${NSS_H}")
  NSS_VPATCH=$(sed -n 's/^#define NSS_VPATCH \([0-9]*\).*/\1/p' "${NSS_H}")

  sed -e "s|%prefix%|${DIST_DIR}|g" \
      -e "s|%exec_prefix%|\${prefix}|g" \
      -e "s|%libdir%|\${exec_prefix}/lib|g" \
      -e "s|%includedir%|${DIST_DIR}/include/nss|g" \
      -e "s|%NSS_VERSION%|${NSS_VMAJOR}.${NSS_VMINOR}.${NSS_VPATCH}|g" \
      -e "s|%NSPR_VERSION%|${NSPR_VERSION}|g" \
      -e "s|%STATIC_LIBS%|${NSS_STATIC_LIBS}|g" \
      "${NSS_PC_IN}" > "${DIST_DIR}/lib/pkgconfig/nss-static.pc"
fi
