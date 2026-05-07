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

## Version Management

### Default OSS Location

All release artifacts are hosted on Alibaba Cloud OSS under:

```
https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/
```

### OSS Directory Structure

```
<oss-host>/openclaw-exporter-to-langfuse/
├── install.sh                   ← same as v0.1.2/install.sh (latest version)
├── uninstall.sh                 ← same as v0.1.2/uninstall.sh (latest version)
├── version-compat.json          ← compatibility matrix (all versions)
├── INSTALLATION.md              ← agent-readable installation guide
├── v0.1.0/
│   ├── install.sh               ← PLUGIN_VERSION="v0.1.0" baked in
│   ├── uninstall.sh
│   └── openclaw-exporter-to-langfuse.tar.gz
├── v0.1.1/
│   ├── install.sh               ← PLUGIN_VERSION="v0.1.1" baked in
│   ├── uninstall.sh
│   └── openclaw-exporter-to-langfuse.tar.gz
└── v0.1.2/
    ├── install.sh               ← PLUGIN_VERSION="v0.1.2" baked in
    ├── uninstall.sh
    └── openclaw-exporter-to-langfuse.tar.gz
```

`version-compat.json` declares which exporter version is compatible with each range of OpenClaw versions. Example:

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

### Installation Logic

Version selection is handled entirely by the AI agent — the versioned `install.sh` itself only performs a pure single-version install:

```
1. Agent: openclaw --version / -V
          → extract "2026.5.4"

2. Agent: fetch version-compat.json
          → match OpenClaw version → exporterVersion = "v0.1.2"

3. Agent: curl .../v0.1.2/install.sh | sudo bash -s -- <flags>
          (no --exporter-version flag needed or accepted)

4. install.sh: downloads .../v0.1.2/openclaw-exporter-to-langfuse.tar.gz
               configures openclaw.json
```

Each versioned `install.sh` has `PLUGIN_VERSION` baked in for its own version, so there is no version-selection logic inside the script. If the agent cannot determine the OpenClaw version and the user cannot provide it manually, the agent falls back to using the `latest` version from `version-compat.json`.

### Release Flow

```bash
# 1. Update VERSION file
echo "0.1.2" > VERSION

# 2. Build, bake, and package (pack.sh does everything)
bash scripts/pack.sh
# Outputs:
#   release/v0.1.2/install.sh         ← PLUGIN_VERSION="v0.1.2" baked in
#   release/v0.1.2/uninstall.sh       ← SELF_VERSION="v0.1.2" baked in
#   release/v0.1.2/openclaw-exporter-to-langfuse.tar.gz
#   release/install.sh                ← copy of v0.1.2/install.sh (latest)
#   release/uninstall.sh              ← copy of v0.1.2/uninstall.sh (latest)
#   release/version-compat.json
#   release/INSTALLATION.md

# 3. Upload versioned artifacts to OSS:
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/v0.1.2/

# 4. Upload root-level artifacts to OSS:
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/install.sh
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/uninstall.sh
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/version-compat.json
#    oss://ck-langfuse-public/openclaw-exporter-to-langfuse/INSTALLATION.md
```

---

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
