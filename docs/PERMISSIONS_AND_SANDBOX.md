# 权限与沙盒说明

对应规格「第二十四部分 · 交付物 #14」。以下 entitlement 内容取自仓库中实际文件
`Config/App.entitlements` 与 `Config/Widget.entitlements`。

## 1. Entitlements（实测内容）

### App（`Config/App.entitlements`）

```xml
<key>com.apple.security.app-sandbox</key>            <!-- 沙盒开启 -->
<key>com.apple.security.network.client</key>          <!-- 允许出站网络连接 -->
<key>com.apple.security.network.server</key>          <!-- HLS 受控代理，仅绑定 127.0.0.1 -->
<key>com.apple.security.files.user-selected.read-write</key>
<key>com.apple.security.files.downloads.read-only</key>   <!-- 读取 ~/Downloads/FLOW-VoicePacks 里转换好的音色包 -->
<key>com.apple.security.application-groups</key>
    <string>group.com.yg.spatiallyrics</string>
```

### Widget（`Config/Widget.entitlements`）

```xml
<key>com.apple.security.app-sandbox</key>
<key>com.apple.security.application-groups</key>
    <string>group.com.yg.spatiallyrics</string>
```

> **注意**：主应用声明 `network.client = true` 与 `network.server = true`。后者用于 HLS 受控代理，`NWListener` 显式只绑定 `127.0.0.1`，并非局域网共享服务。AVFoundation 只访问该回环入口，上游列表/分片/密钥请求检查联网开关、域白名单与跨源请求头；代理随会话销毁。正式 App Sandbox 签名环境仍待验证。未声明屏幕录制、Apple Events 或临时例外。

## 2. 三类权限的实际获取方式

### 2.1 文件访问（本地音频导入）

- 通过 `NSOpenPanel` 由用户主动选择，沙盒自动授予该文件访问权。
- 为跨启动保留访问权，使用 **security-scoped bookmark**：
  存书签数据而非路径，下次启动 `resolveBookmarkData` 后 `startAccessingSecurityScopedResource()`。
- entitlement 为 `files.user-selected.read-write`，权限范围仅限用户选中的文件，不是整个磁盘。
- `files.downloads.read-only`（2026-11-23 新增）：在线获取面板的「角色音色」卡片会检测并导入 `~/Downloads/FLOW-VoicePacks/<中文名>.voicepack`（离线转换工具的默认输出目录）。只读、只用于这一个目录；路径按真实用户主目录计算（沙盒里 `homeDirectoryForCurrentUser` 指向容器）。签名沙盒包里的实际读取仍待验证。

### 2.2 辅助功能（前台窗口几何）

- 状态检测：`AXIsProcessTrusted()`，映射为 `Unknown` / `NotGranted` / `Granted` / `Unavailable`。
- 引导：`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` 打开系统设置面板，
  且**只引导一次**，不无限弹窗；之后设置页「去授权」直接打开「隐私与安全性 → 辅助功能」。权限页停留期间每 2 秒复查一次，授权后无需重进页面。
- 读取范围：仅窗口的 `AXPosition` / `AXSize` / 标题等几何与标识信息。
  **不读取**文档内容、输入内容、选中文本。
- 部分应用拒绝 AX 查询时按 `Unavailable` 处理，不影响其他应用的避让。

**未授权时的降级**（规格 7.3 要求）：

| 能力 | 未授权时 |
|---|---|
| 悬浮歌词显示 | 保留 |
| 屏幕安全区约束（菜单栏/Dock/刘海） | 保留 |
| 多屏位置记忆 | 保留 |
| 手动定位 | 保留 |
| 基于前台窗口的智能避让 | **禁用** |
| 设置页能力说明 | 明确显示当前状态 |

### 2.3 全局快捷键

使用 Carbon `RegisterEventHotKey`（公开 API），**不需要**辅助功能权限。
沙盒下可用；冲突检测只能覆盖应用自身占用的组合键，无法枚举其他应用的注册——这是公开 API 的固有边界。

## 3. 明确不使用的能力

| 能力 | 状态 | 说明 |
|---|---|---|
| 屏幕录制 | 不申请 | 空闲矩形完全由 AX 几何 + `NSScreen` 计算，不做像素分析 |
| 网络 | 生产代码已接入；主应用已声明出站网络 entitlement | 主应用不内置任何第三方商业曲库（原 B 站实现已抽离为未随包分发的 B 站外部插件（开源前已移出仓库、不再分发））；联网仅用于：用户配置的 OpenSubsonic/WebDAV；受 `JavaScriptCore` 沙盒与 `allowedDomains` 白名单限制的用户导入 JS/JSON 音源；AMLL / LRCLIB 歌词与封面；设置页「自动获取」的 GitHub 搜源（`api.github.com`，失败回退 `cdn.jsdelivr.net`）；FLOW Voice 的模型检索与下载（检索走 `huggingface.co` / `api.github.com`，文件下载默认走 `hf-mirror.com` 并回退官方源）。以上全部受设置页「允许联网」开关门控（正式版默认开启，关掉后进行中的音色下载会被取消）；凭据均存入 Keychain（`KeychainSecretStore`）；`Config/App.entitlements` 已声明 `com.apple.security.network.client = true`，签名分发环境仍待验证 |
| 键盘输入监听 | 不使用 | 无 keylogger、无 event tap |
| 私有 API | 不使用 | 窗口层级用公开 `NSWindow.Level.floating`，未使用系统保护层级 |

## 4. 沙盒带来的实际限制

1. **App Group 需要签名。** 未签名时 `containerURL(forSecurityApplicationGroupIdentifier:)`
   返回 nil，`SharedStateStore` 回退到 `UserDefaults.standard`。
   后果：小组件与主应用读不到同一份快照——这是本机无法验证小组件的根本原因，
   不是代码逻辑错误。
2. **XCUITest runner 需要签名。** 0 个签名身份时 runner 被系统 kill，
   UI 测试无法建立连接。
3. **存储位置**受沙盒重定向到容器内
   `~/Library/Containers/.../Data/Library/Application Support/SpatialLyricsPlayer/`。

## 5. 分发形态差异（未完成项）

规格要求区分「本地调试 / 签名 / 公证 / App Store 提交」，并说明
「App Store 版与独立签名公证版的功能差异」。

**该差异文档尚未撰写。** 已确认的事实：

- App Group + 沙盒 + AX 权限三者都可在 App Store 规则下工作（均为公开能力）。
- 无法验证的是：App Store 审核对「读取其他应用窗口几何」的实际尺度，
  以及未签名环境下小组件的真实行为。
- 没有付费开发者账号，因此签名 / 公证 / TestFlight 全部未执行。

不得据本文推断任何一项已通过审核。

## 6. 相关文档

- 多音源与插件沙箱规范：[SOURCE_SPEC.md](SOURCE_SPEC.md)
- 架构与分层：[ARCHITECTURE.md](ARCHITECTURE.md)
- 测试执行记录：[TEST_REPORT.md](archive/TEST_REPORT.md)
- 完整缺口：[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
