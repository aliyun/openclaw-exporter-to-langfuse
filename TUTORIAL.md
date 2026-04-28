# OpenClaw Exporter to Langfuse — How It Works

<!-- LANGUAGE_SELECTOR_START -->
**English** | [中文](./TUTORIAL.zh.md)
<!-- LANGUAGE_SELECTOR_END -->

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Core Concepts](#2-core-concepts)
3. [End-to-End Data Flow](#3-end-to-end-data-flow)
4. [Hook Mechanism](#4-hook-mechanism)
5. [Trace Context Management](#5-trace-context-management)
6. [Span Hierarchy Tree](#6-span-hierarchy-tree)
7. [LangfuseExporter Internals](#7-langfuseexporter-internals)
8. [Segmented LLM Span Mechanism](#8-segmented-llm-span-mechanism)
9. [Tool Call Pipeline](#9-tool-call-pipeline)
10. [Concurrency and Async Task Queue](#10-concurrency-and-async-task-queue)
11. [Configuration and Initialization](#11-configuration-and-initialization)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        OpenClaw Gateway                              │
│                                                                      │
│  ┌────────────┐    ┌──────────────────────────────┐    ┌───────────┐│
│  │ User Msg   │───→│  Agent Execution Engine       │───→│ LLM Call  ││
│  └────────────┘    │  (triggers various Hooks)     │    └───────────┘│
│                    └──────────┬─────────────────────┘                │
│                               │                                      │
│                               ▼                                      │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │               openclaw-exporter-to-langfuse (this exporter)             ││
│  │                                                                  ││
│  │  ┌──────────────────┐    ┌──────────────────────────────────┐   ││
│  │  │  Hook Layer       │    │  TraceContext In-Memory Store    │   ││
│  │  │  (11 Hooks)       │    │  - contextByChannelId           │   ││
│  │  │                   │    │  - contextByRunId               │   ││
│  │  │  message_received │    │  - contextsByChannelId          │   ││
│  │  │  llm_input        │    │  - pendingToolCalls             │   ││
│  │  │  llm_output       │    │  - traceTaskQueueByTraceId      │   ││
│  │  │  before_tool_call │    │  - pendingAssistantByTraceId    │   ││
│  │  │  after_tool_call  │    │  - ...                          │   ││
│  │  │  agent_end        │    └──────────────────────────────────┘   ││
│  │  │  ...              │                                           ││
│  │  └──────────────────┘    ┌──────────────────────────────────┐   ││
│  │            │              │  LangfuseExporter                │   ││
│  │            ▼              │  - openSpans: Map<spanId, Span>  │   ││
│  │  ┌──────────────────┐    │  - BasicTracerProvider           │   ││
│  │  │  createSpan()    │    │    └── BatchSpanProcessor        │   ││
│  │  │  export()        │    │         └── OTLPTraceExporter    │   ││
│  │  │  startSpan()     │    │              │                    │   ││
│  │  │  endSpanById()   │    │              ▼                    │   ││
│  │  └──────────────────┘    │        HTTP POST → Langfuse      │   ││
│  │                          └──────────────────────────────────┘   ││
│  └──────────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────┘
```

**Core workflow**:
1. OpenClaw fires various Hooks during execution
2. The exporter intercepts Hooks and creates/updates Span data
3. LangfuseExporter batches spans to Langfuse via the OpenTelemetry SDK
4. Langfuse receives OTLP data and renders the Trace visualization

---

## 2. Core Concepts

### 2.1 Trace

A Trace represents one complete user interaction — from the moment a user sends a message to the final AI reply.

```typescript
interface TraceContext {
  traceId: string;          // 32-char hex, uniquely identifies a Trace
  rootSpanId: string;       // Root Span ID
  runId: string;            // Run ID (may be re-bound from a temporary ID to a stable one)
  turnId: string;           // Turn ID
  channelId: string;        // Channel identifier (e.g. "user/123", "agent/abc")
  sessionId?: string;       // Session ID
  createdAt: number;        // Creation timestamp

  userInput?: unknown;      // User input content
  lastOutput?: unknown;     // Last output content
  // ... more fields
}
```

### 2.2 Span

A Span is a single node within a Trace representing one operation unit. Spans have parent-child relationships forming a tree.

```typescript
interface SpanData {
  name: string;             // Span name (e.g. "chat claude-3.5")
  type: SpanType;           // Type (entry/model/tool/agent/step etc.)
  startTime: number;        // Start time (ms timestamp)
  endTime?: number;         // End time
  attributes: Record<string, string | number | boolean>;  // Attributes
  input?: unknown;          // Input data
  output?: unknown;         // Output data
  parentSpanId?: string;    // Parent Span ID
  traceId?: string;         // Owning Trace ID
  spanId?: string;          // Span ID
}
```

### 2.3 Span Types

| Type | Description | Lifecycle | Corresponding Hook |
|------|-------------|-----------|-------------------|
| `entry` | Entry (root Span) | Long-lived | Created by `message_received`, closed by `agent_end` |
| `agent` | Agent execution | Long-lived | Created by `before_agent_start`, closed by `agent_end` |
| `step` | React round (LLM + tool call group) | Long-lived | Created by `llm_input`, closed by `after_tool_call`/`before_message_write` |
| `model` | LLM call | Short-lived | Exported by `before_message_write`/`llm_output` |
| `tool` | Tool call | Short-lived | Recorded by `before_tool_call`, exported by `after_tool_call` |
| `session` | Session event | Short-lived | Exported by `session_start`/`session_end` |
| `gateway` | Gateway node | Short-lived | Exported by `gateway_start` |

---

## 3. End-to-End Data Flow

### 3.1 A Complete Conversation Span Tree

```
User: "What's the weather like in Beijing today?"

enter_openclaw_system (root, entry)          ← message_received
  └── invoke_agent weather-agent (agent)     ← before_agent_start
        └── react step (step #1)             ← llm_input
              ├── chat claude-3.5 (model)    ← before_message_write
              │    [LLM decides to call get_weather]
              └── execute_tool get_weather (tool)  ← after_tool_call
        └── react step (step #2)             ← after_tool_call creates new step
              └── chat claude-3.5 (model)    ← before_message_write
                   [LLM generates final answer]
```

### 3.2 Data Flow

```
Hook fires
    │
    ▼
┌─────────────────────────┐
│ getOrCreateContext()    │  ← Get or create TraceContext
│ (look up existing ctx   │
│  by channelId/runId)    │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ createSpan()            │  ← Build SpanData object
│ (populate attributes,   │
│  input/output, parent)  │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ LangfuseExporter        │
│ .export() / .startSpan()│  ← Call OpenTelemetry Tracer
│ / .endSpanById()        │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ BasicTracerProvider     │
│   └── BatchSpanProcessor│  ← Batch processing queue
│         (max 10 spans   │
│          OR every 5s)   │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ OTLPTraceExporter       │  ← Serialize to Protobuf
│ HTTP POST → Langfuse    │  ← With Authorization header
│ /v1/traces              │
└─────────────────────────┘
```

---

## 4. Hook Mechanism

### 4.1 Hook Registration

The exporter registers 11 Hooks in `activate()`:

```typescript
// src/index.ts line 372
activate(api: OpenClawPluginApi) {
  // Read config
  const config: LangfuseTraceConfig = {
    endpoint: pluginConfig.endpoint,
    headers: pluginConfig.headers,
    serviceName: pluginConfig.serviceName || "openclaw-agent",
    debug: pluginConfig.debug || false,
    batchSize: pluginConfig.batchSize || 10,
    flushIntervalMs: pluginConfig.flushIntervalMs || 5000,
    enabledHooks: pluginConfig.enabledHooks,  // optional whitelist
  };
  const skillTaggingEnabled = pluginConfig.skillTaggingEnabled === true; // default false

  // Create Exporter
  const exporter = new LangfuseExporter(api, config);

  // Register Hooks (partial example)
  if (shouldHookEnabled("message_received")) {
    api.on("message_received", async (event, hookCtx) => {
      // handling logic...
    });
  }
  // ... other Hooks
}
```

### 4.2 Hook Execution Timeline

Example of an Agent call with tool usage:

```
Timeline:

T0   message_received     → User message arrives
     ├── Create TraceContext
     ├── Create entry Span (root)
     └── Record userInput

T1   before_agent_start   → Agent begins execution
     ├── Ensure entry Span exists (idempotent)
     └── Create agent Span

T2   llm_input            → LLM is called
     ├── Create step Span (react round #1)
     ├── Record LLM provider, model, input messages
     └── Set llmPendingStartTime

T3   before_message_write → LLM returns assistant message (contains tool_call)
     ├── Extract tool_calls and text content
     ├── Export model Span (LLM call #1)
     └── step remains open (waiting for tool results)

T4   before_tool_call     → Tool call starts
     └── Record pendingToolCall (toolName, toolCallId, startTime)

T5   after_tool_call      → Tool call ends
     ├── Match pendingToolCall
     ├── Export tool Span
     ├── Record tool result
     ├── When all tools are done:
     │   ├── Close current step Span
     │   ├── Create new step Span (react round #2)
     │   └── Prepare next LLM input messages

T6   llm_input            → Second LLM call
     ├── Update llmPendingStartTime
     └── Record input messages (including tool results)

T7   before_message_write → LLM returns final answer (plain text)
     ├── Export model Span (LLM call #2)
     └── Close step Span (no more tool_calls)

T8   llm_output           → LLM call complete
     └── Compatibility fallback (if before_message_write did not fire)

T9   agent_end            → Agent execution ends
     ├── Close remaining step Spans
     ├── After 100ms delay:
     │   ├── Supplement agent Span attributes (output, usage)
     │   ├── Close agent Span
     │   ├── Supplement root Span attributes (input, output)
     │   ├── Close root Span
     │   └── flush() → Force-send all Spans
     └── Clean up TraceContext
```

---

## 5. Trace Context Management

### 5.1 Multi-Map Index Structure

The exporter uses multiple Maps for efficient TraceContext lookup and management:

```typescript
// src/index.ts line 404-410
const contextByChannelId = new Map<string, TraceContext>();          // channelId → Context
const contextByRunId = new Map<string, TraceContext>();              // runId → Context
const contextsByChannelId = new Map<string, Set<TraceContext>>();    // channelId → multiple Contexts (concurrent)
const activeContextByAgentChannel = new Map<string, TraceContext>(); // agent channel → Context
const pendingToolCalls = new Map<string, PendingToolCall>();         // toolCallKey → PendingToolCall
const traceTaskQueueByTraceId = new Map<string, Promise<void>>();    // traceId → task queue
const pendingAssistantByTraceId = new Map<string, PendingAssistantMessage>();
```

### 5.2 Context Lookup Logic

```typescript
const getOrCreateContext = (rawChannelId, runId, hookName) => {
  // 1. Look up by channelId first
  let activeCtx = getContextByChannel(rawChannelId);

  // 2. For agent channels, try to find the bound user context
  if (rawChannelId.startsWith("agent/") && effectiveRunId) {
    const originalChannelId = getOriginalChannelId(effectiveRunId);
    if (originalChannelId) {
      activeCtx = getContextByChannel(originalChannelId) || activeCtx;
    }
  }

  // 3. Look up by runId
  if (!activeCtx) {
    activeCtx = getContextByRun(effectiveRunId);
  }

  // 4. For agent channels without context, try linking the most recent user context
  if (!activeCtx && canLinkRecentUserContext()) {
    activeCtx = linkRecentUserContext();
  }

  // 5. If none found, create a new Trace
  if (!activeCtx) {
    activeCtx = startTurn(effectiveRunId, channelId);
    isNew = true;
  }

  return { ctx: activeCtx, channelId, isNew };
};
```

### 5.3 Run ID Re-binding

OpenClaw may initially use a temporary runId (e.g. `run-1234567890`), providing a stable ID later. The exporter automatically re-binds:

```typescript
const bindRealRunId = (ctx, runId, hookName) => {
  const realRunId = resolveOptionalRunId(runId);
  if (!realRunId || ctx.runId === realRunId) return;

  // Skip if already bound to a stable ID
  if (!isTemporaryRunId(ctx.runId)) return;

  // Remap
  contextByRunId.delete(ctx.runId);
  ctx.runId = realRunId;
  ctx.turnId = realRunId;
  contextByRunId.set(realRunId, ctx);

  // Update attributes on already-exported Spans
  const rebindAttrs = {
    "openclaw.run.id": realRunId,
    "openclaw.turn.id": realRunId,
  };
  exporter.patchOpenSpanAttributes(ctx.rootSpanId, rebindAttrs);
  if (ctx.agentSpanId) {
    exporter.patchOpenSpanAttributes(ctx.agentSpanId, rebindAttrs);
  }
};
```

### 5.4 Stale Context Cleanup

```typescript
const sweepStaleContexts = () => {
  const now = Date.now();
  // Clean up contexts older than 20 minutes
  for (const [key, ctx] of contextByChannelId) {
    if (now - ctx.createdAt > CONTEXT_MAX_AGE_MS) {  // 20 minutes
      contextByChannelId.delete(key);
      contextByRunId.delete(ctx.runId);
    }
  }
  // Clean up pending assistant messages older than 15 seconds
  for (const [traceId, pending] of pendingAssistantByTraceId) {
    if (now - pending.createdAt > PENDING_ASSISTANT_TTL_MS) {  // 15 seconds
      pendingAssistantByTraceId.delete(traceId);
    }
  }
};
// Runs every 10 minutes
setInterval(sweepStaleContexts, CONTEXT_SWEEP_INTERVAL_MS);
```

---

## 6. Span Hierarchy Tree

### 6.1 Parent-Child Resolution

```typescript
// Root Span has no parentSpanId (undefined by default)
// Agent Span's parentSpanId = ctx.rootSpanId
// Step Span's parentSpanId = ctx.agentSpanId || ctx.rootSpanId
// LLM/Tool Span's parentSpanId = ctx.stepSpanId || ctx.agentSpanId || ctx.rootSpanId

const resolveAgentFirstParentSpanId = (ctx) =>
  ctx.agentSpanId || ctx.rootSpanId;

const resolveStepFirstParentSpanId = (ctx) =>
  ctx.stepSpanId || ctx.agentSpanId || ctx.rootSpanId;
```

### 6.2 Span Creation Example

```typescript
const createSpan = (ctx, channelId, name, type, startTime, endTime, attributes) => {
  return {
    name,
    type,
    startTime,
    endTime,
    attributes: {
      ...attributes,
      "openclaw.version": openclawVersion,
      "openclaw.session.id": sessionId,
      "gen_ai.session.id": sessionId,
      "langfuse.session.id": sessionId,       // Langfuse-specific attribute
      "openclaw.run.id": ctx.runId,
      "openclaw.turn.id": ctx.turnId,
    },
    traceId: ctx.traceId,
    spanId: generateId(16),
    parentSpanId: parentSpanId || ctx.rootSpanId,  // Default parent is root
  };
};
```

---

## 7. LangfuseExporter Internals

### 7.1 Initialization

```typescript
// src/langfuse-exporter.ts line 60-103
private async initialize(): Promise<void> {
  // 1. Create Resource (service identity)
  const resource = resourceFromAttributes({
    [ATTR_SERVICE_NAME]: this.config.serviceName,
    "service.instance.id": `${instanceName}@${hostname()}:${process.pid}`,
    "host.name": hostname(),
    "telemetry.sdk.language": "nodejs",
  });

  // 2. Create OTLP Exporter (with Authorization header)
  const exporter = new OTLPTraceExporter({
    url: traceUrl,  // endpoint + "/v1/traces"
    headers: {
      ...this.config.headers,
      "x-langfuse-ingestion-version": "4",  // Langfuse-specific header
    },
  });

  // 3. Create BatchSpanProcessor (batched processing)
  const spanProcessor = new BatchSpanProcessor(exporter, {
    maxQueueSize: 100,                  // Buffer up to 100 spans
    maxExportBatchSize: this.config.batchSize,       // Send when 10 spans buffered
    scheduledDelayMillis: this.config.flushIntervalMs, // Or send every 5 seconds
  });

  // 4. Create BasicTracerProvider (not registered globally to avoid conflicts)
  this.provider = new BasicTracerProvider({
    resource,
    spanProcessors: [spanProcessor],
  });

  // 5. Get Tracer (without calling .register())
  this.tracer = this.provider.getTracer("openclaw-exporter-to-langfuse", PLUGIN_VERSION);
}
```

### 7.2 Two Export Modes

#### Mode 1: `export()` — Fire-and-Forget (Short-lived)

Applies to: LLM span, Tool span, Session span

```typescript
async export(spanData: SpanData): Promise<void> {
  // 1. Create Span
  const span = this.tracer.startSpan(spanData.name, {
    kind: spanKind,
    startTime: spanData.startTime,
    attributes: exportSpanAttrs,
  }, parentContext);

  // 2. Set status
  span.setStatus({ code: hasError ? SpanStatusCode.ERROR : SpanStatusCode.OK });

  // 3. End immediately (automatically enters BatchSpanProcessor queue)
  span.end(spanData.endTime || Date.now());

  // Note: span is NOT stored in openSpans — create → close → enqueue in one shot
}
```

#### Mode 2: `startSpan()` + `endSpanById()` — Long-lived

Applies to: Root span, Agent span, Step span

```typescript
// Open a Span
async startSpan(spanData: SpanData, spanId: string): Promise<void> {
  const span = this.tracer.startSpan(spanData.name, {
    kind: spanKind,
    startTime: spanData.startTime,
    attributes: spanAttrs,
  }, parentContext);

  this.openSpans.set(spanId, span);  // ← Store in Map, keep alive
}

// Dynamically patch attributes later
patchOpenSpanAttributes(spanId: string, attrs: Record<string, ...>): void {
  const span = this.openSpans.get(spanId);
  if (!span) return;
  for (const [key, value] of Object.entries(attrs)) {
    span.setAttribute(key, value);
  }
}

// Close the Span
endSpanById(spanId: string, endTime: number, additionalAttrs?): void {
  const span = this.openSpans.get(spanId);
  if (!span) return;

  // Add final attributes
  if (additionalAttrs) {
    for (const [key, value] of Object.entries(additionalAttrs)) {
      span.setAttribute(key, value);
    }
  }

  span.setStatus({ code: SpanStatusCode.OK });
  span.end(endTime || Date.now());    // ← Closing auto-enqueues
  this.openSpans.delete(spanId);      // ← Remove from Map
}
```

### 7.3 Batch Export Mechanism

```
Span enters queue
    │
    ▼
┌─────────────────────────┐
│  BatchSpanProcessor     │
│                         │
│  Queue (max 100 spans)  │
│                         │
│  Trigger conditions     │
│  (any one met):         │
│  1. 10 spans buffered   │
│  2. 5 seconds elapsed   │
│  3. Manual flush() call │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  OTLPTraceExporter      │
│  Serialize to Protobuf  │
│  HTTP POST → Langfuse   │
│  /api/public/otel/v1/   │
│  traces                 │
└─────────────────────────┘
```

### 7.4 Parent Span Context Resolution

Since global `.register()` is not called, parent-child relationships must be managed manually:

```typescript
private resolveParentContext(parentSpanId?: string) {
  if (parentSpanId) {
    const parentSpan = this.openSpans.get(parentSpanId);
    if (parentSpan) {
      // Look up parent Span via the openSpans Map
      return trace.setSpan(context.active(), parentSpan);
    }
  }
  return context.active();
}
```

---

## 8. Segmented LLM Span Mechanism

### 8.1 Why Segmentation?

In multi-round React loops, the LLM is called multiple times (once before and after each tool call):

```
Without segmentation (old approach):
  One LLM span covers all rounds → cannot distinguish per-round timing/input/output

Segmented approach:
  Each LLM call → independent LLM span → clear per-round visibility
```

### 8.2 Segmentation Implementation

```typescript
const exportPendingLlmSpan = async (ctx, channelId, params) => {
  // 1. Calculate timing
  const startTime = ctx.llmPendingStartTime;  // from llm_input
  const safeEndTime = params.endTime;          // from before_message_write

  // 2. Build attributes (including usage/tokens)
  const llmAttrs = {
    "gen_ai.operation.name": "chat",
    "gen_ai.provider.name": ctx.llmProvider,
    "gen_ai.request.model": ctx.llmModel,
    "gen_ai.usage.input_tokens": params.usage?.input ?? 0,
    "gen_ai.usage.output_tokens": params.usage?.output ?? 0,
    "gen_ai.usage.total_tokens": totalTokens,
    "langfuse.observation.input": ctx.llmPendingInputMessages,
    "langfuse.observation.output": formatOutputMessages(params.outputTexts),
  };

  // 3. Create and export the Span
  const span = createSpan(ctx, channelId, `chat ${model}`, "model",
    startTime, safeEndTime, llmAttrs,
    undefined, undefined, resolveStepFirstParentSpanId(ctx));

  await exporter.export(span);  // ← fire-and-forget

  // 4. Increment counter
  ctx.llmSegmentCount += 1;
};
```

### 8.3 Role of `llmSegmentCount`

```typescript
// Compatibility fallback in llm_output
if (ctx.llmSegmentCount === 0 && ctx.llmPendingStartTime) {
  // Only runs if before_message_write did not fire
  await exportPendingLlmSpan(ctx, channelId, { endTime, usage: event.usage });
}
```

- `llmSegmentCount === 0` → No segments exported yet; use `llm_output` as fallback
- `llmSegmentCount > 0` → Already exported via `before_message_write`; skip

---

## 9. Tool Call Pipeline

### 9.1 Tool Call Lifecycle

```
before_tool_call                     after_tool_call
     │                                    │
     ▼                                    ▼
Record pendingToolCall              Match pendingToolCall
(toolName, toolCallId,              Export tool Span
 startTime, params)                 Record tool result
                                    Check if all tools are done
                                          │
                                          ▼
                                    If all done:
                                      - Close current step
                                      - Create new step
                                      - Prepare next LLM input
```

### 9.2 Tool Matching Logic

```typescript
const consumePendingToolCall = (event: AfterToolCallEvent) => {
  // 1. Exact match (toolCallId + runId)
  const directKey = buildPendingToolCallKey(eventToolCallId, eventRunId);
  const direct = pendingToolCalls.get(directKey);
  if (direct) {
    pendingToolCalls.delete(directKey);
    return direct;
  }

  // 2. Fallback match (toolName + runId, latest by time)
  let fallback: PendingToolCall | undefined;
  for (const [key, pending] of pendingToolCalls) {
    if (pending.toolName !== event.toolName) continue;
    if (eventRunId && pending.runId !== eventRunId) continue;
    if (!fallback || pending.toolStartTime > fallback.toolStartTime) {
      fallback = pending;
      fallbackKey = key;
    }
  }
  return fallback;
};
```

### 9.3 Multi-Tool Batch Processing

When the LLM invokes multiple tools at once:

```typescript
// Inside after_tool_call
if (hadWaitingTools) {
  // Remove current tool from the waiting set
  traceContext.llmPendingToolCallIds.delete(toolCallId);

  // Check if all tools are done
  const toolBatchFinished =
    traceContext.llmPendingToolCallIds.size === 0 &&
    traceContext.llmPendingToolCallCountFallback === 0;

  if (toolBatchFinished) {
    // Close current step
    endStepSpan(traceContext, now, "toolUse", channelId);

    // Create new step (next LLM round)
    traceContext.llmPendingStartTime = now;
    await ensureStepSpan(traceContext, channelId, now);

    // Prepare input messages (with all tool results)
    traceContext.llmPendingInputMessages = formatInputMessages(nextInputHistory);
  }
}
```

---

## 10. Concurrency and Async Task Queue

### 10.1 Why a Task Queue?

Hooks may arrive out of order (e.g. `before_message_write` arriving before `llm_input`). The task queue ensures operations on the same trace execute sequentially:

```typescript
const enqueueTraceTask = (traceId: string, task: () => Promise<void>): Promise<void> => {
  const prev = traceTaskQueueByTraceId.get(traceId) || Promise.resolve();
  const next = prev.catch(() => undefined).then(task);  // ← Chained execution

  const tracked = next.finally(() => {
    if (traceTaskQueueByTraceId.get(traceId) === tracked) {
      traceTaskQueueByTraceId.delete(traceId);  // ← Queue done, clean up
    }
  });

  traceTaskQueueByTraceId.set(traceId, tracked);
  return tracked;
};
```

### 10.2 Usage Examples

```typescript
// Async export in before_message_write
void enqueueTraceTask(ctx.traceId, async () => {
  await processAssistantMessageForContext(ctx, channelId, message);
}).catch((err) => {
  api.logger.warn(`before_message_write segmented export failed: ${err}`);
});

// Wait for all queued tasks in agent_end
await drainTraceTasks(ctx.traceId);  // ← Ensure all async tasks complete before closing spans
```

### 10.3 Pending Assistant Buffer

When `before_message_write` arrives before `llm_input`, the message is buffered:

```typescript
if (!ctx.hasSeenLlmInput) {
  // Buffer the message; process when llm_input arrives
  pendingAssistantByTraceId.set(ctx.traceId, { message, createdAt: Date.now() });
  return;
}

// In llm_input, check and process buffered messages
const pendingAssistant = pendingAssistantByTraceId.get(ctx.traceId);
if (pendingAssistant) {
  pendingAssistantByTraceId.delete(ctx.traceId);
  void enqueueTraceTask(ctx.traceId, async () => {
    await processAssistantMessageForContext(ctx, channelId, pendingAssistant.message);
  });
}
```

---

## 11. Configuration and Initialization

### 11.1 Plugin Configuration

```json
// In openclaw.json
{
  "plugins": {
    "openclaw-exporter-to-langfuse": {
      "enabled": true,
      "config": {
        "endpoint": "http://langfuse-server:3000/api/public/otel",
        "headers": {
          "Authorization": "Basic base64(pk-xxx:sk-xxx)"
        },
        "serviceName": "openclaw-agent",
        "tags": ["id:openclaw", "ip:127.0.0.1"],
        "debug": false,
        "skillTaggingEnabled": false,
        "batchSize": 10,
        "flushIntervalMs": 5000,
        "enabledHooks": [
          "message_received",
          "llm_input",
          "llm_output",
          "before_message_write",
          "before_tool_call",
          "after_tool_call",
          "before_agent_start",
          "agent_end"
        ]
      }
    }
  }
}
```

### 11.2 Langfuse OTLP Endpoint

```typescript
private resolveTraceUrl(): string {
  const endpoint = this.config.endpoint.replace(/\/+$/, "");
  // Auto-append /v1/traces
  if (/\/v1\/traces$/i.test(endpoint)) {
    return endpoint;
  }
  return `${endpoint}/v1/traces`;
}
```

### 11.3 Langfuse-Specific Attributes

| Attribute | Description | Set On |
|-----------|-------------|--------|
| `langfuse.session.id` | Session ID | All Spans |
| `langfuse.user.id` | User ID | Root Span |
| `langfuse.trace.input` | Trace input | Root Span at creation |
| `langfuse.tags` | Custom Trace tags (`tags` config) | Root Span at creation |
| `langfuse.observation.input` | Observation input | LLM/Agent Span |
| `langfuse.observation.output` | Observation output | LLM/Agent Span |

---

## Appendix: Key Constants

```typescript
const CONTEXT_LINK_TIMEOUT_MS = 3_000;       // Timeout for agent channel to link user context
const CONTEXT_MAX_AGE_MS = 20 * 60 * 1_000;  // Max context lifetime (20 minutes)
const CONTEXT_SWEEP_INTERVAL_MS = 10 * 60 * 1_000;  // Stale context sweep interval (10 minutes)
const TEMP_RUN_ID_PREFIX = "run-";           // Temporary runId prefix
const PENDING_ASSISTANT_TTL_MS = 15_000;     // Pending assistant message timeout (15 seconds)
const MAX_ATTR_LENGTH = 3_200_000;           // Max attribute length (3.2M characters)
```
