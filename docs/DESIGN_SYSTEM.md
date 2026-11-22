# 视觉与动效重构（令牌与单窗口形态体系已落地）

> 目标：把"能用的界面"改成"像为 Mac 专门设计的音乐应用"。
> 注：第 1–5 节记录第一轮重构后的阶段现状；当时"尚未完成"的悬浮四形态、单窗口连续变形与主界面排版已由下方「形态重构轮新增令牌」及 [UI_REFRESH_2026-11-19.md](archive/UI_REFRESH_2026-11-19.md) 落地，以下原文保留作演进参照。

## 1. 设计令牌（已落地）

`DesignSystem/Tokens.swift`

| 类别 | 内容 |
|---|---|
| `Spacing` | 4 / 8 / 12 / 16 / 24 / 32 / 48 |
| `Radius` | control 8 · card 12 · container 16 · board 20 |
| `Surface` | background `regularMaterial` / chrome `bar` / overlay `thickMaterial` |
| `Motion` | micro .14 · control .22 · lyric .34 · morph .42 · artwork .55 · ambient .78 |
| `TypeScale` | playerTitle 26 semibold / artist 15 / section 13 semibold / body 13 / caption 11 / timecode 11 monospacedDigit |

曲线按场景分两类：`Motion.move`（位移，轻减速，落点确定不弹跳）、`Motion.fade`（透明度，easeOut）。
所有动画经 `Motion.respectingReduceMotion` 过滤"减少动态效果"。

**修正记录**：SwiftUI 的 `Material` 只有 5 档 + `.bar`，没有 AppKit 的 `.underWindowBackground` / `.popover`，
第一版写错导致编译失败，已改为 `regularMaterial` / `thickMaterial`。

## 2. 封面取色（已落地 + 4 条测试）

`DesignSystem/ArtworkPalette.swift`：封面缩到 1×1 读面积平均色（比逐像素遍历便宜），
再用 HSB 降饱和到 0.35、亮度夹到 0.62，保证压在其上的文字可读。没有封面返回 nil，调用方回退系统强调色。

## 3. 主窗口（第一轮已改）

`UI/MainWindow/NowPlayingPane.swift` + `TransportBar.swift`

- 封面 210pt 作为第一视觉锚点，投影克制（radius 22 / y 10 / 黑 22%）
- 标题 26pt semibold，艺术家次级，专辑三级——层级靠排版，不用卡片和边框
- 歌词行**统一字号**，只改字重与亮度（0.72 次級色），避免行长变化导致整列抖动
- 底部材质只出现一条 1pt 分隔线，控制区不再叠卡片
- 新增 `DesignSystem/HairlineSlider.swift`：轨道 3pt、静止不显示滑块、可点击区域仍是 20pt 高，
  支持 VoiceOver 可调节动作

## 4. 尚未完成（不要当成已完成）

- 悬浮歌词四种形态**完全没动**，仍是旧实现
- 迷你播放器、菜单栏面板、队列、设置、小组件未改造
- 歌词切换仍是 `scrollTo` + 单条动画，未实现"连续位移"效果
- 形态变形（窗口尺寸连续变化）未实现
- 空态构图仍有大留白：截图里「暂无歌词」与封面之间空隙过大
- 侧栏选中项仍是系统蓝色大色块，视觉偏重
- 工具栏导入按钮是系统默认大圆，偏重

## 5. 视觉验证现状

已用真实截图验证主窗口（`docs/screenshots/main-window-redesign.png`），
并据此发现上述留白与色块问题。**其他页面尚未截图验证**。

---

## 形态重构轮新增令牌（本节为重写后的实际取值）

### 排版（`FlowType`）

| 令牌 | 字号 / 字重 / 字距 | 用途 |
|---|---|---|
| `wordmark` | 10.5 / semibold / +3.0 | 顶栏「FLOW」 |
| `eyebrow` | 10 / semibold / +1.7 | 分区小标签（全大写） |
| `trackTitle` | 32 / semibold / −0.7 | 完整形态曲名 |
| `trackTitleCompact` | 20 / semibold / −0.3 | 迷你条 / 抽屉标题 |
| `artist` | 13 / medium / +0.3 | 艺术家 |
| `caption` | 11 / regular / +0.2 | 辅助信息 |
| `timecode` | 11 / medium / +0.4，等宽数字 | 进度时间 |
| `lyricCurrent(size)` | size / semibold / −0.4，行距 = max(4, size×0.22) | 当前歌词（默认 34pt） |
| `lyricNeighbor(size)` | size / regular / 0，行距 = max(2, size×0.18) | 前后行（默认 15pt） |

