# openclaw-exporter-to-langfuse {{EXPORTER_VERSION}} Installation Guide

> This guide is for exporter version **{{EXPORTER_VERSION}}**.  
> For version selection and compatibility with your OpenClaw version, see the root-level [INSTALLATION.md](https://<oss-host>/openclaw-exporter-to-langfuse/INSTALLATION.md).

---

This installer provides two **independent, optional** observability components for OpenClaw:

- **openclaw-exporter-to-langfuse** — LLM application tracing to Langfuse
- **diagnostics-otel + otelcol-contrib** — System metrics/logs/traces to ClickHouse

You can install either one alone, or both together. Neither is required for the other.

## What's Included

This project provides **two complementary observability capabilities**:

### A) openclaw-exporter-to-langfuse — LLM Application Tracing (optional)

- **What it does**: Captures GenAI-level traces (Agent steps, LLM calls, Tool executions, Token usage, Prompt/Response) and exports them to [Langfuse](https://langfuse.com).
- **Data flow**: `OpenClaw → openclaw-exporter-to-langfuse → Langfuse`
- **View data**: Open your Langfuse project dashboard → **Traces** tab. Each request shows a full call tree: Agent → LLM → Tool with timing, token counts, and input/output.

### B) diagnostics-otel + otelcol-contrib — System Observability (optional)

- **What it does**: Forwards infrastructure-level telemetry (gateway QPS, error rates, system logs, resource metrics) to ClickHouse via a local [otelcol-contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib) collector.
- **Data flow**: `OpenClaw → diagnostics-otel → otelcol-contrib (localhost) → ClickHouse`
- **View data**: Connect Grafana, [HyperDX](https://www.hyperdx.io/), or any ClickHouse-compatible tool to query `otel_traces`, `otel_logs`, `otel_metrics_*` tables in the configured database.

### How They Work Together

The two capabilities are **independent, optional, and non-overlapping** — install either one alone or both together:

| | openclaw-exporter-to-langfuse | diagnostics-otel → ClickHouse |
|---|---|---|
| **Focus** | LLM application layer | Infrastructure / system layer |
| **Data** | Agent/LLM/Tool traces, token usage, prompt/response | QPS, error rate, latency, system logs, resource metrics |
| **Visualization** | Langfuse | Grafana / HyperDX / custom |
| **Typical questions** | "Why did this agent call fail?" "How many tokens were used?" | "What's the gateway error rate?" "Any anomalous logs?" |

For production environments, **we recommend enabling both** (Choice C). The `--diag-traces` flag defaults to `false` to avoid duplicate trace data since the Langfuse exporter already handles LLM traces.

---

## Installation Workflow

> **Principle**: Identify what you need → run `install.sh` → troubleshoot only if it fails. The install script is **idempotent** and handles all configuration automatically.

### Step 1: Choose Components and Gather Parameters

**Both components are optional — pick what you need** and prepare the required parameters:

#### Choice A — Langfuse Exporter Only

AI Agent trace visualization in Langfuse. No otelcol-contrib needed.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--endpoint` | **Yes** | — | Langfuse OTLP endpoint URL |
| `--pk` | **Yes**\* | — | Langfuse Public Key (pk-lf-xxx) |
| `--sk` | **Yes**\* | — | Langfuse Secret Key (sk-lf-yyy) |
| `--authorization` | **Yes**\* | — | Alternative to pk/sk: `"Basic <base64>"` |
| `--serviceName` | **Yes** | — | Service name for traces (e.g., `my-agent-prod`) |
| `--tags` | No | unset | Custom trace-level Langfuse tags (CSV like `"id:openclaw,ip:127.0.0.1"` or JSON array string) |
| `--debug` | No | `false` | Enable exporter debug logs (boolean flag, add this option to enable) |
| `--skill-tagging-enabled` | No | `false` | Enable skill tagging (boolean flag, add this option to enable) |
| `--skills-roots` | No | explicit value (recommended) | Skill roots for tagging. OpenClaw will auto-discover skill paths at runtime when this is omitted, but we recommend passing CSV or JSON array string explicitly for stable behavior |
| `--config` | **Recommended** | auto-detect | Path to `openclaw.json` (e.g., `~/.openclaw/openclaw.json`). Recommended to avoid mis-detection |
| `--install-dir` | **Recommended** | auto-detect | Exporter installation directory (e.g., `~/.openclaw/extensions/openclaw-exporter-to-langfuse`). Recommended to avoid mis-detection |
| `--plugin-url` | No | OSS default | Custom exporter tarball URL |
| `--oss-host` | No | `ck-langfuse-public.oss-cn-beijing.aliyuncs.com` | Full OSS hostname for hosting assets (affects all download URLs) |

\* Provide `--pk` + `--sk` **or** `--authorization` (not both). We recommend pk/sk — the script auto-generates the header.

#### Choice B — OtelCol + ClickHouse Only

System metrics/logs/traces to ClickHouse (Grafana/HyperDX). **No Langfuse exporter installed.** Use `--skip-plugin` to skip it.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--serviceName` | **Yes** | — | Service name for traces |
| `--skip-plugin` | **Yes** | — | Skip openclaw-exporter-to-langfuse installation |
| `--enable-otelcol` | **Yes** | — | Enable otelcol-contrib installation |
| `--ck-endpoint` | **Yes** | — | ClickHouse HTTP endpoint (e.g., `http://<ck-host>:8123`) |
| `--ck-username` | **Yes** | — | ClickHouse username (e.g., `default`) |
| `--ck-password` | **Yes** | — | ClickHouse password |
| `--ck-database` | No | `clickobserve_service` | ClickHouse database name |
| `--config` | **Recommended** | auto-detect | Path to `openclaw.json` (e.g., `~/.openclaw/openclaw.json`). Recommended to avoid mis-detection |
| `--otelcol-binary` | No | auto-download | Path to pre-downloaded otelcol-contrib package |
| `--otelcol-grpc-endpoint` | No | `0.0.0.0:4317` | otelcol-contrib gRPC receiver |
| `--otelcol-http-endpoint` | No | `0.0.0.0:4318` | otelcol-contrib HTTP receiver |
| `--diag-traces` | No | `false` | Forward traces to ClickHouse (default off — avoid duplication) |
| `--diag-logs` | No | `true` | Forward logs to ClickHouse |
| `--diag-metrics` | No | `true` | Forward metrics to ClickHouse |
| `--oss-host` | No | `ck-langfuse-public.oss-cn-beijing.aliyuncs.com` | Full OSS hostname for hosting assets (affects all download URLs) |

#### Choice C — Both (Recommended)

Full observability: Langfuse + ClickHouse. All parameters from A + B, **without** `--skip-plugin`.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--endpoint` | **Yes** | — | Langfuse OTLP endpoint URL |
| `--pk` | **Yes**\* | — | Langfuse Public Key |
| `--sk` | **Yes**\* | — | Langfuse Secret Key |
| `--authorization` | **Yes**\* | — | Alternative to pk/sk |
| `--serviceName` | **Yes** | — | Service name for traces |
| `--tags` | No | unset | Custom trace-level Langfuse tags (CSV or JSON array string) |
| `--debug` | No | `false` | Enable exporter debug logs (boolean flag, add this option to enable) |
| `--skill-tagging-enabled` | No | `false` | Enable skill tagging (boolean flag, add this option to enable) |
| `--skills-roots` | No | explicit value (recommended) | Skill roots for tagging. OpenClaw will auto-discover skill paths at runtime when this is omitted, but we recommend passing CSV or JSON array string explicitly for stable behavior |
| `--enable-otelcol` | **Yes** | — | Enable otelcol-contrib installation |
| `--ck-endpoint` | **Yes** | — | ClickHouse HTTP endpoint (e.g., `http://<ck-host>:8123`) |
| `--ck-username` | **Yes** | — | ClickHouse username (e.g., `default`) |
| `--ck-password` | **Yes** | — | ClickHouse password |
| `--ck-database` | No | `clickobserve_service` | ClickHouse database name |
| `--config` | **Recommended** | auto-detect | Path to `openclaw.json` (e.g., `~/.openclaw/openclaw.json`). Recommended to avoid mis-detection |
| `--plugin-url` | No | OSS default | Custom exporter tarball URL |
| `--install-dir` | **Recommended** | auto-detect | Exporter installation directory (e.g., `~/.openclaw/extensions/openclaw-exporter-to-langfuse`). Recommended to avoid mis-detection |
| `--otelcol-binary` | No | auto-download | Path to pre-downloaded otelcol-contrib package |
| `--otelcol-grpc-endpoint` | No | `0.0.0.0:4317` | otelcol-contrib gRPC receiver |
| `--otelcol-http-endpoint` | No | `0.0.0.0:4318` | otelcol-contrib HTTP receiver |
| `--diag-traces` | No | `false` | Forward traces to ClickHouse |
| `--diag-logs` | No | `true` | Forward logs to ClickHouse |
| `--diag-metrics` | No | `true` | Forward metrics to ClickHouse |
| `--oss-host` | No | `ck-langfuse-public.oss-cn-beijing.aliyuncs.com` | Full OSS hostname for hosting assets (affects all download URLs) |

\* Provide `--pk` + `--sk` **or** `--authorization`.

**Where to find parameters:**

- **Langfuse endpoint / pk / sk**: Langfuse Console → Project Settings → API Keys
- **ClickHouse endpoint / username / password**: Your ClickHouse cluster connection info
- **config**: Path to openclaw.json — run `openclaw config get` to find it, or check `~/.openclaw/openclaw.json`
- **install-dir**: Exporter install directory — typically `~/.openclaw/extensions/openclaw-exporter-to-langfuse`
- **serviceName**: A name to identify this OpenClaw instance (e.g., `my-agent-prod`)
- **debug**: Enable verbose plugin logs for troubleshooting (boolean flag, default `false`)
- **tags**: Custom tags written to `langfuse.tags` on trace root span only (for example: `--tags "id:openclaw,ip:127.0.0.1"` or JSON array string)
- **skill-tagging-enabled**: Whether to emit `skill:*` tags to Langfuse (boolean flag, default `false`)
- **skills-roots**: OpenClaw can auto-discover skill roots at runtime, but we recommend explicitly passing `--skills-roots` (CSV like `"/opt/openclaw/skills,/a/skills"` or JSON array string) to avoid environment differences. Recommended common paths: `/opt/openclaw/skills/`, `/opt/git/openclaw/skills`, `/custom/skills`

> **Important**: Do not rely on `install.sh` to auto-detect and write `skillsRoots`. The preferred practice is to let OpenClaw perform runtime discovery and explicitly set `--skills-roots` in installation/configuration commands when you need deterministic roots.

### Step 2: Run the Install Script

Run this once first to pre-validate elevated permissions and trigger password prompt early (if required):

```bash
sudo -v
```

Pick the matching command from the install sections below ([Choice A](#part-1-langfuse-exporter-installation-choice-a-or-c), [Choice B](#otelcol-only-install--choice-b-skip-langfuse-exporter), [Choice C](#quick-install-with-otelcol--choice-c-both)) and run it. The script will:

- Auto-detect existing configuration and update in-place
- Install/update components as needed
- Restart services automatically

> **The install script is idempotent** — running it multiple times is safe. Already installed? It updates config. First time? It does a fresh install. No need to check current status manually.

### Step 3: If Install Fails — Troubleshoot

If the script exits with an error, check:

1. **Check current status** to understand what's already configured:

   ```bash
   openclaw config get plugins.entries
   openclaw config get diagnostics
   ```

   | Output | Status |
   |--------|--------|
   | Key exists with `"enabled": true` | **ENABLED** — component is active |
   | Key exists with `"enabled": false` | **DISABLED** — previously installed, currently off |
   | Key not present | **NOT CONFIGURED** — never installed |

2. **Common failure scenarios:**

   | Error | Cause | Solution |
   |-------|-------|----------|
   | `Node.js not found` | Node.js < 18 or missing | Install Node.js >= 18 (see [Troubleshooting](#nodejs-not-found)) |
   | `Failed to download otelcol-contrib` | No internet / OSS unreachable | Use `--otelcol-binary` with pre-downloaded file (see [Air-Gapped Setup](#manual-otelcol-contrib-setup-air-gapped-environments)) |
   | `openclaw: command not found` | OpenClaw CLI not in PATH | Gateway restart skipped; restart manually: `openclaw gateway restart` |
   | `diagnostics-otel not available` | OpenClaw < v26.2.19 | Upgrade OpenClaw to v26.2.19+ before using `--enable-otelcol` |
   | `Port already in use` | Another process on 4317/4318 | Check with `ss -tlnp \| grep 431` |
   | `Config file not found` | openclaw.json not auto-detected | Use `--config /path/to/openclaw.json` to specify manually |

3. **Config auto-detection**: The script automatically finds openclaw.json by checking (in order):
   - `--config` flag (if provided)
   - `OPENCLAW_STATE_DIR` environment variable
   - Running openclaw process user's home directory (`~/.openclaw/openclaw.json`)
   - Current user's home directory (`~/.openclaw/openclaw.json`)

   If auto-detection fails, use `--config` to specify the path explicitly.

4. **Install directory auto-detection**: The script determines the exporter install directory by checking (in order):
   - `--install-dir` flag (if provided)
   - `OPENCLAW_STATE_DIR` environment variable (`$OPENCLAW_STATE_DIR/extensions/openclaw-exporter-to-langfuse`)
   - Running openclaw process user's home directory (`~/.openclaw/extensions/openclaw-exporter-to-langfuse`)
   - Current user's home directory (`~/.openclaw/extensions/openclaw-exporter-to-langfuse`)
   - Fallback: `/opt/openclaw-exporter-to-langfuse`

   If auto-detection picks the wrong directory, use `--install-dir` to override.

5. **To uninstall first**: See [Uninstall](#uninstall) section
6. **For more issues**: See [Troubleshooting](#troubleshooting) section

---

## Prerequisites

- Node.js >= 18, npm
- OpenClaw CLI (optional — for automatic gateway restart)
- For OtelCol-Contrib: OpenClaw **>= v26.2.19** (`openclaw version` to check), Linux or macOS, internet access (or pre-downloaded binary)

> **Note**: openclaw-exporter-to-langfuse itself is **not affected** by the OpenClaw version — only the `--enable-otelcol` feature requires v26.2.19+.

---

## Part 1: Langfuse Exporter Installation (Choice A or C)

### Quick Install

#### Method 1: Using pk/sk (Recommended)

```bash
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/install.sh | sudo bash -s -- \
  --endpoint "<your-otlp-endpoint>" \
  --pk "pk-lf-xxx" \
  --sk "sk-lf-yyy" \
  --serviceName "my-service" \
  --tags "id:openclaw,ip:127.0.0.1" \
  --skill-tagging-enabled \
  --skills-roots "/opt/openclaw/skills,/opt/git/openclaw/skills/custom/skills" \
  --config "<path-to-openclaw.json>" \
  --install-dir "<path-to-install-directory>"
```

#### Method 2: Using Authorization Header

```bash
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/install.sh | sudo bash -s -- \
  --endpoint "<your-otlp-endpoint>" \
  --authorization "Basic xxx" \
  --serviceName "my-service" \
  --tags "[\"id:openclaw\",\"ip:127.0.0.1\"]" \
  --skill-tagging-enabled \
  --skills-roots "/opt/openclaw/skills,/opt/git/openclaw/skills/custom/skills" \
  --config "<path-to-openclaw.json>" \
  --install-dir "<path-to-install-directory>"
```

> **Endpoint Examples**:
> - Langfuse Cloud: `https://cloud.langfuse.com/api/public/otel/v1/traces`
> - Self-hosted Langfuse: `https://langfuse.your-company.com/api/public/otel/v1/traces`
> - HTTP (local/dev): `http://localhost:3000/api/public/otel/v1/traces`

### Getting Langfuse API Keys

1. Navigate to Langfuse Console: **Project Settings → API Keys**
2. Copy your Public Key (pk-lf-xxx) and Secret Key (sk-lf-yyy)

To manually generate Authorization header:

```bash
echo -n "pk-lf-xxx:sk-lf-yyy" | base64
# Output: cGstbGYteHh4OnNrLWxmLXl5eQ==
# Usage: --authorization "Basic cGstbGYteHh4OnNrLWxmLXl5eQ=="
```

### What the Installer Does

The installation script:

1. Downloads, extracts, and installs the exporter
2. Installs npm dependencies
3. Updates `openclaw.json` with exporter configuration

> **WARNING**: The install script will **restart the OpenClaw gateway** at the end. Active connections and in-flight requests may be interrupted. **Please confirm you want to proceed before running the install command.**

---

## Part 2: OtelCol-Contrib + ClickHouse (Choice B or C)

> **Requires OpenClaw >= v26.2.19.** The `diagnostics-otel` plugin used by this feature is not included in earlier versions. Run `openclaw version` to verify before proceeding. The Langfuse exporter (Part 1) is not affected by this requirement.

This optional feature installs and configures [otelcol-contrib](https://github.com/open-telemetry/opentelemetry-collector-contrib) to forward OpenTelemetry data (metrics, logs, traces) from OpenClaw to a ClickHouse instance.

> **Note**: The install script **automatically downloads and installs** otelcol-contrib from Alibaba Cloud OSS (accelerated mirror). No manual download is needed. For air-gapped environments, see [Manual otelcol-contrib Setup](#manual-otelcol-contrib-setup-air-gapped-environments).

**Data flow:**

```
OpenClaw (diagnostics-otel) → otelcol-contrib (localhost) → ClickHouse
OpenClaw (langfuse-exporter)  → Langfuse (separate endpoint)
```

### Quick Install with OtelCol — Choice C (Both)

```bash
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/install.sh | sudo bash -s -- \
  --endpoint "<your-langfuse-otlp-endpoint>" \
  --pk "pk-lf-xxx" \
  --sk "sk-lf-yyy" \
  --serviceName "my-service" \
  --tags "id:openclaw,ip:127.0.0.1" \
  --skill-tagging-enabled \
  --skills-roots "/opt/openclaw/skills,/opt/git/openclaw/skills/custom/skills" \
  --config "<path-to-openclaw.json>" \
  --install-dir "<path-to-install-directory>" \
  --enable-otelcol \
  --ck-endpoint "http://<clickhouse-host>:8123" \
  --ck-username "default" \
  --ck-password "your-password"
```

> **WARNING**: This command will:
> 1. Install otelcol-contrib (may require elevated privileges on Linux)
> 2. Write `/etc/otelcol-contrib/config.yaml` (backs up existing config)
> 3. Restart the `otelcol-contrib` service
> 4. Restart the OpenClaw gateway
>
> **Active connections and in-flight requests may be interrupted. Please confirm you want to proceed before running this command.**

### OtelCol-only Install — Choice B (skip Langfuse exporter)

If you only need otelcol-contrib + ClickHouse forwarding without the Langfuse exporter:

```bash
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/install.sh | sudo bash -s -- \
  --serviceName "my-service" \
  --config "<path-to-openclaw.json>" \
  --skip-plugin \
  --enable-otelcol \
  --ck-endpoint "http://<clickhouse-host>:8123" \
  --ck-username "default" \
  --ck-password "your-password"
```

> **Note**: `--endpoint` is **not required** for Choice B since no Langfuse exporter is installed.
>
> **WARNING**: This command will restart the `otelcol-contrib` service and the OpenClaw gateway. **Please confirm you want to proceed before running this command.**

### diagnostics-otel Parameters

These control what OpenClaw sends to the local otelcol-contrib (included in the tables above):

| Parameter | Default | Description |
|----------|---------|-------------|
| `--diag-traces` | `false` | Enable traces (default off — Langfuse exporter handles traces) |
| `--diag-logs` | `true` | Enable logs |
| `--diag-metrics` | `true` | Enable metrics |

### What OtelCol Install Does

When `--enable-otelcol` is passed, the script additionally:

1. **Downloads and installs otelcol-contrib** — auto-detects OS/arch and package format (RPM/DEB/tar.gz), downloads from OSS
2. **Generates `/etc/otelcol-contrib/config.yaml`** — configures OTLP receivers and ClickHouse exporter
3. **Starts/restarts the otelcol-contrib service**
4. **Locates and configures `diagnostics-otel`** — points it to the local otelcol-contrib HTTP endpoint
5. **Updates `openclaw.json`** — enables diagnostics-otel with configured traces/logs/metrics settings

### Manual otelcol-contrib Setup (Air-Gapped Environments)

In air-gapped environments where the installer cannot reach OSS, you can pre-download otelcol-contrib and pass it via `--otelcol-binary`.

1. **Find your platform package:**

   | Source | URL | Note |
   |--------|-----|------|
   | **OSS (accelerated)** | `https://<oss-host>/opentelemetry-collector-releases/` | Recommended for China mainland |
   | **GitHub (backup)** | `https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.136.0` | Fallback if OSS is unavailable |

2. **Download examples (OSS):**

   ```bash
   # Linux (amd64, RPM)
   wget -O otelcol-contrib.rpm https://<oss-host>/opentelemetry-collector-releases/otelcol-contrib_0.136.0_linux_amd64.rpm

   # Linux (amd64, DEB)
   wget -O otelcol-contrib.deb https://<oss-host>/opentelemetry-collector-releases/otelcol-contrib_0.136.0_linux_amd64.deb

   # macOS (arm64)
   wget -O otelcol-contrib.tar.gz https://<oss-host>/opentelemetry-collector-releases/otelcol-contrib_0.136.0_darwin_arm64.tar.gz
   ```

   <details><summary>GitHub backup URLs</summary>

   ```bash
   # Linux (amd64, RPM)
   wget -O otelcol-contrib.rpm https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.136.0/otelcol-contrib_0.136.0_linux_amd64.rpm

   # Linux (amd64, DEB)
   wget -O otelcol-contrib.deb https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.136.0/otelcol-contrib_0.136.0_linux_amd64.deb

   # macOS (arm64)
   wget -O otelcol-contrib.tar.gz https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.136.0/otelcol-contrib_0.136.0_darwin_arm64.tar.gz
   ```

   </details>

3. **Verify checksum:**

   ```bash
   # Download checksums (OSS)
   wget https://<oss-host>/opentelemetry-collector-releases/opentelemetry-collector-releases_otelcol-contrib_checksums.txt
   # Or from GitHub:
   # wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.136.0/opentelemetry-collector-releases_otelcol-contrib_checksums.txt

   # Verify
   sha256sum -c opentelemetry-collector-releases_otelcol-contrib_checksums.txt --ignore-missing
   ```

4. **Re-run installer with `--otelcol-binary`:**

   ```bash
   curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/install.sh | sudo bash -s -- \
     --endpoint "..." --pk "..." --sk "..." --serviceName "..." \
     --enable-otelcol \
     --ck-endpoint "http://<ck-host>:8123" \
     --ck-password "password" \
     --otelcol-binary ./otelcol-contrib.rpm
   ```

### otelcol-contrib config.yaml Reference

The installer generates the following config at `/etc/otelcol-contrib/config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 5s
    send_batch_size: 5000
exporters:
  clickhouse:
    endpoint: http://<ck-host>:8123?dial_timeout=10s&compress=lz4&async_insert=1
    username: default
    password: <your-password>
    traces_table_name: otel_traces
    logs_table_name: otel_logs
    metrics_tables:
      gauge:
        name: otel_metrics_gauge
      sum:
        name: otel_metrics_sum
      summary:
        name: otel_metrics_summary
      histogram:
        name: otel_metrics_histogram
      exponential_histogram:
        name: otel_metrics_exp_histogram
    create_schema: true
    timeout: 5s
    database: clickobserve_service
    sending_queue:
      queue_size: 1000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouse]
```

### openclaw.json Configuration Example (with OtelCol)

```json
{
  "plugins": {
    "allow": ["openclaw-exporter-to-langfuse", "diagnostics-otel"],
    "load": {
      "paths": ["/path/to/openclaw-exporter-to-langfuse"]
    },
    "entries": {
      "openclaw-exporter-to-langfuse": {
        "enabled": true,
        "config": {
          "endpoint": "<your-langfuse-otlp-endpoint>",
          "headers": {
            "Authorization": "Basic xxx"
          },
          "serviceName": "my-service",
          "tags": ["id:openclaw", "ip:127.0.0.1"],
          "debug": false,
          "skillTaggingEnabled": false
        }
      },
      "diagnostics-otel": {
        "enabled": true
      }
    }
  },
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "endpoint": "http://localhost:4318",
      "protocol": "http/protobuf",
      "serviceName": "my-service",
      "metrics": true,
      "traces": false,
      "logs": true
    }
  }
}
```

`skillTaggingEnabled` defaults to `false`. Set it to `true` if you want `skill:*` tags on tool observations in Langfuse.
`tags` is optional. When configured, it is written to `langfuse.tags` on the trace root span only.

---

## Uninstall

The uninstall script supports selective uninstall of components:

| Component | Default | Flag to change |
|-----------|---------|----------------|
| openclaw-exporter-to-langfuse | **Uninstalled** (removes files + config) | `--skip-plugin` to skip |
| otelcol-contrib | **Not touched** (preserved) | `--stop-otelcol` to stop service |

### Quick Uninstall (exporter only)

> **WARNING**: Uninstalling will **restart the OpenClaw gateway**. Active connections and in-flight requests may be interrupted. **Please confirm you want to proceed before running this command.**

```bash
sudo -v
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/uninstall.sh | sudo bash
```

### Uninstall exporter + stop otelcol-contrib

> **WARNING**: This will uninstall the exporter, stop otelcol-contrib, and restart the gateway. **Please confirm before executing.**

```bash
sudo -v
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/uninstall.sh | sudo bash -s -- -y --stop-otelcol
```

### Stop otelcol-contrib only (keep exporter)

> **WARNING**: This will stop the otelcol-contrib service and disable diagnostics-otel. Data forwarding to ClickHouse will stop. **Please confirm before executing.**

```bash
sudo -v
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/uninstall.sh | sudo bash -s -- -y --skip-plugin --stop-otelcol
```

### Uninstall with Options

```bash
# Skip confirmation
sudo -v
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/uninstall.sh | sudo bash -s -- -y

# Custom install directory
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/uninstall.sh | sudo bash -s -- --install-dir /path/to/exporter -y
```

### Uninstall Parameters

| Parameter | Description |
|-----------|-------------|
| `-y` / `--yes` | Skip confirmation prompt |
| `--install-dir` | Specify plugin directory (auto-detected if not provided) |
| `--skip-plugin` | Skip openclaw-exporter-to-langfuse uninstall |
| `--stop-otelcol` | Stop otelcol-contrib service (binary and config are preserved) |
| `--oss-host` | Full OSS hostname for fetching the version-specific uninstall script (default: `ck-langfuse-public.oss-cn-beijing.aliyuncs.com`) |

### What Uninstall Does

By default, uninstall cleans up `openclaw-exporter-to-langfuse`:

- Removes entries from `plugins.allow` and `plugins.entries`
- Deletes the `openclaw-exporter-to-langfuse` directory

With `--stop-otelcol`:

- Stops the otelcol-contrib service
- Disables `diagnostics-otel` in `openclaw.json` (keeps config for easy re-enable)
- **Does NOT remove** otelcol-contrib binary or `/etc/otelcol-contrib/config.yaml`

> **Note**: To fully remove otelcol-contrib, use your system package manager (e.g., `yum remove otelcol-contrib` or `apt remove otelcol-contrib`).

---

## Manual Installation

If you prefer manual installation:

```bash
# 1. Download and extract
curl -fsSL https://<oss-host>/openclaw-exporter-to-langfuse/{{EXPORTER_VERSION}}/openclaw-exporter-to-langfuse.tar.gz | tar xz
cd openclaw-exporter-to-langfuse

# 2. Install dependencies
npm install --omit=dev

# 3. Configure in openclaw.json (see example below)
```

## openclaw.json Configuration Example (Langfuse only)

```json
{
  "plugins": {
    "allow": ["openclaw-exporter-to-langfuse"],
    "load": {
      "paths": ["/path/to/openclaw-exporter-to-langfuse"]
    },
    "entries": {
      "openclaw-exporter-to-langfuse": {
        "enabled": true,
        "config": {
          "endpoint": "<your-otlp-endpoint>",
          "headers": {
            "Authorization": "Basic xxx"
          },
          "serviceName": "my-service",
          "tags": ["id:openclaw", "ip:127.0.0.1"],
          "debug": false,
          "skillTaggingEnabled": false
        }
      }
    }
  }
}
```

## Reported Spans

The exporter reports spans following [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/):

| Span | gen_ai.span.kind | Description |
|------|----------------|-------------|
| `enter_openclaw_system` | ENTRY | Request entry |
| `invoke_agent` | AGENT | Agent invocation |
| `chat` | LLM | LLM call |
| `execute_tool` | TOOL | Tool execution |
| `session_start` / `session_end` | — | Session lifecycle |
| `gateway_start` / `gateway_stop` | — | Gateway lifecycle |

## Troubleshooting

### Gateway restart fails

> **WARNING**: This will restart the OpenClaw gateway. Active connections may be interrupted. **Please confirm before executing.**

If automatic gateway restart fails, run manually:

```bash
openclaw gateway restart
```

### otelcol-contrib service not starting

Check service status and logs:

```bash
# Check service status
systemctl status otelcol-contrib

# View logs
journalctl -u otelcol-contrib -f
```

Common issues:
- **Port already in use**: Another process is using port 4317 or 4318. Check with `ss -tlnp | grep 431`
- **Config syntax error**: Validate config with `otelcol-contrib validate --config=/etc/otelcol-contrib/config.yaml`
- **ClickHouse unreachable**: Verify connectivity with `curl http://<ck-host>:8123`

### otelcol-contrib download fails (no internet)

See [Manual otelcol-contrib Setup](#manual-otelcol-contrib-setup-air-gapped-environments) above for offline installation.

> **WARNING**: Restarting otelcol-contrib may briefly interrupt data forwarding to ClickHouse. **Please confirm before executing.**

```bash
# After manual install, restart the service
service otelcol-contrib restart
```

### Node.js not found

Install Node.js >= 18:

```bash
# Using nvm
nvm install 18
nvm use 18

# Or via package manager
# macOS: brew install node@18
# Ubuntu: curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt install nodejs
```

## Support

For issues and feature requests, please open an issue in the project repository.

**DingTalk Group**: 180485008966
