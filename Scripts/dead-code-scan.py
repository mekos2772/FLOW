#!/usr/bin/env python3
"""机械扫描零引用的类型声明。

为什么需要：人肉找"看起来没用的类型"误判率很高——本工程实测误判过三次
（把测试替身当成"没实现的功能"、把 `@main` 入口当成死代码）。
这里只做一件机械的事：统计每个类型名在全工程（含测试）的出现次数，
把"只有声明、别处一次都没出现"的挑出来给人复核。

用法：
    python3 Scripts/dead-code-scan.py

约定：
- `@main` 入口不会被按名字引用 → 自动忽略；
- `AppIntent` / `Widget` 由系统按元数据发现 → 自动忽略；
- 输出为空表示没有可疑项。
"""

from __future__ import annotations

import pathlib
import re
import sys

PRODUCTION_ROOTS = [
    "Sources", "Core", "Lyrics", "Playback", "Morph", "Morphology",
    "UI", "Integration", "App", "MenuBar", "Spatial", "Overlay",
    "DesignSystem", "System", "DI", "Persistence", "Shared", "Voice",
]

# 由系统/框架按元数据发现，不靠名字引用。
ALLOWED_SUFFIXES = ("Intent", "Widget", "WidgetBundle")
ALLOWED_NAMES = {"SpatialLyricsPlayerApp"}

# 属性修饰（@MainActor @Observable @available(...)）可能多个、可能带参数，
# 用 `@[\w]+(?:\([^)]*\))?\s*` 逐个吃掉；只认一个 @xxx 会漏扫
# `@MainActor @Observable final class …` 这类真实声明。
# 修饰词表也要宽：`nonisolated`/`open`/`package`/`static`/`indirect` 这些
# 进不了 `(?:final|public…)*` 的话声明直接被跳过，漏扫不留痕迹。
DECL = re.compile(
    r"^(?:@[\w]+(?:\([^)]*\))?\s+)*(?:\w+\s+)*?"
    r"(?:class|struct|enum|protocol|actor) (\w+)",
    re.M,
)


def swift_files(root: pathlib.Path) -> list[pathlib.Path]:
    return list(root.rglob("*.swift")) if root.exists() else []


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent

    # 目录缺失**不能**静默跳过：改个名字就能让整层扫描失效，而脚本照样打印 OK。
    # （与 architecture-lint.sh 里同类漏洞一并修掉，见第 156 节。）
    missing = [r for r in PRODUCTION_ROOTS if not (repo / r).exists()]
    if missing:
        print("dead-code-scan: 以下被扫描的目录不存在 —— " + ", ".join(missing))
        return 1
    production = [f for r in PRODUCTION_ROOTS for f in swift_files(repo / r)]
    tests = swift_files(repo / "Tests") + swift_files(repo / "UITests")
    sources = {f: f.read_text(errors="ignore") for f in production + tests}

    candidates: list[tuple[str, str]] = []
    for path in production:
        text = sources[path]
        for match in DECL.finditer(text):
            name = match.group(1)
            if name in ALLOWED_NAMES or name.endswith(ALLOWED_SUFFIXES):
                continue
            uses = sum(len(re.findall(r"\b" + re.escape(name) + r"\b", body))
                       for body in sources.values())
            if uses <= 1:  # 只有声明本身
                candidates.append((name, str(path.relative_to(repo))))

    if not candidates:
        print("dead-code-scan: OK（没有零引用的类型）")
        return 0

    print(f"dead-code-scan: {len(candidates)} 个可疑类型（需人工复核）")
    for name, path in sorted(candidates, key=lambda item: item[1]):
        print(f"  {name:38s} {path}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
