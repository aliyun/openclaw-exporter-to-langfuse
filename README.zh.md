# openclaw-exporter-to-langfuse

<!-- LANGUAGE_SELECTOR_START -->
[English](./README.md) | **中文**
<!-- LANGUAGE_SELECTOR_END -->

OpenClaw 到 Langfuse 的导出器，提供两种互补的可观测性能力：

| 能力 | 数据通路 | 关注层面 | 可视化工具 |
|------|----------|----------|------------|
| **Langfuse 链路追踪** | OpenClaw → 本导出器 → Langfuse | LLM 应用层：Agent/LLM/Tool 调用链路、Token 用量、Prompt/Response | Langfuse |
| **系统可观测性**（可选） | OpenClaw → diagnostics-otel → otelcol-contrib → ClickHouse | 基础设施层：网关 QPS、错误率、系统日志、资源指标 | Grafana / HyperDX 等 |

两者独立运行、互不替代，生产环境推荐同时启用。

在 **阿里云** 上，[Agent-lens](https://help.aliyun.com/clickhouse/user-guide/agent-lens-overview) 由 **ClickHouse** 或 **SelectDB** 与 **Langfuse** 组合提供托管的 Agent 可观测性（全链路追踪、提示词管理、评估等），与开源 Langfuse 生态兼容。

技术细节（Hook 机制、Span 层级、Exporter 工作原理等）请参阅 [TUTORIAL.zh.md](./TUTORIAL.zh.md)。

## 安装 / 卸载

详细安装说明请参阅 [INSTALLATION.md](./scripts/INSTALLATION.md)（Agent 专用），包含：

- 一键安装（pk/sk 或 authorization）
- 可选 otelcol-contrib + ClickHouse 集成
- 一键卸载（支持选择性卸载组件）
- 手动安装方式
- 常见问题排查

## 上报的 Span

导出器按照 [OpenTelemetry GenAI 语义规范](https://opentelemetry.io/docs/specs/semconv/gen-ai/) 上报以下 Span：

| Span | gen_ai.span.kind | 说明 |
|------|------------------|------|
| `enter_openclaw_system` | ENTRY | 请求入口 |
| `invoke_agent` | AGENT | Agent 调用 |
| `chat` | LLM | LLM 调用 |
| `execute_tool` | TOOL | 工具执行 |
| `session_start` / `session_end` | -- | 会话生命周期 |
| `gateway_start` / `gateway_stop` | -- | 网关生命周期 |

## 版本管理

### 安装包默认位置

所有发布产物托管在阿里云 OSS 的以下路径：

```
https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/
```

### OSS 目录结构

```
<oss-host>/openclaw-exporter-to-langfuse/
├── version-compat.json          ← 兼容矩阵（全量版本）
├── INSTALLATION.md              ← Agent 可读的安装指南
├── latest/                      ← 始终与最新版本（v0.1.2）内容一致
│   ├── install.sh               ← 已写入 PLUGIN_VERSION="v0.1.2"
│   ├── uninstall.sh
│   ├── INSTALLATION.md
│   └── openclaw-exporter-to-langfuse.tar.gz
├── v0.1.0/
│   ├── install.sh               ← 已写入 PLUGIN_VERSION="v0.1.0"
│   ├── uninstall.sh
│   ├── INSTALLATION.md
│   └── openclaw-exporter-to-langfuse.tar.gz
├── v0.1.1/
│   ├── install.sh               ← 已写入 PLUGIN_VERSION="v0.1.1"
│   ├── uninstall.sh
│   ├── INSTALLATION.md
│   └── openclaw-exporter-to-langfuse.tar.gz
└── v0.1.2/
    ├── install.sh               ← 已写入 PLUGIN_VERSION="v0.1.2"
    ├── uninstall.sh
    ├── INSTALLATION.md
    └── openclaw-exporter-to-langfuse.tar.gz
```

`version-compat.json` 声明每个 exporter 版本对应的 OpenClaw 版本范围，示例：

```json
{
  "latest": "v0.1.2",
  "compatMatrix": [
    {
      "minOpenclaw": "2026.4.24",
      "maxOpenclaw": "",
      "exporterVersion": "v0.1.2"
    },
    {
      "minOpenclaw": "2026.2.29",
      "maxOpenclaw": "2026.4.24",
      "exporterVersion": "v0.1.0"
    }
  ]
}
```

### 安装逻辑

版本选择完全由 AI Agent 负责，版本专属的 `install.sh` 只执行纯安装，不做版本选择：

```
1. Agent：openclaw --version / -V
          → 提取 "2026.5.4"

2. Agent：获取 version-compat.json
          → 匹配 OpenClaw 版本 → exporterVersion = "v0.1.2"

3. Agent：curl .../v0.1.2/install.sh | sudo bash -s -- <参数>
          （不需要也不接受 --exporter-version 参数）

4. install.sh：下载 .../v0.1.2/openclaw-exporter-to-langfuse.tar.gz
               配置 openclaw.json
```

每个版本的 `install.sh` 均已将 `PLUGIN_VERSION` 写入该版本号，脚本内部无版本选择逻辑。若 Agent 无法确定 OpenClaw 版本且用户也无法提供，则回退到 `version-compat.json` 中 `latest` 指定的版本。

### 发布流程

```bash
# 1. 更新 VERSION 文件
echo "0.1.2" > VERSION

# 2. 构建、写入版本并打包（pack.sh 一步完成）
bash scripts/pack.sh
# 输出：
#   release/v0.1.2/install.sh         ← 已写入 PLUGIN_VERSION="v0.1.2"
#   release/v0.1.2/uninstall.sh       ← 已写入 SELF_VERSION="v0.1.2"
#   release/v0.1.2/INSTALLATION.md    ← 版本专属安装指南
#   release/v0.1.2/openclaw-exporter-to-langfuse.tar.gz
#   release/latest/                   ← 与 v0.1.2/ 内容完全一致
#   release/version-compat.json
#   release/INSTALLATION.md

# 3. 上传版本目录到 OSS：
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/v0.1.2/

# 4. 上传 latest/ 到 OSS：
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/latest/

# 5. 上传根目录文件到 OSS：
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/version-compat.json
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/INSTALLATION.md
```

---

## 开发

```bash
npm install
npm run build    # 编译 TypeScript
npm run dev      # 监听模式
```

### 打包发布

```bash
bash scripts/pack.sh
# 输出: release/openclaw-exporter-to-langfuse.tar.gz
```

## 许可证

MIT

## 交流

扫码加入钉钉讨论群：

<img src="https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/dingtalk-qr-code.JPG" alt="QR Code" width="200" />

**钉钉群号**：180485008966
