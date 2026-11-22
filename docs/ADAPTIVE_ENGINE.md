# 自适应引擎：故障定位与修复（2026-11-14）

> 这份文档只记"哪一环断了、怎么修的、拿什么证明"。功能清单见 README。

## 一、故障点（逐项核对后的结论）

| # | 检查项 | 结论 |
|---|---|---|
| 1 | 监听真实应用激活/失活 | 有监听，但**判据错误**：`NSApplication.didBecomeActive` 被当成"用户回到 FLOW"。面板 `orderFront` 也会触发它，于是刚记下的失焦时间被清空 |
| 2 | 是否知道 FLOW 在前台 | 只有 `isAppActive` 布尔量，且初值写死 `true`、与实际前台无关 |
| 3 | 能否取外部前台窗口几何 | 能。`WindowGeometryReader` 走 AX，实测 `obstacles=[(0.0, ...)]` |
| 4 | 是否监听外部窗口移动/缩放 | 能。`AXWindowObserver`（`kAXWindowMoved/Resized/Created/FocusedWindowChanged`）→ `evaluateSpace` |
| 5 | 是否有真实空白区域算法 | 有。`FreeSpaceAnalyzer.maximalRects`，纯几何、有单测 |
| 6 | 是否按空白选形态 | 有，但**关键判据缺失**：只判"这个形态能不能在某处放下"，不判"我现在是不是被压住" |
| 7 | 是否真的移动/缩放窗口 | 能，`panel.setFrame`；实测 `RELOCATE (450,843) → (1496,600)` |
| 8 | 能否取消过时任务 | 能，`evaluationTask?.cancel()` |
| 9 | 是否记住用户展开/锁定 | 能（`isLocked` / `suppressAutoExpandUntil`） |
| 10 | 权限缺失降级 | 能，`obstacles()` 在 `ax != granted` 时返回空并记日志 |

### 三处根因

1. **伪激活抹掉失焦记录** → 状态机永远 `rejected=appStillActive`，自动收缩从不发生。
2. **冷启动恢复异步重建状态机** → `restorePreferences` 里的 `Task` 在 `syncFrontmostState()` 之后
   把 `deactivatedAt` / `lastUserInteraction` / `hasStartedPlayback` 一并清空（同样的症状，第二个来源）。
3. **"放得下"≠"位置没问题"** → 胶囊可以正好停在浏览器上面而引擎报 `noBetterOption`，
   所以"只会收缩、不会避让"。

## 二、修复

### 1. 前台判定改为边沿触发（`syncFrontmostState`）

- 所有通知（`didBecomeActive` / `didResignActive` / 工作区 `didActivate` / `didDeactivate`）
  只当**触发器**，不直接投事件；
- 由它自己读 `NSWorkspace.frontmostApplication` 判断"是不是我"，
  并且只在状态**真的变化**时才向状态机投 `.appActivated` / `.appDeactivated`；
- 冷启动先同步一次，避免"启动时前台状态没人记"。

### 2. 恢复不再清运行时状态

新增 `MorphologyStateMachine.adoptRestoredMorphology(_:)`：只落 `current/previous/phase/recommendation`，
运行时事实一概保留。

### 3. 引擎知道"我被压住了"

- `MorphologyEnvironment.currentOverlap`（0…1）；
- 超过 `relocationOverlapThreshold`（默认 0.18）时 `currentStillFits = false`，
  引擎优先"保持形态、要求移动"，其次才降级；
- 执行器 `relocateIfNeeded` 用同一套门槛，并要求遮挡至少改善
  `minimumRelocationImprovement`（默认 0.15）才动手——不满足就宁可不动。

### 4. 执行顺序符合规格 5.6

不移动 → 短距离移动 → 换形态 → 贴边 → 隐匿。
移动只改 frame，形态降级由引擎决定，两者不会互相打架。

## 三、验收记录（实机）

环境：macOS 26（1920×1080 主屏），障碍物为真实 TextEdit 窗口，用 System Events 设置几何。

