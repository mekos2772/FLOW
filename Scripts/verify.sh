#!/bin/bash
# 上线前一键验证。
#
# 为什么需要：验证项已经分成四类（单测、架构、死代码、Release 构建），
# 每次手动敲四条命令容易漏一条——而"漏掉的那条"往往就是出问题的那条。
#
# 用法：
#   ./Scripts/verify.sh            # 全量
#   ./Scripts/verify.sh --quick    # 跳过 Release 构建（约省 40 秒）

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
QUICK=0
LIVE=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --live)  LIVE=1 ;;
  esac
done

FAIL=0
step() { printf '\n=== %s ===\n' "$1"; }

step "1/4 单元测试"
# 退出码、最终成功标记与非零用例的零失败摘要必须同时满足，避免只看摘要假绿。
TEST_LOG=/tmp/slp-verify-tests.log
# --live 会真的联网跑 13 条集成测试（默认跳过）。发布前应当跑一次。
if [ "$LIVE" -eq 1 ]; then
  echo "（包含联网集成测试）"
  # `xcodebuild test` 不会把环境变量透传给测试宿主，
  # 所以走 `LiveTestGate` 支持的文件标记；结束时清掉，保持默认行为。
  touch /tmp/bili-live-test
  trap 'rm -f /tmp/bili-live-test' EXIT
fi
xcodebuild test -workspace SpatialLyricsPlayer.xcworkspace -scheme SpatialLyricsPlayer \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/slp-verify \
  -only-testing:SpatialLyricsPlayerTests CODE_SIGNING_ALLOWED=NO > "$TEST_LOG" 2>&1
TEST_STATUS=$?
SUMMARY=$(grep -E '^[[:space:]]*Executed [0-9]+ tests?,' "$TEST_LOG" | tail -1)
TEST_RESULT=$(grep -E '^[[:space:]]*\*\* TEST [A-Z]+ \*\*[[:space:]]*$' "$TEST_LOG" | tail -1)
echo "${SUMMARY:-（没有拿到测试摘要）}"
if [ "$TEST_STATUS" -ne 0 ] || [[ "$TEST_RESULT" != *'** TEST SUCCEEDED **'* ]]; then
  echo "！测试命令失败或缺少最终成功标记（xcodebuild 退出码 ${TEST_STATUS}），详见 $TEST_LOG"
  FAIL=1
fi
# XCTest 在测试进程崩溃时会**自动重启并继续**，最后仍然打印 0 failures。
# 兼容重启原因与大小写变化；即使最终成功，也不能掩盖重启。
RESTART_PATTERN='Restarting after|Restarting (the )?test (runner|process)|Test (runner|process).*(crashed|restarted|exited unexpectedly)'
RESTARTS=$(grep -ciE "$RESTART_PATTERN" "$TEST_LOG" || true)
if [ "${RESTARTS:-0}" -gt 0 ]; then
  echo "！测试进程崩溃或重启了 ${RESTARTS} 次（XCTest 会把它藏成 0 failures）"
  grep -iE -B 3 "$RESTART_PATTERN" "$TEST_LOG" | tail -12
  FAIL=1
fi

if ! printf '%s\n' "$SUMMARY" | grep -qE '^[[:space:]]*Executed [1-9][0-9]* tests?, (with )?([0-9]+ (tests? )?skipped and )?0 failures?([[:space:],]|$)'; then
  echo "！测试存在失败或用例未执行，详见 $TEST_LOG"
  grep -E "error: -\[" "$TEST_LOG" | head -5
  FAIL=1
fi

step "2/4 架构分层"
./Scripts/architecture-lint.sh || FAIL=1

step "3/4 死代码"
python3 Scripts/dead-code-scan.py || FAIL=1

if [ "$QUICK" -eq 0 ]; then
  step "4/4 Release 构建"
  BUILD_LOG=/tmp/slp-verify-release.log
  xcodebuild build -workspace SpatialLyricsPlayer.xcworkspace -scheme SpatialLyricsPlayer \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/slp-release CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1
  BUILD_STATUS=$?
  WARN=$(grep -cE 'warning:' "$BUILD_LOG" || true)
  BUILD_RESULT=$(grep -E '^[[:space:]]*\*\* BUILD [A-Z]+ \*\*[[:space:]]*$' "$BUILD_LOG" | tail -1)
  if [ "$BUILD_STATUS" -eq 0 ] && [[ "$BUILD_RESULT" == *'** BUILD SUCCEEDED **'* ]]; then
    echo "构建成功，警告 $WARN 条"
    [ "$WARN" -eq 0 ] || FAIL=1
  else
    echo "构建失败或缺少最终成功标记（xcodebuild 退出码 ${BUILD_STATUS}），详见 $BUILD_LOG"
    FAIL=1
  fi
else
  step "4/4 Release 构建（已跳过）"
fi

step "附加：文档数字"
if [ "$QUICK" -eq 1 ]; then
  ./Scripts/check-doc-numbers.sh --skip-build-log || FAIL=1
else
  ./Scripts/check-doc-numbers.sh || FAIL=1
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  echo "verify: OK"
else
  echo "verify: FAILED（见上方输出）"
fi
exit "$FAIL"
