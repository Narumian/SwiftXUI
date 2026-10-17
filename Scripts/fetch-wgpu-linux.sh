#!/bin/bash
#
# fetch-wgpu-linux.sh — wgpu-native Linux prebuild into Vendor/linux-x86_64.
#
# Companion to Scripts/fetch-wgpu.sh (Apple xcframework). Run on Linux hosts /
# Cloud Agents before building XRenderWGPU / XRenderLinux.
#
#   bash Scripts/fetch-wgpu-linux.sh
#
# Output: Vendor/linux-x86_64/  (git-ignored under Vendor/)
#
set -euo pipefail

WGPU_VERSION="v29.0.1.1"

BASE_URL="https://github.com/gfx-rs/wgpu-native/releases/download/${WGPU_VERSION}"
PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${PKG_DIR}/Vendor"
WORK_DIR="${VENDOR_DIR}/.download-linux"
OUT="${VENDOR_DIR}/linux-x86_64"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ZIP="wgpu-linux-x86_64-release.zip"; SLICE="linux-x86_64" ;;
  aarch64|arm64) ZIP="wgpu-linux-aarch64-release.zip"; SLICE="linux-aarch64"; OUT="${VENDOR_DIR}/linux-aarch64" ;;
  *) printf 'error: unsupported arch %s\n' "$ARCH" >&2; exit 1 ;;
esac

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl  >/dev/null || fail "curl not found"
command -v unzip >/dev/null || fail "unzip not found"

rm -rf "${WORK_DIR}" "${OUT}"
mkdir -p "${WORK_DIR}" "${OUT}/lib" "${OUT}/include"

log "fetch ${SLICE} (${ZIP})"
curl -fSL --retry 3 -o "${WORK_DIR}/wgpu.zip" "${BASE_URL}/${ZIP}" \
  || fail "download failed: ${BASE_URL}/${ZIP}"
unzip -q -o "${WORK_DIR}/wgpu.zip" -d "${WORK_DIR}"
[ -f "${WORK_DIR}/lib/libwgpu_native.a" ] || fail "libwgpu_native.a missing"
[ -f "${WORK_DIR}/include/webgpu/webgpu.h" ] || fail "webgpu.h missing"

cp "${WORK_DIR}/lib/libwgpu_native.a" "${OUT}/lib/"
cp "${WORK_DIR}/include/webgpu/webgpu.h" "${WORK_DIR}/include/webgpu/wgpu.h" "${OUT}/include/"

cat > "${OUT}/include/CWGPU.h" <<'EOF'
#pragma once
// wgpu-native C API umbrella for Swift `import CWGPU`.
#include "webgpu.h"
#include "wgpu.h"
EOF

# systemLibrary path root must expose module.modulemap.
# Do not `link "wgpu_native"` here — Package.swift force-links the static .a.
cat > "${OUT}/module.modulemap" <<'EOF'
module CWGPU {
    header "include/CWGPU.h"
    export *
}
EOF

rm -rf "${WORK_DIR}"
log "done: ${OUT}  (wgpu-native ${WGPU_VERSION})"