| 测试 | 操作 | 结果 |
|---|---|---|
| 1 自动收缩 | 播放中切到 TextEdit | `MORPH-DONE expanded->compact`，`deact=true`，此后稳定 `rejected=noBetterOption`（无抖动） |
| 2 自动避让 | TextEdit 压住迷你条 | `note=被前台窗口遮挡 100%，需要移动` → `RELOCATE (450,843,420,80) → (1496,600,420,80) occlusion 100% → 0%`，窗口实际移动 |
| 2b 无法避让 | TextEdit 全屏覆盖 | `MORPH-DONE compact->dormant`（"所有悬浮形态都放不下"） |
| 3 自动恢复 | 缩小 TextEdit | `MORPH-DONE dormant->compact`，回到可用位置 |
| 4 原地展开 | 点击悬浮条 | `MORPH-DONE compact->expanded frame=(896,83,1020,640)`，3 秒后仍是完整形态（未回缩） |

单元测试：`MorphologyRelocationTests`（3 条）锁定"被压住必须要求移动 / 没被压住不许动 / 轻微遮挡不折腾"。
当时（2026-11-14）合计 338 条全绿；现行基线见 [上线清单](RELEASE_CHECKLIST.md)。

## 四、第二轮：防抖分档、序号、补偿检查、调试面板

### 4.1 防抖分两档（原来只有一档）

几何事件（前台窗口移动/缩放）以前也要等 `autoCollapseDelay`（700ms），
快速拖动时播放器明显滞后。现在：

| 触发 | 防抖 |
|---|---|
| 前台窗口移动/缩放、屏幕变化 | **100ms** 合并 |
| 形态决策 | 再额外经过状态机的 `autoCollapseDelay` + `interactionGrace` |

前者是"要不要重算"，后者是"允不允许换形态"，两件事不能混。

### 4.2 事件序号（规格 §三）

`spatialSeq` 每次请求 +1，评估任务带着自己的序号回来比对，过期结果直接丢：

```
EVAL dropped stale seq=12 current=13
```

### 4.3 补偿检查（规格 §二.2）

有的应用不投递 moved/resized。现在 ticker 每拍问一次 `compensatingCheck()`，
但只在三个条件同时满足时才真算一次，且自身限流 ≥500ms：

- 我不在前台；
- 当前是悬浮形态（完整形态不跑）；
- 已有 1 秒没收到任何 AX 几何事件。

不是全局轮询，也不需要辅助功能权限以外的任何权限。

### 4.4 调试面板（规格 §九）

`SLP_DEBUG_SPATIAL=1` 时右上角出现一块只读面板（`screenshots/flow/17-spatial-inspector.png`（截图已从公开仓库移除））：

```
FLOW · 空间决策
seq        15
前台       com.apple.TextEdit
我在前台    否
AX         granted
锁定/冷却   未锁 / 可切换
形态       expanded → compact
遮挡       87%
屏幕       0,79 1920×971
播放器     450,283 1020×640
前台窗口    1 个   0,320 1400×700
候选区     10 个   1400,79 520×971 …
空问不足，expanded → compact
```

面板 `ignoresMouseEvents = true`（不挡操作）、`.canJoinAllSpaces`、只有环境变量开启时才创建，
正式界面里不存在这些虚线框与数字。

### 4.5 补充验收

| 场景 | 结果 |
|---|---|
| 规则 G：暂停 | `STATE playing → paused(user)`，全程 **0 次** `MORPH-DONE …dormant`——暂停不会触发隐藏 |
| 规则 F：锁定 | 锁定后状态机 `rejected=locked`，自动决策不覆盖用户意图 |
| 快速拖动 | 序号丢弃 + 100ms 合并，日志出现 `EVAL dropped stale` |
| 规则 E：回到前台 | `FRONT -> appActivated` 后自动展开，且不会立刻被回缩（见第一轮测试 4） |

## 五、对齐参考形态（2026-11-14）

