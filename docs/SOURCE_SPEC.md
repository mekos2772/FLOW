# FLOW 多音源与多配置兼容标准（`FLOW Source Spec v1`）

本文档定义 **FLOW（`SpatialLyricsPlayer`）** 的外部音源脚本、声明式 JSON 模板、订阅清单、预设服务器配置以及沙箱运行时的统一兼容规范。

设计目标：
1. **默认零预置曲库**：主应用本身不捆绑任何商业版权或侵权接口，所有扩展音源由用户按需显式导入或连接。
2. **多配置原生兼容**：同时兼容以下五大配置生态：
   - **FLOW JS 插件规范（`flow-js-v1`）**
   - **MusicFree 开源插件生态（`IPluginDefine` / TypeScript 编译产物 `__esModule`）**
   - **LX 自定义源扩展规范（`globalThis.lx` + JSDoc 元数据头）**
   - **FLOW 声明式 JSON API 模板（`flow-source-v1`，含直链模式、嵌套路径与回退表达式）**
   - **多格式订阅清单与标准自建服务器预设 JSON（`flow-server-v1` / `plugins.json` / 根数组）**

---

## 一、支持导入的配置格式矩阵

| 配置格式 | 识别依据 | 目标运行器 | 持久化位置 |
|---|---|---|---|
| JS 插件（`.js`） | `module.exports` / `exports.default` 或 `globalThis.lx` | `JSPluginSource`（`JavaScriptCore` 隔离沙箱） | `ImportedSources/*.js` |
| 声明式 JSON API（`.json`） | `schema: "flow-source-v1"` 或含 `search.url` | `JSONTemplateSource`（零脚本 HTTP + 点路径） | `ImportedSources/*.json` |
| 自建服务器预设 JSON | `schema: "flow-server-v1"` 或含 `kind: "opensubsonic" \| "webdav"` + `baseURL` | `OpenSubsonicSource` / `WebDAVSource` | `ServerSourceConfigStore` + `KeychainSecretStore` |
| 插件 / 模板订阅清单 | `{ "plugins": [...] }`、`{ "sources": [...] }`、`{ "feeds": [...] }` 或根数组 `[...]` | `ImportedSourceStore` 批量拉取并部分容错导入 | 逐条落盘到 `ImportedSources/` |

### URL 规范化规则（GitHub / 社区仓库直链兼容与自动搜索发现）
导入器 `SourceDomainPolicy.normalizeImportURL(_:)` 在下载前自动执行以下兼容转换：
1. GitHub 网页文件链接 `https://github.com/<owner>/<repo>/blob/<branch>/<path>` 自动改写为 `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`。
2. Gitee / GitCode 网页 `/blob/` 链接自动改写为 `/raw/` 直链。
3. 社区订阅中未编码的空格（如 `QQ Vip.js`）与非 ASCII 字符（如中文脚本名）自动进行安全百分号编码。
4. 读取脚本或 JSON 时自动剥离 UTF-8 BOM（`\u{FEFF}`）。
5. 设置页支持通过 `GitHubSourceDiscovery` 搜索公开 GitHub 仓库或直达 `owner/repo` / 仓库链接，自动扫描内部可导入的订阅清单、声明式 JSON 模板与 JS 插件，并支持订阅清单条目预览与单项/批量一键导入（配置可选 GitHub Token 存入 Keychain 后额外支持全网代码文件检索）。
6. 设置页「自动获取与扩展预设」与 GitHub 搜索弹窗同步展示外部扩展与开放 API 预设（Audius、Radio Browser、Internet Archive 等开放接口），默认均为未启用状态且不置于首页明面，勾选或点击「一键获取并启用」后按需从外置插件目录或 GitHub 远端（含 jsDelivr CDN 回退）自动获取并启用（主应用 Bundle 内仍零预置外部脚本与商业源）。

---

## 二、JS 插件标准与 MusicFree / LX 兼容规范

### 2.1 插件元数据导出字段

支持 **CommonJS 导出**（`module.exports = { ... }`）、**TypeScript 编译导出**（`exports.default` / `module.exports.default`）以及 **JSDoc 注释头兜底**（`@name`、`@version`、`@author`、`@description`、`@homepage`）：

