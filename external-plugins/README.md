# FLOW 外部音源插件目录（不随主应用打包）

此目录放置与主工程完全解耦、由用户自行按需导入的独立 `.js` / `.json` 音源脚本或 API 模板。

## 导入方式

1. 打开 FLOW → **设置 → 在线音乐**；
2. 在 **自动获取与扩展预设** 中开启 Audius / Radio Browser / Internet Archive 等开放接口预设（默认均未启用），或在 **GitHub 自动搜源** 中检索获取，或点击 **选择文件导入** 手动选择本目录下的 `.js` 插件 / `.json` 模板 / `presets.json` 清单；
3. 主应用会在隔离的 `JavaScriptCore` 上下文中加载插件，敏感会话凭据仅存入系统钥匙串（Keychain）。网络请求按插件声明的 `allowedDomains` 校验，**每一跳重定向在跟随前也会重新校验**；但 `allowedDomains` 为空或含 `"*"` 时表示允许任意 http/https 域（见 [`SOURCE_SPEC.md`](../docs/SOURCE_SPEC.md)），请只导入可信来源的插件。

> **已知限制**：插件脚本在应用进程内同步执行，系统 SDK 未提供可中断 JavaScript 执行的公开接口。顶层或回调里写了死循环的插件会卡住导入与启动恢复，调用超时也无法打断已经在跑的脚本。

## 目录内容

- [`docs/SOURCE_SPEC.md`](../docs/SOURCE_SPEC.md)：FLOW 多音源与多配置兼容标准（`flow-js-v1` / MusicFree / LX / `flow-source-v1` / `flow-server-v1`）
- `presets.json`：外部多 API 预设订阅清单（Audius / Radio Browser / Internet Archive 开放示例模板）
- `examples/audius.flow.json`：Audius 开放音乐接口声明式 JSON 模板
- `examples/radiobrowser.flow.json`：Radio Browser 公开电台目录声明式 JSON 模板
- `examples/internetarchive.flow.json`：Internet Archive 公共音频典藏声明式 JSON 模板

> FLOW 不收录、不分发抓取商业音乐 / 视频平台的脚本。第三方插件由用户自行导入并自行承担使用责任。
