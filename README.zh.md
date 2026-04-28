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

## 快速开始

```bash
curl -fsSL https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/install.sh | sudo bash -s -- \
  --endpoint "<your-otlp-endpoint>" \
  --pk "pk-lf-xxx" \
  --sk "sk-lf-yyy" \
  --serviceName "my-service" \
  --config "<path-to-openclaw.json>" \
  --install-dir "<path-to-install-directory>"
```

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