```js
/**
 * @name Example Source
 * @version 1.0.0
 * @author FLOW
 * @description 兼容 MusicFree 与 FLOW 的标准音源插件
 */
module.exports = {
  id: "example-source",         // 可选，缺省按 platform / 文件名安全化派生
  platform: "Example Source",   // 显示名称（与 name 等价）
  version: "1.0.0",
  author: "Author",
  description: "Markdown 或纯文本说明",
  srcUrl: "https://example.com/plugin.js",
  allowedDomains: ["api.example.com", "*.cdn.example.com"], // 强烈建议声明；空或 ["*"] 表示允许任意 http/https 域
  supportedSearchType: ["music", "album", "sheet", "artist", "lyric"],
  supportedQualities: ["auto", "standard", "high", "hifi", "lossless", "hiRes"],
  userVariables: [
    { key: "url", name: "服务器地址", hint: "例如 https://music.example.com" },
    { key: "token", name: "访问令牌", type: "password" }
  ],
  hints: {
    importMusicSheet: ["粘贴公开歌单链接"]
  }
};
```

### 2.2 标准能力接口（按实现情况自动映射 `SourceCapabilities`）

| JS 导出方法 | FLOW 映射能力 | 参数与返回值约定 |
|---|---|---|
| `search(query, page, type)` | `supportsSearch` | 返回 `{ isEnd?: boolean, data: TrackRaw[] }` 或直接返回 `TrackRaw[]` |
| `getMediaSource(musicItem, quality)` | 必须（播放）或可与 `getLyric` 协同 | 返回 `{ url, headers?, userAgent?, codec?, bitrate?, sampleRate?, fileExtension?, isLossless?, quality? }` |
| `getLyric(musicItem)` | `supportsLyrics` | 返回 `{ rawLrc?, lrc?, translation?, translatedLrc?, lines?: [{ start, end?, text, translation? }] }` 或纯 LRC 字符串 |
| `discover(limit)` | `supportsDiscover` | 返回 `TrackRaw[]` 或 `{ data: TrackRaw[] }` |
| `getTopLists()` + `getTopListDetail(item, page)` | `supportsDiscover` | MusicFree 榜单标准格式；必要时回退到 `getRecommendSheetTags` / `getRecommendSheetsByTag` |
| `canHandleQuery(query)` + `resolveQuery(query)` | `URLResolvableSourceProvider` | 支持外部直链、ID、`importMusicSheet` / `importMusicItem` 解析 |
| `getMusicInfo(musicBase)` | `PlaybackSourceProvider.resolve` | 补全封面、专辑、歌手、时长与附加元数据 |
| `getRelated(musicItem, limit)` | `supportsRelatedRadio` | 返回关联推荐 `TrackRaw[]` |
| `auth`（含 `status` / `beginQRLogin` / `pollQRLogin` / `signOut` / `collections` / `collectionTracks`） | `supportsAccount` | 接入设置页扫码登录状态机与外部歌单/收藏导入 |

### 2.3 `TrackRaw` 字段宽容映射

| FLOW `Track` | 兼容的 JS 返回字段（按优先级） |
|---|---|
| `externalID` | `id` → `bvid` → `songmid` → `hash` |
| `title` | `title` → `name` |
| `artist` | `artist` → `singer` → `author` → `artists[].name` → `user.name` |
| `album` | `album` → `albumName` |
| `duration` | `duration`（支持数字秒、数字毫秒 `> 36000` 自动换算、`"mm:ss"` 或 `"hh:mm:ss"` 字符串） |
| `artwork` | `artwork` → `pic` → `cover` → `artworkUrl` → `coverImgUrl` |
| `_meta` 与插件扩展标识字段（`bvid`、`aid`、`cid`、`songmid`、`hash` 等） | 轻量化持久化进 `Track.persistentIdentifier`（兼容旧库无 `persistentIdentifier` 的 BV/AID 兜底提取），重启或原曲↔AI 切换再取流时无损传回插件 |

### 2.4 `quality` 档位双向兼容

- `AudioQualityTier` 枚举值：`auto` / `standard` / `high` / `hifi` / `lossless` / `hiRes`。
- 若插件未显式声明 `supportedQualities`，FLOW 在调用 `getMediaSource(item, quality)` 时会将高精度档位映射为标准 MusicFree `IQualityKey`（`auto/high`→`high`，`hifi/lossless/hiRes`→`super`，`standard`→`standard`），避免社区插件因键名严格比较返回空值。

### 2.5 沙箱全局对象与 `require(...)` 白名单

为保障安全，插件运行在独立 `JavaScriptCore` 上下文中，无文件系统、Shell 或原生 Node API 访问权限。宿主注入以下标准模块（全部提供 `.default = pkg` 以兼容 TypeScript `__importDefault` 编译产物）：

