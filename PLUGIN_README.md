# openclaw-exporter-to-langfuse

## What This Plugin Does

**openclaw-exporter-to-langfuse** is an OpenClaw plugin that exports AI agent execution traces to [Langfuse](https://langfuse.com) via the OpenTelemetry OTLP protocol.

Every time OpenClaw handles an agent request, this plugin captures the full execution chain — including agent invocations, LLM calls, tool executions, token usage, and prompt/response content — and sends them as structured traces to your Langfuse project. This gives you end-to-end visibility into how your agents behave in production.

### How It Works

```
OpenClaw Runtime
    │
    ├─ enter_openclaw_system  (ENTRY span)
    │     └─ invoke_agent     (AGENT span)
    │           ├─ chat       (LLM span — prompt, response, token usage)
    │           └─ execute_tool (TOOL span — tool name, input/output)
    │
    └─ [hooks: gateway_start / session_start / session_end /
               message_received / message_sending / message_sent /
               llm_input / llm_output / before_message_write /
               before_tool_call / after_tool_call /
               before_agent_start / agent_end]
               │
               ▼
    LangfuseExporter
    (OTLPTraceExporter → BatchSpanProcessor)
               │
               ▼
    Langfuse  /api/public/otel/v1/traces
```

### Reported Spans

| Span name | `gen_ai.span.kind` | Description |
|---|---|---|
| `enter_openclaw_system` | `ENTRY` | Request entry point |
| `invoke_agent` | `AGENT` | Agent invocation |
| `chat` | `LLM` | LLM call (prompt, response, tokens) |
| `execute_tool` | `TOOL` | Tool / function call |
| `session_start` / `session_end` | — | Session lifecycle |
| `gateway_start` / `gateway_stop` | — | Gateway lifecycle |

---

## Configuration

Add the following to your `openclaw.json` to enable the plugin and configure it under `plugins.entries.openclaw-exporter-to-langfuse.config`:

| Option | Type | Default | Description |
|---|---|---|---|
| `endpoint` | string | `""` | Langfuse OTLP endpoint (e.g. `https://<LANGFUSE_HOST>/api/public/otel/v1/traces`) |
| `headers.Authorization` | string | `""` | Langfuse Basic auth header (base64-encoded `pk:sk`) |
| `serviceName` | string | `"openclaw-agent"` | Service name shown in Langfuse traces |
| `tags` | string[] | `[]` | Custom Langfuse tags on the root trace span |
| `userId` | string | `""` | Static user ID used when the hook event does not provide one. Priority: hook event > config > `"unknown"` |
| `batchSize` | number | `10` | Spans to buffer before flushing |
| `flushIntervalMs` | number | `5000` | Max ms to wait before flushing buffered spans |
| `debug` | boolean | `false` | Enable verbose debug logging |
| `skillTaggingEnabled` | boolean | `false` | Detect and emit `skill:*` tags on tool observations |
| `skillsRoots` | string[] | `[]` | Explicit skill root directories (skips auto-detection) |
| `enabledHooks` | string[] | _(all)_ | Restrict which hooks are active |

**Minimal example with Langfuse Cloud:**

> **How to create the `Authorization` header:**
> 1. Go to your Langfuse project → **Settings → API Keys**
> 2. Copy your **Public Key** (`pk-lf-xxx`) and **Secret Key** (`sk-lf-yyy`)
> 3. Generate the Base64-encoded value:
>    ```bash
>    echo -n "pk-lf-xxx:sk-lf-yyy" | base64 -w 0
>    # Example output: cGstbGYteHh4OnNrLWxmLXl5eQ==
>    ```
> 4. Set `Authorization` to `"Basic <output>"`, e.g. `"Basic cGstbGYteHh4OnNrLWxmLXl5eQ=="`

```json
{
  "plugins": {
    "entries": {
      "openclaw-exporter-to-langfuse": {
        "enabled": true,
        "hooks": {
          "allowConversationAccess": true
        },
        "config": {
          "endpoint": "http://<LANGFUSE_HOST>/api/public/otel/v1/traces",
          "headers": {
            "Authorization": "Basic <base64(pk:sk)>"
          },
          "serviceName": "my-openclaw-agent"
        }
      }
    }
  }
}
```

---

## Alibaba Cloud Observability Integration

Supports delivering OpenClaw runtime data to Alibaba Cloud ClickHouse **Agent-lens** and the **All-in-one-observe-suite** platform, helping you comprehensively monitor and analyze the runtime status of your Agent applications.

| Capability | What You Can See | Tool |
|---|---|---|
| **Trace → Agent-lens** | Full agent call-chain tree, LLM prompt/response, token usage, per-span latency | [Agent-lens](https://help.aliyun.com/clickhouse/user-guide/agent-lens-overview) |
| **Trace / Metric / Log → ClickHouse** | Gateway QPS, error rates, system logs, resource metrics — query with AI Notebook | [All-in-one-observe-suite](https://help.aliyun.com/clickhouse/user-guide/all-in-one-observe-suite) |

Installation: https://ck-langfuse-public.oss-cn-beijing.aliyuncs.com/openclaw-exporter-to-langfuse/INSTALLATION.md

Full setup guide: https://help.aliyun.com/clickhouse/user-guide/openclaw-observability

---

**Open Source**: https://github.com/aliyun/openclaw-exporter-to-langfuse