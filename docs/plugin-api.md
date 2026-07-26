# OpenFinder 插件 API 参考

本文是插件包、manifest、输入、事件和工件的字段参考。插件生命周期与设计理由见 [`plugin-system.md`](plugin-system.md)。

## 包格式

首选后缀是 `.openfinderplugin`，兼容旧后缀 `.plugin`。

```text
my-action.openfinderplugin/
├── manifest.json
├── run.sh | run.py | run.js   # 仅 process 插件
└── README.md                   # 可选
```

约束：

- 包必须是真实目录，不能是文件或符号链接；
- `manifest.json` 必须是包内的普通文件，不能是符号链接；
- process `entry` 必须解析到包内普通文件；
- 包 ID 重复时，Built-in > User > Development；
- 单个坏包产生诊断，不阻止合法兄弟包加载。

扫描目录见 [`plugin-system.md#1-发现与目录优先级`](plugin-system.md#1-发现与目录优先级)。

## Manifest 顶层字段

| 字段 | 类型 | 必需 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | integer | 是 | `1` = process，`2` = HTTP v1 |
| `id` | string | 是 | 稳定、全局唯一的插件 ID |
| `name` | string | 是 | UI 显示名 |
| `version` | string | 是 | durable task 精确保存并在执行时校验 |
| `description` | string | 否 | 设置页描述 |
| `author` | string | 否 | 作者 |
| `runtime` | object/string | schema 1 | process runtime |
| `entry` | string | schema 1 | 包内相对入口 |
| `execution` | object | schema 2 | HTTP transport 描述 |
| `actions` | action[] | 是 | 可匹配的上下文动作 |
| `permissions` | object | 是 | 文件、网络、剪贴板、secret 等声明 |
| `configuration` | config field[] | 是 | 设置 UI 与运行输入的普通配置 |

未知顶层字段目前由 Swift `Codable` 忽略；事件与 HTTP wire 则执行严格未知字段拒绝。插件不应依赖未声明顶层字段。

## Schema 1：process

```json
{
  "schemaVersion": 1,
  "id": "dev.example.echo",
  "name": "Echo",
  "version": "1.0.0",
  "runtime": { "type": "python3", "minimumVersion": "3.9" },
  "entry": "run.py",
  "actions": [],
  "permissions": {
    "readFiles": "selected",
    "writeFiles": "none",
    "network": { "required": false, "hosts": [] },
    "clipboardWrite": false,
    "clipboardRead": false,
    "keychainSecrets": [],
    "localSecrets": [],
    "remoteAccounts": false,
    "runExternalCommands": false
  },
  "configuration": []
}
```

`runtime`：

| `type` | 默认命令 | 可配置 |
| --- | --- | --- |
| `shell` | `/bin/zsh` | 无 |
| `python3` | `/usr/bin/env python3` | Settings 中的 Python path |
| `node` | `/usr/bin/env node` | Settings 中的 Node path |

`minimumVersion` 可随 Python/Node runtime 声明并保留在 manifest 模型中；当前 runner 不把它当作独立版本探测结果，插件仍应自行兼容目标 runtime。

## Schema 2：HTTP

```json
{
  "schemaVersion": 2,
  "id": "dev.example.analyzer",
  "name": "Analyzer",
  "version": "1.0.0",
  "execution": {
    "type": "http",
    "protocolVersion": 1,
    "endpointConfigurationKey": "serverURL",
    "tokenSecretKey": "serverToken"
  },
  "actions": [],
  "permissions": {
    "readFiles": "selected",
    "writeFiles": "taskOutput",
    "network": { "required": true, "hosts": ["127.0.0.1", "::1"] },
    "clipboardWrite": false,
    "clipboardRead": false,
    "keychainSecrets": [],
    "localSecrets": ["serverToken"],
    "remoteAccounts": false,
    "runExternalCommands": false
  },
  "configuration": [
    {
      "key": "serverURL",
      "type": "url",
      "title": "Server URL",
      "default": "http://127.0.0.1:8765",
      "required": true
    }
  ]
}
```

校验：

- `execution.type` 必须是 `http`；
- `protocolVersion` 当前只能是 `1`；
- `endpointConfigurationKey` 必须非空，并存在于 `configuration`；
- `tokenSecretKey` 必须非空，并且只出现在一种 secret storage 声明中；
- 不能混入 schema 1 的 `runtime`/`entry`；
- endpoint 必须满足 [HTTP v1 loopback 约束](plugins/http-plugin-v1.md#transport-boundary)。

## Action

```json
{
  "id": "analyze-video",
  "title": "Analyze Video",
  "category": "Analysis",
  "selection": {
    "minItems": 1,
    "maxItems": 100,
    "allowDirectories": false
  },
  "match": {
    "extensions": ["mp4", "mov"],
    "uttypes": ["public.movie"],
    "mimePrefixes": ["video/"],
    "matchMode": "all"
  },
  "output": {
    "resultType": "mediaAnalysis.v1",
    "canCopyToClipboard": false
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 插件内稳定 action ID |
| `title` | string | 上下文菜单标题 |
| `category` | string? | UI 分组提示 |
| `selection.minItems` | integer | 默认 0 |
| `selection.maxItems` | integer? | 缺省表示无上限 |
| `selection.allowDirectories` | boolean | 默认 true |
| `match.extensions` | string[] | 大小写不敏感扩展名，不带点 |
| `match.uttypes` | string[] | 精确、前缀或系统 UTType conformance |
| `match.mimePrefixes` | string[] | 前缀匹配 |
| `match.matchMode` | `all`/`any` | 对选中项集合的量词 |
| `output.resultType` | string? | result handler/renderer schema ID |
| `output.canCopyToClipboard` | boolean | UI 是否允许复制 terminal clipboard |

同一文件的 extension/UTType/MIME 非空条件是 AND。`matchMode` 决定所有选中项或任一选中项需要满足该文件规则。

## Permissions

| 字段 | 类型 | 当前含义 |
| --- | --- | --- |
| `readFiles` | string | 常用 `none`、`selected` |
| `writeFiles` | string | 常用 `none`、`selected`、`taskOutput` |
| `network.required` | boolean | 是否声明需要网络 |
| `network.hosts` | string[] | 审计/UI 允许主机提示；HTTP v1 另有强制 loopback 校验 |
| `clipboardWrite` | boolean | terminal clipboard 声明 |
| `clipboardRead` | boolean | 剪贴板读取声明 |
| `keychainSecrets` | string[] | 由 macOS Keychain 保存的 key |
| `localSecrets` | string[] | 由 secured local config 保存的 key |
| `remoteAccounts` | boolean | 远端账号访问声明 |
| `runExternalCommands` | boolean | 外部命令声明 |

Secret key 在各自数组内必须唯一，两数组必须不相交。当前 process 插件仍以用户权限运行，permissions 不是 OS sandbox enforcement。

## Configuration

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `key` | string | `PluginInput.config` 中的 key |
| `type` | string | `bool`/`boolean` 使用 Toggle；其他使用 TextField |
| `title` | string | UI label |
| `default` | string? | 没有非空 saved value 时使用 |
| `required` | boolean | 字段元数据 |
| `storage` | string? | 保留的字段元数据；secret storage 由 permissions 决定 |
| `options` | `{label,value}[]`? | 非空时使用 Picker |

所有配置在 wire 中是字符串；bool 使用 `"true"`/`"false"`。空白 saved value 被视为未设置并回退 default。未在 manifest 声明的 saved key 不进入插件输入。

## PluginInput

OpenFinder 向 process stdin 或 HTTP `POST /jobs` 发送一个对象：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schemaVersion` | integer | 当前为 1 |
| `taskID` | UUID | 本次 attempt identity；HTTP 幂等键 |
| `actionID` | string | manifest action ID |
| `app` | `{name,version}` | 调用应用 |
| `context.activePane` | string | UI pane identity |
| `context.currentLocation` | `Location` | 当前 local/remote 位置 |
| `files` | `PluginInputFile[]` | 执行时文件快照 |
| `config` | string map | 已声明配置的 resolved value |
| `secrets` | `{key:{env:string}}` map | 凭据引用/环境变量名，不是明文 |
| `tempDirectory` | absolute string | 本次临时目录 |
| `outputDirectory` | absolute string | 允许生成 result artifact 的根 |

`PluginInputFile`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `path` | string | 本地 path 或 provider display path |
| `name` | string | 文件名 |
| `extension` | string? | 不带点 |
| `uti` | string? | UTType identifier |
| `mimeType` | string? | MIME |
| `size` | int64? | 已知字节数 |
| `isDirectory` | boolean | 目录标记 |

HTTP v1 是同机路径协议，不上传 `files[].path` 对应字节。

## Process stdout 事件

每个非空 stdout 行必须是一个 JSON object。未知字段会被拒绝。

### Log

```json
{"type":"log","level":"info","message":"Starting"}
```

`message` 必需；`level` 缺省为 `info`。

### Progress

```json
{
  "type":"progress",
  "fraction":0.5,
  "message":"Halfway",
  "phase":"analyzing",
  "completed":5,
  "total":10,
  "unit":"files"
}
```

`fraction` 必须是有限的 `0...1`。`completed` 与 `total` 必须同时出现，满足 `completed >= 0`、`total > 0`、`completed <= total`。

### Result

Inline artifact：

```json
{
  "type":"result",
  "status":"success",
  "message":"Done",
  "clipboard":"optional text",
  "artifacts":[
    {"type":"text","content":"inline payload"}
  ]
}
```

File artifact：

```json
{
  "type":"result",
  "status":"success",
  "artifacts":[
    {
      "type":"archive",
      "artifactID":"D0B238A9-6F55-4B60-8A62-05D7633B4B65",
      "relativePath":"selection.zip",
      "mediaType":"application/zip",
      "byteCount":1234,
      "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
```

`status` 只能是 `success`、`failure`、`cancelled`。输出必须恰好包含一个 result，且它是最后一个事件。成功还要求进程退出码为 0。

stderr 作为 debug log 保存，不参与事件协议。

## File artifact 校验

- `artifactID` 在一次 result 中必须唯一；
- `relativePath` 必须非空、相对 `outputDirectory` 且不能逃逸；
- 路径中任何符号链接都不能指向根外；
- 文件实际字节数必须等于 `byteCount`；
- SHA-256 必须是 64 位小写十六进制并与文件一致；
- artifact 只有提交完成后才可持久打开；
- inline 与 file 字段不能混合。

## Result schema

`output.resultType` 是路由 ID：

| ID | 契约 | Renderer |
| --- | --- | --- |
| `mediaAnalysis.v1` | 正好一个同 type JSON schema artifact，解码为 `MediaAnalysisDocument` v1 | 共享媒体分析工作区 |
| 其他/缺省 | 保留 terminal message 与 artifacts | generic artifact UI |

不同插件 ID 可以共享同一 schema。不要依赖插件 ID 选择 Swift 类型或 renderer。

## 内置示例

| 包 | Transport | 结果 |
| --- | --- | --- |
| `batch-rename-demo.plugin` | Python | text/clipboard dry-run |
| `copy-markdown-image.plugin` | Python | Markdown links |
| `remove-quarantine.plugin` | Python | 外部命令结果 |
| `upload-image-demo.plugin` | Python | deterministic demo URLs |
| `zip-selected.plugin` | Python | file-backed archive |
| `video-analyzer.plugin` | HTTP v1 | `mediaAnalysis.v1` |

`Tests/**/Fixtures` 下的插件只用于测试，不能复制进 `ExamplePlugins` 或 `BuiltinPlugins`。

## 相关参考

- [插件机制](plugin-system.md)
- [HTTP 插件协议 v1](plugins/http-plugin-v1.md)
- [OpenAPI](plugins/http-plugin-v1.openapi.json)
- [Renderer Catalog](renderer-catalog.md)
- [开发与维护指南](development.md)