| 模块 / 全局 | 兼容能力摘要 |
|---|---|
| `require("axios")` | `axios(cfg)`、`axios(url, cfg)`、`.get/.post/.put/.delete/.head/.request`、`.create(baseCfg)`、`defaults`、`interceptors.{request,response}.use`、JSON/Text/JSONP 解析与宽容原始 header 参数兜底 |
| `require("crypto-js")` | `MD5`、`SHA1`、`SHA256`、`SHA512`、`HmacMD5`、`HmacSHA1`、`HmacSHA256`、`HmacSHA512`、`AES.{encrypt,decrypt}`（`ECB`/`CBC` + `Pkcs7`/`NoPadding`）、`enc.{Utf8,Hex,Base64,Latin1}` |
| `require("cheerio")` | `cheerio.load(html)` 及 `.find/.children/.parent/.eq/.first/.last/.get/.each/.map/.toArray/.text/.html/.attr/.prop('tagName')` HTML 选择器引擎 |
| `require("he")` | `decode` / `encode` / `escape` / `unescape`（HTML 命名实体 + 十进制/十六进制数字实体） |
| `require("dayjs")` | `dayjs(input)` / `dayjs.unix(sec)` / `.format` / `.unix` / `.valueOf` / `.add` / `.subtract` |
| `require("qs")` / `require("querystring")` | `stringify` / `parse` |
| `require("big-integer")` | 基于原生 ES `BigInt` 的 `modPow` / `pow` / `add` / `subtract` / `multiply` / `divide` / `toString(radix)` |
| `require("webdav")` | `AuthType.Password`、`createClient(url, opts)`、`.getDirectoryContents(path)`（基于 `PROPFIND`）、`.getFileDownloadLink(path)` |
| `require("crypto")` | `md5`、`sha1`、`sha256`、`sha512`、`hmacSha1`、`hmacSha256`、`hmacMd5`、`base64Encode`、`base64Decode`、`createHash`、`createHmac`、`randomBytes` |
| 全局对象 | WHATWG `URL` 与 `URLSearchParams`、`Buffer`、`env.getUserVariables()` / `env.setUserVariables()`、`flow.{request,storage,crypto}`、`global` / `self` / `window` → `globalThis`、`btoa` / `atob`、`setTimeout` / `clearTimeout`、`console` |

### 2.6 LX 自定义源兼容（`globalThis.lx`）

对于遵循 LX Music v2 脚本规范（存在 `@name` 头部且通过 `globalThis.lx.on(EVENT_NAMES.request, ...)` 与 `send(EVENT_NAMES.inited, { sources })` 初始化）的脚本：
- `JSPluginRuntime` 自动捕获初始化声明的源映射与音质配置并注入 `request(url, options, (err, resp) => ...)` HTTP 桥梁；
- 导入阶段识别为 `hasLXBridge` 源，可解析 `musicUrl`、`lyric`、`pic` 请求并返回统一音频流与歌词结果。

---

## 三、声明式 JSON 接口模板标准（`flow-source-v1`）

无需任何 JavaScript 代码，仅通过 URL 模板、请求头与路径表达式即可接入公开 REST API：

```json
{
  "schema": "flow-source-v1",
  "id": "public-api-id",
  "name": "展示名称",
  "version": "1.0.0",
  "allowedDomains": ["api.example.com"],
  "headers": {
    "Accept": "application/json"
  },
  "search": {
    "method": "GET",
    "url": "https://api.example.com/search?q={{query}}&limit={{limit}}",
    "itemsPath": "data.items",
    "durationScale": 1,
    "fields": {
      "id": "id",
      "title": "title|name",
      "artist": "artist.name|creator.0|creator",
      "album": "album.title",
      "duration": "duration",
      "artwork": "artwork.480x480|artwork.150x150|cover",
      "artworkTemplate": "https://api.example.com/img/{{id}}",
      "streamUrl": "stream_url",
      "streamUrlTemplate": "https://api.example.com/tracks/{{id}}/stream",
      "lyricsUrl": "lyrics_url"
    }
  },
  "discover": {
    "url": "https://api.example.com/trending?limit={{limit}}",
    "itemsPath": "data",
    "fields": { "id": "id", "title": "title", "artist": "artist" }
  },
  "resolve": {
    "mode": "direct",
    "url": "https://api.example.com/tracks/{{id}}/stream",
    "streamUrlPath": "data.url",
    "codec": "MP3",
    "fileExtension": "mp3"
  },
  "lyrics": {
    "url": "https://api.example.com/tracks/{{id}}/lyrics",
    "textPath": "lrc"
  }
}
```