规则：**大字号收紧字距、小号标签放开字距**。这一条比字号本身更能拉开与系统默认界面的距离。

### 颜色（`FlowColor`）

| 令牌 | 值 | 用途 |
|---|---|---|
| `hairline` | `primary @0.08` | 分隔线（比系统 separator 更淡） |
| `secondaryText` / `tertiaryText` | `primary @0.55` / `@0.38` | 次级 / 三级文字 |
| `hover` / `pressed` | `primary @0.06` / `@0.11` | 悬停 / 按下 |
| `track` | `primary @0.12` | 进度轨道 |
| `ambientWash` | 封面色 @0.26（深）/ @0.15（浅） | 封面背后的一团光 |
| `emphasis` | 封面色（缺失时系统强调色） | 进度填充、当前行标记 |
| `windowBase` | `windowBackgroundColor` 不透明 | 完整形态窗口底 |

封面色流程：面积平均（缩到 1×1 采样）→ 降饱和到 **0.28** → 压亮度到 **0.55**。
禁大面积高饱和、彩虹渐变、霓虹。

### 材质（`Surface`）

| 令牌 | 值 | 用在哪 |
|---|---|---|
| `windowBase(scheme)` | 不透明系统窗口底色 | 完整形态 |
| `translucent` | `.ultraThinMaterial` | 迷你条 / 胶囊 / 双行 |
| `sheer` | `.thinMaterial` | 贴边 / 隐匿把手 |
| `background` / `chrome` / `overlay` | `.regularMaterial` / `.bar` / `.thickMaterial` | 设置页、菜单、浮层 |

同一区域最多一层材质。**完整形态不要用材质做底**（无边框窗口会把桌面透上来）。

### 动效（`Motion`）

| 令牌 | 时长 | 曲线 |
|---|---|---|
| `micro` | 140ms | `fade`（easeOut） |
| `control` | 220ms | `move` |
| `lyric` | 340ms | `fade` |
| `morph` | 360ms | `move(0.22,0.61,0.24,1)` |
| `collapse` | 400ms | 同上（窗口层用同一组控制点） |
| `expand` | 560ms | 同上 |
| `dormant` | 260ms | 同上 |
| `artwork` | 550ms | `fade` |
| `ambient` | 780ms | `fade` |
| `handoff` | 260ms | `fade`（内容跨形态交接） |

`Motion.respectingReduceMotion(_:reduceMotion:)` 是所有动画的唯一出口。
减少动态效果开启时：时长归零、不做几何插值、只留极短淡入淡出。

### 形状

`Radius.control 8 / card 12 / container 16 / board 20 / window 22 / artwork 18 / capsule 28`。
悬浮形态的圆角**随高度连续收敛**：`min(base, height/2)`，所以"矩形变胶囊"是插值出来的，
不需要单独一条圆角动画（`MorphCorner.radius(for:height:)`）。

### 组件（`DesignSystem/FlowComponents.swift`）

`SectionLabel`、`FlowCaption`、`FlowIconButton`、`FlowPlayButton`、`FlowTextButton`、
`ArtworkSlab`、`HairlineProgress`、`FlowDivider`、`DrawerSurface`、`FlowRow`、`InteractiveHighlight`。

### 分段切换与播放页背景（2026-11-21）

- **`FlowSegmentedSwitch`**（`DesignSystem/FlowSegmentedSwitch.swift`）：胶囊形分段控件，选中段垫一块底色，切换时用 `matchedGeometryEffect` 滑过去，动画走 `Motion.respectingReduceMotion`。两种外观：`standard` 跟随黑白版面（轨道 `FlowColor.hover`、选中 `primary` 12%），`glass` 给沉浸页这种动态画面用（轨道黑 30%、选中白 22%、白字）。右上角「普通 / 悬浮 / 沉浸」用的就是它。
- **播放页背景**（`UI/Expanded/PlayerBackdropView.swift`）：纯色仍是 `Surface.windowBase`；封面取色是调色板的静态渐变再压 28% 黑；场景背景复用沉浸渲染器，上面压一层从上到下 62% → 46% 的黑色保证文字可读。选了非纯色背景时整页切成深色外观。
- 沉浸页的颜色不走令牌，而是从封面取五个角色色，规则见 [IMMERSIVE_MODE.md](IMMERSIVE_MODE.md) 第四节。
