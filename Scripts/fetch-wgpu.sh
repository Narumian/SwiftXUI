#!/bin/bash
#
# fetch-wgpu.sh — wgpu-native のプリビルドを取得して CWGPU.xcframework を組み立てる。
#
# ビルドフェーズには入れない(ENABLE_USER_SCRIPT_SANDBOXING 対策)。
# 開発環境セットアップ時と wgpu-native 更新時に手で 1 回叩く。
#
#   bash Scripts/fetch-wgpu.sh
#
# Linux hosts use the companion script instead:
#   bash Scripts/fetch-wgpu-linux.sh
#
# 生成物: Vendor/CWGPU.xcframework  (git 管理外)
# スライス: ios-arm64 / ios-arm64-simulator / macos-arm64
#
set -euo pipefail

# wgpu-native のバージョンピン。
WGPU_VERSION="v29.0.1.1"

BASE_URL="https://github.com/gfx-rs/wgpu-native/releases/download/${WGPU_VERSION}"
PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${PKG_DIR}/Vendor"
WORK_DIR="${VENDOR_DIR}/.download"
OUT="${VENDOR_DIR}/CWGPU.xcframework"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "xcodebuild が見つからない(Xcode Command Line Tools が必要)"
command -v curl       >/dev/null || fail "curl が見つからない"
command -v unzip      >/dev/null || fail "unzip が見つからない"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Swift から `import CWGPU` するための Clang モジュール定義。
# wgpu.h は同ディレクトリの webgpu.h を #include "webgpu.h" で引く。
write_module_headers() {
  local headers_dir="$1"
  mkdir -p "${headers_dir}"
  cat > "${headers_dir}/CWGPU.h" <<'EOF'
#pragma once
// wgpu-native の C API をまとめて公開するアンブレラヘッダ。
#include "webgpu.h"
#include "wgpu.h"
EOF
  cat > "${headers_dir}/module.modulemap" <<'EOF'
module CWGPU {
    header "CWGPU.h"
    export *
}
EOF
}

# fetch_slice <xcframework-slice-name> <release-zip-name>
fetch_slice() {
  local slice="$1" zip="$2"
  local dir="${WORK_DIR}/${slice}"
  log "取得: ${slice}  (${zip})"
  mkdir -p "${dir}"
  curl -fSL --retry 3 -o "${dir}/wgpu.zip" "${BASE_URL}/${zip}" \
    || fail "ダウンロード失敗: ${BASE_URL}/${zip}"
  unzip -q -o "${dir}/wgpu.zip" -d "${dir}"
  [ -f "${dir}/lib/libwgpu_native.a" ] || fail "${slice}: libwgpu_native.a が無い"
  [ -f "${dir}/include/webgpu/webgpu.h" ] || fail "${slice}: webgpu.h が無い"

  local headers="${dir}/Headers"
  mkdir -p "${headers}"
  cp "${dir}/include/webgpu/webgpu.h" "${dir}/include/webgpu/wgpu.h" "${headers}/"
  write_module_headers "${headers}"

  XCF_ARGS+=( -library "${dir}/lib/libwgpu_native.a" -headers "${headers}" )
}

XCF_ARGS=()
fetch_slice "ios-arm64"           "wgpu-ios-aarch64-release.zip"
fetch_slice "ios-arm64-simulator" "wgpu-ios-aarch64-simulator-release.zip"
fetch_slice "macos-arm64"         "wgpu-macos-aarch64-release.zip"

log "xcframework を生成: ${OUT}"
rm -rf "${OUT}"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "${OUT}" >/dev/null \
  || fail "xcodebuild -create-xcframework に失敗"

rm -rf "${WORK_DIR}"
log "完了: $(cd "${VENDOR_DIR}" && ls -d CWGPU.xcframework)  (wgpu-native ${WGPU_VERSION})"
