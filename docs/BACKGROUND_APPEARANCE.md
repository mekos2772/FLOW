# 背景驱动深浅外观 · 2026-11-15

## 使用

设置 → 外观 → 悬浮层 → **悬浮深浅外观**：

- **跟随背景**（默认）：播放器所在区域的浅壁纸 → 浅底深字；深壁纸 → 深底浅字。
- 跟随系统：交还系统深浅外观。
- 始终浅色 / 始终深色：固定悬浮播放器外观。

作用于迷你、胶囊、贴边与把手。完整播放器、设置窗和菜单继续跟随系统，不被局部墙纸颜色带着跳。设置进 UserDefaults，并纳入设置备份；没有该字段的旧 v1 备份保持兼容。

## 实现

1. 主线程从 `NSWorkspace` 取得窗口所在屏幕的壁纸 URL、缩放方式、裁剪选项和填充色。
2. `WallpaperLuminanceSampler` actor 后台缩略解码，最长边 512px。按 fill/fit/stretch/center 计算真实铺放矩形，采样窗口覆盖区域到 24×16 后求 Rec.709 加权亮度。支持负坐标与非零原点的副屏。
3. 最多缓存 3 张缩略图，文件修改时间变化就重新解码。专项测试发现 `URL.resourceValues` 会缓存旧属性，已改成每次读取文件 stat，覆盖同一路径更换壁纸的情形。
4. 首次有效采样以 0.56 分界即时定色；暗→亮需 ≥0.64，亮→暗需 ≤0.44，反转持续 **280ms** 才应用。灰色区域不会在单一阈值附近反复翻转。
5. 复用现有 tick，不增加独立常驻轮询器。背景检查至少间隔 350ms，暂停时受 400ms tick 限制；静止时每 2 秒复采，捕捉壁纸 URL/文件变化。形态完成、自动迁移完成、移动与 Space 变化均触发更新。
6. 后台结果核对世代和窗口 frame，旧采样不会覆盖新位置。该链路独立于避让开关和位置/形态锁。
7. 用本面板 `NSAppearance` 和 SwiftUI 根部 colorScheme 共同落地，不改 `NSApp.appearance`。系统“减少透明度”优先使用不透明底板。

## 真实覆盖范围

- 数据来自壁纸文件，不是屏幕截图，不读取其他应用窗口内容。
- 压在普通窗口上时，回到系统外观并加可读性底板，不把壁纸误当成该窗口颜色。
- URL 不可得、文件不可读、动态/多帧图像等情况同样回退；未实现对视频壁纸当前帧或外部窗口像素的实时采样。
- 启动后已确认最新构建运行；当前桌面被其他窗口占满，播放器恢复为边缘把手，因此本轮没有实机明暗壁纸拖动对照证据，也未更改用户壁纸或窗口布局。

## 验证

2026-11-15 当时全量运行 **563 条测试，13 条跳过，0 失败**（现行基线见 [上线清单](RELEASE_CHECKLIST.md)）；Debug 构建、架构检查和差异检查通过。13 条跳过为 12 条联网/环境测试和 1 条受当前桌面几何约束的旧形态尺寸测试。

新增 **18 条**，覆盖：初始明暗、滞回、280ms 稳定、候选撤销、无效采样、左右/上下局部采样、副屏原点、fill 裁剪、fit 留边填充、center、屏外区域、默认与固定模式、UserDefaults 重载、旧备份兼容、文件替换缓存失效、面板恢复系统及实际视图渲染。

[浅色呈现](<screenshots/background-appearance/background-light.png>) · [深色呈现](<screenshots/background-appearance/background-dark.png>)

两图来自实际 `MorphRootView` 的 SwiftUI `ImageRenderer`，并故意传入相反的系统 colorScheme，验证局部色调确实覆盖系统色调；是控件渲染，不是桌面截图。

## 复现

```bash
TEST_RUNNER_SLP_TEST_RENDER_DIR=/tmp/flow-background-render \
  xcodebuild test -workspace SpatialLyricsPlayer.xcworkspace \
  -scheme SpatialLyricsPlayer -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/slp-dd \
  -only-testing:SpatialLyricsPlayerTests CODE_SIGNING_ALLOWED=NO
./Scripts/architecture-lint.sh
```

本轮由主代理独立完成，未创建 commit 或 push。
