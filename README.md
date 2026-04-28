# openclaw-exporter-to-langfuse

<!-- LANGUAGE_SELECTOR_START -->
**English** | [中文](./README.zh.md)
<!-- LANGUAGE_SELECTOR_END -->

An OpenClaw exporter that provides two complementary observability capabilities:

| Capability | Data Path | Focus | Visualization |
|------------|-----------|-------|---------------|
| **Langfuse Tracing** | OpenClaw → this exporter → Langfuse | LLM application layer: Agent/LLM/Tool call chains, token usage, prompt/response | Langfuse |
| **System Observability** (optional) | OpenClaw → diagnostics-otel → otelcol-contrib → ClickHouse | Infrastructure layer: gateway QPS, error rates, system logs, resource metrics | Grafana / HyperDX etc. |

The two capabilities run independently and do not replace each other. For production environments, we recommend enabling both.

On **Alibaba Cloud**, [Agent-lens](https://help.aliyun.com/clickhouse/user-guide/agent-lens-overview) is the managed agent/LLM observability offering built on **ClickHouse** or **SelectDB** plus **Langfuse** (tracing, prompt management, evaluation). It remains compatible with the open Langfuse ecosystem.

For technical details (hook mechanism, span hierarchy, exporter internals, etc.), see [TUTORIAL.md](./TUTORIAL.md).

## Installation / Uninstallation

See [INSTALLATION.md](./scripts/INSTALLATION.md) (for AI agents) for full installation instructions, including:

- One-command install (pk/sk or authorization)
- Optional otelcol-contrib + ClickHouse integration
- One-command uninstall (selective component removal)
- Manual installation
- Troubleshooting

## Quick Start

```bash
curl -fsSL https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/install.sh | sudo bash -s -- \
  --endpoint "<your-otlp-endpoint>" \
  --pk "pk-lf-xxx" \
  --sk "sk-lf-yyy" \
  --serviceName "my-service" \
  --config "<path-to-openclaw.json>" \
  --install-dir "<path-to-install-directory>"
```

## Reported Spans

The exporter reports spans following [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/):

| Span | gen_ai.span.kind | Description |
|------|------------------|-------------|
| `enter_openclaw_system` | ENTRY | Request entry |
| `invoke_agent` | AGENT | Agent invocation |
| `chat` | LLM | LLM call |
| `execute_tool` | TOOL | Tool execution |
| `session_start` / `session_end` | -- | Session lifecycle |
| `gateway_start` / `gateway_stop` | -- | Gateway lifecycle |

## Development

```bash
npm install
npm run build    # Compile TypeScript
npm run dev      # Watch mode
```

### Build & Package

```bash
bash scripts/pack.sh
# Output: release/openclaw-exporter-to-langfuse.tar.gz
```

## License

MIT

## Contact

Scan the QR code to join the DingTalk discussion group:

<img src="https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/dingtalk-qr-code.JPG" alt="QR Code" width="200" />

**DingTalk Group**: 180485008966
