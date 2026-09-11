#!/usr/bin/env bash

# This script cross-compiles the NSS library for Android.

set -euvx

if [[ "${#}" -ne 5 ]]
then
    echo "Usage:"
    echo "./build-nss-android.sh <ABSOLUTE_SRC_DIR> <DIST_DIR> <TOOLCHAIN_PATH> <TOOLCHAIN> <ANDROID_NDK_API_VERSION>"
    exit 1
fi

NSS_SRC_DIR=${1}
DIST_DIR=${2}
TOOLCHAIN_PATH=${3}
TOOLCHAIN=${4}
ANDROID_NDK_API_VERSION=${5}

if [[ -d "${DIST_DIR}" ]]; then
  echo "${DIST_DIR} folder already exists. Skipping build."
  exit 0
fi

if [[ "${TOOLCHAIN}" == "x86_64-linux-android" ]]
then
  GYP_ARCH="x64"
  NSPR_64="--enable-64bit"
elif [[ "${TOOLCHAIN}" == "aarch64-linux-android" ]]
then
  GYP_ARCH="arm64"
  NSPR_64="--enable-64bit"
elif [[ "${TOOLCHAIN}" == "arm-linux-androideabi" ]]
then
  GYP_ARCH="arm"
else
  echo "Unknown toolchain"
  exit 1
fi
NSPR_64="${NSPR_64:-""}"

# shellcheck source=libs/build-android-common.sh
source ./build-android-common.sh

# Build NSPR
NSPR_BUILD_DIR=$(mktemp -d)
pushd "${NSPR_BUILD_DIR}"
"${NSS_SRC_DIR}"/nspr/configure \
  "${NSPR_64}" \
  --target="${TOOLCHAIN}" \
   --disable-debug \
   --enable-optimize
make
popd

# Build NSS
BUILD_DIR=$(mktemp -d)

BUILD_DIR=$(mktemp -d)
rm -rf "${NSS_SRC_DIR}/nss/out"
# Held in one variable so that the dependency dump further down describes the
# same configuration as the build.
GYP_FLAGS=(
  --depth "${NSS_SRC_DIR}/nss/"
  --generator-output=.
  -DOS=android
  -Dforce_integrated_as=1
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
  -Dpython=python3
)
gyp -f ninja-android "${NSS_SRC_DIR}/nss/nss.gyp" "${GYP_FLAGS[@]}"

GENERATED_DIR="${NSS_SRC_DIR}/nss/out/Release"
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
if [[ "${TOOLCHAIN}" == "x86_64-linux-android" ]]; then
  cp -p -L "${BUILD_DIR}/lib/libghash-aes-x86_c_lib.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libintel-gcm-wrap_c_lib.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libhw-acc-crypto-avx.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libhw-acc-crypto-avx2.a" "${DIST_DIR}/lib"
  cp -p -L "${BUILD_DIR}/lib/libsha-x86_c_lib.a" "${DIST_DIR}/lib"
fi
if [[ "${TOOLCHAIN}" == "aarch64-linux-android" ]] || [[ "${TOOLCHAIN}" == "arm-linux-androideabi" ]]; then
  cp -p -L "${BUILD_DIR}/lib/libarmv8_c_lib.a" "${DIST_DIR}/lib"
fi
if [[ "${TOOLCHAIN}" == "aarch64-linux-android" ]]; then
  cp -p -L "${BUILD_DIR}/lib/libghash-aes-aarch64_c_lib.a" "${DIST_DIR}/lib"
fi
if [[ "${TOOLCHAIN}" == "arm-linux-androideabi" ]]; then
  cp -p -L "${BUILD_DIR}/lib/libghash-aes-arm32-neon_c_lib.a" "${DIST_DIR}/lib"
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
