#!/bin/bash
# 打一个可以直接发给别人的 FLOW Beta / 正式包（ad-hoc 签名 + DMG）。
#
# 为什么是 ad-hoc：开源分发不买苹果开发者账号。ad-hoc 签名能保证应用完整性、
# 也能带上沙盒与 App Group 权限，但没法和公证一起用——别人第一次打开要右键「打开」，
# ad-hoc 下也**不能**加 --options runtime（会拒载同为 ad-hoc 的 OnnxRuntime）。
#
# 用法：
#   ./Scripts/package-release.sh            # 版本号取自 Config/App-Info.plist
#   ./Scripts/package-release.sh 0.2.0      # 覆盖版本号（只影响文件名）
# 产物：dist/FLOW-<版本>-arm64.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

BUILD_DIR="${TMPDIR:-/tmp}/flow-release-package"
DIST="${ROOT}/dist"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/flow-package.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

[ -s Vendor/OnnxRuntime/OnnxRuntime.xcframework/macos-arm64/OnnxRuntime.framework/Versions/A/OnnxRuntime ] \
    || { echo "缺 ONNX Runtime，先跑 ./Scripts/fetch-onnxruntime.sh" >&2; exit 1; }

echo "构建 Release…"
xcodebuild build \
    -workspace SpatialLyricsPlayer.xcworkspace \
    -scheme SpatialLyricsPlayer \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${BUILD_DIR}" \
    CODE_SIGNING_ALLOWED=NO >/dev/null

BUILT="${BUILD_DIR}/Build/Products/Release/SpatialLyricsPlayer.app"
# 版本号从构建产物读：工程里是 $(MARKETING_VERSION) 占位，构建后才替换成真值。
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${BUILT}/Contents/Info.plist")}"
DMG="${DIST}/FLOW-${VERSION}-arm64.dmg"

APP="${STAGE}/FLOW.app"
ditto "${BUILT}" "${APP}"

echo "ad-hoc 签名（框架 → 小组件 → 主程序）…"
codesign --force --sign - "${APP}/Contents/Frameworks/OnnxRuntime.framework"
codesign --force --sign - --entitlements Config/Widget.entitlements "${APP}/Contents/PlugIns/SpatialLyricsWidgets.appex"
codesign --force --sign - --entitlements Config/App.entitlements "${APP}"
codesign --verify --deep --strict "${APP}"

ln -s /Applications "${STAGE}/Applications"
mkdir -p "${DIST}"
rm -f "${DMG}"
hdiutil create -quiet -volname FLOW -srcfolder "${STAGE}" -format UDZO "${DMG}"
hdiutil verify "${DMG}" >/dev/null

rm -rf "${BUILD_DIR}"
echo
echo "完成：${DMG}"
echo "SHA-256：$(shasum -a 256 "${DMG}" | awk '{print $1}')"
echo "提醒：这个包没有公证，别人第一次打开要右键「打开」；发布时上传到 GitHub Releases。"