### 扩展兼容特性
1. **多路径回退表达式**：任意字段路径支持 `a.b|c.0|d` 竖线分隔回退链；`itemsPath` 留空或省略即直接解析根级 JSON 数组（如 Radio Browser）。
2. **`resolve.mode`**：
   - `"json"`（默认）：向 `resolve.url` 发起 JSON 请求并按 `streamUrlPath` 提取音频地址与动态 `headersPath`；
   - `"direct"`：将插值后的 `resolve.url` 直接作为音频流地址（适配 Audius、Internet Archive、Subsonic REST 直链等直接返回音频或 302 重定向的开放接口）。
3. **JSONP 自动解包**：如远端返回 `callback({...});`，自动剥离 JSONP 外壳后再解析 JSON。
4. **模板占位符**：URL 与模板字段支持 `{{query}}`（自动做 query value 安全百分号编码）、`{{limit}}`、`{{offset}}`、`{{page}}`、`{{id}}`、`{{title}}`、`{{artist}}`。

---

## 四、自建服务器预设 JSON（`flow-server-v1`）

```json
{
  "schema": "flow-server-v1",
  "kind": "opensubsonic",
  "displayName": "Home Navidrome",
  "baseURL": "https://music.example.com",
  "username": "listener"
}
```

支持在导入 JSON 或订阅时直接生成标准 `ServerSourceConfig`（`opensubsonic` 或 `webdav`）；口令留空或通过 Keychain 安全补充，绝不明文硬编码写盘到 `UserDefaults`。

---

## 五、外部参考示例与 GitHub 开源实测来源

- [external-plugins/examples/audius.flow.json](../external-plugins/examples/audius.flow.json)：Audius 开放 REST API 声明式模板
- [external-plugins/examples/radiobrowser.flow.json](../external-plugins/examples/radiobrowser.flow.json)：Radio Browser 开放电台根数组接口模板
- [external-plugins/examples/internetarchive.flow.json](../external-plugins/examples/internetarchive.flow.json)：Internet Archive 公共音频典藏检索模板
- GitHub 生态对标项目（已纳入离线与 `SLP_LIVE_TEST=1` 实网端到端验证）：
  - `maotoumao/MusicFree`（`IPluginDefine` 类型规范与沙箱白名单模块清单）
  - `maotoumao/MusicFreePlugins`（`navidrome`、`webdav`、`geciwang`、`geciqianxun`、`audiomack`、`maoerfm` 等真实 TS 编译插件及 `plugins.json` 订阅）
  - `qwerwhr/musicfree-plugins`（如 `CCTV听音.js` 推荐歌单 + HLS `.m3u8` 实时音频流）
  - Community `plugins.json` 清单（GitHub/CDN 链接重写、空格/中文文件名转义、部分 404 容错）与 LX Music 自定义源接口格式（`globalThis.lx`）
- 已落地的多配置兼容强化：
  - **音质降级回退**：`getMediaSource` 自动按 `[requested, "standard", "low", "high", "super"]` 顺序探测可用档位（兼容仅实现 `"standard"`/`"low"` 的插件，如 `audiomack`、`maoerfm`）
  - **无扩展名音频魔数嗅探**：`MediaAudioCache.sniffAudioExtension` 按响应头字节与 MIME 自动识别 `flac` / `mp3` / `aac` / `ogg` / `opus` / `wav` / `m4a`（兼容 Navidrome `/rest/stream` 等无后缀直链）
  - **HLS（`.m3u8`）受控播放**：`AVURLAsset` 只访问本机回环代理，列表、分片、初始化片段与密钥由 `PluginHTTPClient` 逐跳校验域名和联网开关；跨源剥离秘密头，不支持的动态网络扩展拒绝加载（不误走单文件下载，也不退回外网直连）
  - **HTTP 与签名精确性**：`HTTPRequestSpec` 自动区分 JS `Boolean` (`true`/`false`) 与数字、`percentEncodedQuery` 按 RFC 3986 编码 `+`/`/`/`=`，`cheerio` 保留 `<script>`/`<style>` 原始文本（适配 OAuth1 `HMAC-SHA1` 与 `__NEXT_DATA__` 提取）