参考图给的完整生命周期是：**完整播放器 → 自主收缩 → 贴边生存 → 自动隐匿（边缘入口）**。
逐项核对后改了两处：

### 5.1 隐匿把手从"一颗圆点"改成"贴边竖条"

参考图的入口是一条**竖着的圆角条 + 三点**，不是圆点。竖条更容易点中，
贴左右边缘时也不抢视觉重心。几何从 26×26 改成 26×72（min 20×52，max 40×120），
位置解析强制落到**左右边**——靠近顶边时也不会变成一根横着的短棍。

`screenshots/flow/18-dormant-handle.png`（截图已从公开仓库移除）：右侧边缘的浅色圆角竖条 + 三点，
播放时中间一点更亮（静态相位，不做无限动画）。

底色用确定值（`white 0.93` / `white 0.20`）而不是薄材质：贴在彩色壁纸上时材质会被吃掉，
变成一坨发灰的脏块——实机看过才改的。

### 5.2 生命周期顺序与参考一致

| 参考 | 实现 | 触发 |
|---|---|---|
| 01 完整播放器 | `expanded` 1020×640 | 用户激活 / 点击悬浮体 |
| 02 自主收缩 | `compact` 420×80（找空位，不贴固定角） | 切走后失焦 + 空间评估 |
| 03 贴边生存 | `edge` 300×34（贴最近边，留 4pt 缝） | 空间进一步压缩 |
| 04 自动隐匿 | `dormant` 竖条把手 / 完全隐藏 | 没有任何合法位置 / 全屏 / 用户隐藏 |

降级与升级都沿 `tightnessOrder` 走，不跳级；升级永远不会自动跳回 `expanded`。

## 六、第三轮：移动的视觉连续性、遮挡并集、重定位去重

### 6.1 移动也要走过渡计划（规格 5.6）

之前移动是固定 360ms 平移动画：从屏幕这头滑到那头，等于让窗口横穿工作区——规格明确禁止。
现在 `moveWithContinuity` 复用 `MorphTransitionPlan`：

- 近（< 32% 屏幕对角线）：连续平移；
- 远：**淡出 160ms → 改 frame → 淡入**，日志 `MORPH-DONE … 远距离重定位（57% 屏幕对角线）：淡出迁移淡入`。

### 6.2 遮挡面积必须按并集算（真 bug）

`occlusion` 原来是"把每个障碍物的交集面积加起来"。同一应用的多个窗口/子面板会互相重叠，
加起来就重复计数：实测只压住 69%，算成 138% 再钳到 100% → 播放器以为一直没躲开，
**反复重定位**（规格 6.8 明令要防的"重复横跳"）。

新增 `Morphology/Coverage.swift`：先把裁到目标矩形内的片段求并，再算面积。
同一场景下日志从 `occlusion 100% -> 0%`（假的）变成 `75% -> 0%`（真的），重定位次数从反复跳变成一次。

`CoverageTests` 四条锁定：完全重合不翻倍、部分重叠取并集、界外算 0、全覆盖算 1。

### 6.3 重定位去重

动画期间 `panel.frame` 还没走到目标，下一拍会算出同样的移动。
现在 800ms 内对同一目标只执行一次（`RELOCATE deduped`），避免日志刷两条、动画被反复重启。

## 七、仍未实现 / 受系统限制

- **全屏检测**：`detectFullscreen()` 依赖 `AXFullScreen` 属性，实测多次读回 `false`（部分应用不暴露）。
  现在按"读不到就当不是全屏"保守处理，会漏判。
- **多显示器**：只有单屏实机环境，跨屏坐标转换未实测。
- **悬挂观察者清理**：应用切换时 `AXWindowObserver.start` 会先 `stop`，但被观察应用退出时
  没有额外清理路径（依赖 `AXObserverCreate` 失败分支）。
- **调试面板（规格 §9）**：目前只有 `SLP_SPATIAL_DEBUG=1` 的日志
  （`FRONT` / `MORPH` / `RELOCATE` / `OBSTACLE`），没有可视化候选项矩形。
