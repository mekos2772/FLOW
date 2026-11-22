#!/bin/bash
# 取回 FLOW Voice 依赖的 ONNX Runtime 二进制（仓库里不提交这个 33MB 的文件）。
#
# 来源：微软在 PyPI 发布的官方 onnxruntime 1.32.0 wheel（macOS 14 / arm64）。
# 里面的 libonnxruntime.1.32.0.dylib 就是我们打进 OnnxRuntime.framework 的那份，
# 只改了 install name 并做 ad-hoc 签名；头文件、modulemap、Info.plist 已在仓库里。
#
# 两层校验：wheel 的 SHA-256（与 PyPI 公布值一致）+ 解出来的 dylib 的 SHA-256。任何一层不符就停。
#
# 用法：
#   ./Scripts/fetch-onnxruntime.sh           # 已存在就跳过
#   ./Scripts/fetch-onnxruntime.sh --force   # 重新下载覆盖

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${ROOT}/Vendor/OnnxRuntime/OnnxRuntime.xcframework/macos-arm64/OnnxRuntime.framework/Versions/A/OnnxRuntime"

WHEEL_URL="https://files.pythonhosted.org/packages/f1/0c/97eb4ac42266545d7630e8231f8cc969f5c3f144d2ee6cb568ef45f81360/onnxruntime-1.32.0-cp313-cp313-macosx_14_0_arm64.whl"
WHEEL_SHA256="27bf5dad46355a8a435c9c4e1556464d99ca834ea44e0f452909712068b8821b"
DYLIB_MEMBER="onnxruntime/capi/libonnxruntime.1.32.0.dylib"
DYLIB_SHA256="fa585fabbea65b823b9a8f7e27d46aee3989d1be7e36b528203d3a1fd613aae7"
INSTALL_NAME="@rpath/OnnxRuntime.framework/Versions/A/OnnxRuntime"

if [ -s "${TARGET}" ] && [ "${1:-}" != "--force" ]; then
    echo "ONNX Runtime 已就位：${TARGET}（要重新下载请加 --force）"
    exit 0
fi

for tool in curl unzip shasum install_name_tool codesign; do
    command -v "${tool}" >/dev/null || { echo "缺少命令：${tool}" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/flow-onnxruntime.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "下载 onnxruntime 1.32.0（约 17MB）…"
curl -fsSL --retry 3 --proto '=https' -o "${WORK}/ort.whl" "${WHEEL_URL}"

actual="$(shasum -a 256 "${WORK}/ort.whl" | awk '{print $1}')"
if [ "${actual}" != "${WHEEL_SHA256}" ]; then
    echo "wheel 校验失败：期望 ${WHEEL_SHA256}，实际 ${actual}" >&2
    exit 1
fi

# 只解出这一个文件，写到我们指定的位置。
unzip -p "${WORK}/ort.whl" "${DYLIB_MEMBER}" > "${WORK}/libonnxruntime.dylib"
actual="$(shasum -a 256 "${WORK}/libonnxruntime.dylib" | awk '{print $1}')"
if [ "${actual}" != "${DYLIB_SHA256}" ]; then
    echo "dylib 校验失败：期望 ${DYLIB_SHA256}，实际 ${actual}" >&2
    exit 1
fi

mkdir -p "$(dirname "${TARGET}")"
cp "${WORK}/libonnxruntime.dylib" "${TARGET}"
chmod 755 "${TARGET}"
install_name_tool -id "${INSTALL_NAME}" "${TARGET}"
codesign --force --sign - "${TARGET}" >/dev/null 2>&1

echo "完成：${TARGET}"
echo "SHA-256：$(shasum -a 256 "${TARGET}" | awk '{print $1}')"
