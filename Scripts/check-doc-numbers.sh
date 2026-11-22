#!/bin/bash
# 核对文档里写死的数字是否与现状一致。
#
# 为什么需要：审查报告和上线清单里全是 "988 条 / 0 警告 / 8 张图" 这类数字，
# 代码改过之后它们会开始骗人——**过期的文档比没有文档更糟**。
# 这里只查最易腐烂、且能稳定取到的两项。

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0
# `--skip-build-log`：调用方明确声明"这次没构建"（例如 verify.sh --quick）。
# 不传这个参数却又没有日志 → 视为**无法核对**，判失败。
# 不能因为"没数据"就报 OK——那正是本轮要消灭的一类假绿。
SKIP_BUILD_LOG=0
[ "${1:-}" = "--skip-build-log" ] && SKIP_BUILD_LOG=1

# 1) 证据图张数（文档声称 8 张）
REPORT=docs/AUDIT_REPORT.md
if [ ! -f "$REPORT" ]; then
  echo "！审查报告不见了：$REPORT"
  FAIL=1
else
  CLAIMED=$(grep -oE "证据图共 [0-9]+ 张" "$REPORT" | grep -oE "[0-9]+")
  ACTUAL=$(find docs/evidence -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
  echo "证据图：文档 ${CLAIMED:-?} 张，实际 $ACTUAL 张"
  # 解析不到 = 检查失效，不能当作通过（否则改一句文案就让它永久静默）
  if [ -z "${CLAIMED:-}" ]; then
    echo "！报告里找不到"证据图共 N 张"这句声明，无法核对"
    FAIL=1
  elif [ "$CLAIMED" != "$ACTUAL" ]; then
    echo "！张数不一致，请更新 $REPORT"
    FAIL=1
  fi
fi

# 2) 测试条数（从最近一次 verify 留下来的日志里取，格式稳定）
TESTLOG=/tmp/slp-verify-tests.log
if [ -f "$TESTLOG" ]; then
  ACTUAL_TESTS=$(grep -oE "Executed [0-9]+ tests" "$TESTLOG" | tail -1 | grep -oE "[0-9]+")
  CLAIMED_TESTS=$(grep -oE "\*\*[0-9]+ 条\*\*、[0-9]+ 跳过" docs/RELEASE_CHECKLIST.md | head -1 | sed -E "s/\*\*([0-9]+).*/\1/")
  echo "测试条数：清单 ${CLAIMED_TESTS:-?} 条，实际 ${ACTUAL_TESTS:-?} 条"
  if [ -n "${CLAIMED_TESTS:-}" ] && [ -n "${ACTUAL_TESTS:-}" ] && [ "$CLAIMED_TESTS" != "$ACTUAL_TESTS" ]; then
    echo "！清单里的测试条数过期，请更新 docs/RELEASE_CHECKLIST.md"
    FAIL=1
  fi
else
  echo "（还没有测试日志，先跑 ./Scripts/verify.sh）"
fi

# 3) 覆盖率测量文件（正文不再写死数字，但文件必须在且可解析）
COV=docs/evidence/coverage.txt
if [ -f "$COV" ]; then
  COV_PCT=$(grep -oE "行覆盖: [0-9.]+%" "$COV" | grep -oE "[0-9.]+")
  COV_ZERO=$(grep -oE "零覆盖文件: [0-9]+ /" "$COV" | grep -oE "[0-9]+")
  echo "覆盖率证据：${COV_PCT:-?}%（零覆盖 ${COV_ZERO:-?} 个）"
  if [ -z "${COV_PCT:-}" ] || [ -z "${COV_ZERO:-}" ]; then
    echo "！coverage.txt 格式不对，取不到覆盖率数字"
    FAIL=1
  fi
else
  echo "！缺少 docs/evidence/coverage.txt（文档正文现在指向它）"
  FAIL=1
fi

# 4) Release 警告数（文档声称 0）——基于上一次 verify.sh 留下的构建日志
LOG=/tmp/slp-verify-release.log
if [ -f "$LOG" ]; then
  WARN=$(grep -cE "\.swift:[0-9]+:[0-9]+: warning:" "$LOG")
  echo "Release 警告：$WARN 条（文档声称 0）"
  if [ "$WARN" -ne 0 ]; then
    echo "！存在编译警告，与文档不符"
    FAIL=1
  fi
elif [ "$SKIP_BUILD_LOG" -eq 1 ]; then
  echo "Release 警告：本次未构建，已按调用方声明跳过核对"
else
  echo "！没有构建日志，无法核对"0 警告"这条声明（先跑一次 ./Scripts/verify.sh）"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "check-doc-numbers: OK"
fi
exit "$FAIL"
