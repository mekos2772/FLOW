#!/bin/bash
# 分层越界扫描。
#
# 单 App Target 无法用模块系统强制"表现层不引用具体源"，
# 因此在测试与 CI 里跑同一个 grep 作为兜底。
# 退出码非 0 即视为架构违规。

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS=0

check() {
    local dir="$1"; shift
    local pattern="$1"; shift
    local label="$1"; shift
    # 目录不存在**不能**当作通过：
    # 那样把 `UI/` 改名成 `ui/` 就能让这条规则永久静默失效，
    # 而脚本依旧打印 OK —— 和 verify.sh 那个假绿是同一类问题。
    if [ ! -d "$ROOT/$dir" ]; then
        echo "[FAIL] $label —— 被检查的目录不存在：$dir"
        STATUS=1
        return 0
    fi
    # 先剔除整行注释：这些规则管的是"代码依赖"，注释里提到某个类型是正常文档。
    # （第 111 节就是因为一条解释性注释被误判成架构违规。）
    local hits
    hits=$(grep -rnE "$pattern" "$ROOT/$dir" --include='*.swift' \
        --exclude-dir=Vendor --exclude-dir=Tools --exclude-dir=.build \
        | grep -vE ':[0-9]+: *//' \
        | grep -vE ':[0-9]+: */\*' || true)
    if [ -n "$hits" ]; then
        echo "[FAIL] $label"
        echo "$hits"
        STATUS=1
    fi
}

# 表现层与系统层不得知道任何具体源实现或播放器
check "UI"      'MockPlaybackSource|MockPlaybackSession|AVPlayer|AVAudioPlayer|URLSession' "UI/ 引用了具体源或播放器"
check "Overlay" 'MockPlaybackSource|MockPlaybackSession|AVPlayer|URLSession'                "Overlay/ 引用了具体源或播放器"
check "MenuBar" 'MockPlaybackSource|MockPlaybackSession|AVPlayer|URLSession'                "MenuBar/ 引用了具体源或播放器"

# 菜单栏只能依赖共享的格式化/领域类型，不能认识"完整播放器"的具体视图
# （本轮就是 `MenuBarView` 借了 `ExpandedPlayerView.format` 来格式化时长）。
check "MenuBar" 'ExpandedPlayerView|CompactBarView|LyricScrollView' \
      "MenuBar/ 引用了具体播放器视图"

# 播放内核不得直接依赖 Mock 类型，也不得自己抓播放器/网络
# （与 SourceSubstitutionTests 的禁用清单保持一致，避免两处规则漂移）
check "Playback" 'MockPlaybackSource|MockPlaybackSession|MockCatalog|AVPlayer|URLSession' \
      "Playback/ 直接依赖了具体实现或播放器"

# `Shared/` 同时进入 App 与小组件两个 target：只能依赖 Foundation / WidgetKit / AppIntents，
# 不能依赖 AppKit（小组件进程没有 NSApplication）或 App 内部类型。
check "Shared" 'import AppKit|import SwiftUI|NSApplication|NSWindow' \
      "Shared/ 依赖了只在 App 里存在的框架（小组件会编译失败）"

# 原生 C/ObjC 回调显式 hop 到 actor，避免 macOS 执行器检查路径崩溃。
check "Morph"       'MainActor\.assumeIsolated' "窗口回调假设了主 actor 执行器"
check "Spatial"     'MainActor\.assumeIsolated' "AX 回调假设了主 actor 执行器"
check "Integration" 'MainActor\.assumeIsolated' "系统回调假设了主 actor 执行器"

# 全局禁止裸 DispatchQueue（Phase 1 的 CoreAudio 桥接会显式豁免并注释）
check "." 'DispatchQueue\.main\.async' "出现裸 DispatchQueue"

# 给系统框架的异步回调闭包不得捕获主线程隔离对象。
#
# MediaPlayer 在它自己的 accessQueue 上调用封面 request handler，闭包一旦被推断成
# MainActor 隔离，系统回调时执行器断言直接 SIGTRAP
# （崩溃报告 SpatialLyricsPlayer-2026-11-15-062145）。唯一允许的写法是
# NowPlayingArtwork.make(...)：显式 @Sendable、只捕获 Data/CGSize。
# 注释行与那一处显式 @Sendable 的构造要放过，否则红线会被文档本身点燃。
artwork_hits=$(
    grep -rn 'MPMediaItemArtwork(' "$ROOT/Playback" --include='*.swift' 2>/dev/null \
    | grep -v ':[0-9]*:[[:space:]]*///' \
    | grep -v ':[0-9]*:[[:space:]]*//' \
    | grep -v '@Sendable' || true
)
if [ -n "$artwork_hits" ]; then
    echo "[FAIL] MPMediaItemArtwork 只能用显式 @Sendable 的闭包构造（见 NowPlayingArtwork）"
    echo "$artwork_hits"
    STATUS=1
fi

if [ $STATUS -eq 0 ]; then
    echo "architecture-lint: OK"
fi
exit $STATUS
