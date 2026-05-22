# OpenClaw Exporter to Langfuse 工作原理详解

<!-- LANGUAGE_SELECTOR_START -->
[English](./TUTORIAL.md) | **中文**
<!-- LANGUAGE_SELECTOR_END -->

## 目录

1. [整体架构](#1-整体架构)
2. [核心概念](#2-核心概念)
3. [数据流转全景](#3-数据流转全景)
4. [Hook 机制](#4-hook-机制)
5. [Trace Context 管理](#5-trace-context-管理)
6. [Span 层级树](#6-span-层级树)
7. [LangfuseExporter 工作原理](#7-langfuseexporter-工作原理)
8. [分段 LLM Span 机制](#8-分段-llm-span-机制)
9. [工具调用链路](#9-工具调用链路)
10. [并发与异步任务队列](#10-并发与异步任务队列)
11. [配置与初始化](#11-配置与初始化)

---

## 1. 整体架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                        OpenClaw 网关服务                               │
│                                                                        │
│  ┌────────────┐    ┌──────────────────────────────┐    ┌───────────┐  │
│  │ 用户消息    │───→│  Agent 执行引擎               │───→│ LLM 调用   │  │
│  └────────────┘    │  (触发各种 Hook)               │    └───────────┘  │
│                    └──────────┬─────────────────────┘                   │
│                               │                                          │
│                               ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │               openclaw-exporter-to-langfuse (本导出器)                    │   │
│  │                                                                    │   │
│  │  ┌──────────────────┐    ┌──────────────────────────────────┐    │   │
│  │  │  Hook 注册层      │    │  TraceContext 内存管理            │    │   │
│  │  │  (11 个 Hook)     │    │  - contextByChannelId            │    │   │
│  │  │                   │    │  - contextByRunId                │    │   │
│  │  │  message_received │    │  - contextsByChannelId           │    │   │
│  │  │  llm_input        │    │  - pendingToolCalls              │    │   │
│  │  │  llm_output       │    │  - traceTaskQueueByTraceId       │    │   │
│  │  │  before_tool_call │    │  - pendingAssistantByTraceId     │    │   │
│  │  │  after_tool_call  │    │  - ...                           │    │   │
│  │  │  agent_end        │    └──────────────────────────────────┘    │   │
│  │  │  ...              │                                            │   │
│  │  └──────────────────┘    ┌──────────────────────────────────┐    │   │
│  │            │              │  LangfuseExporter                 │    │   │
│  │            ▼              │  - openSpans: Map<spanId, Span>   │    │   │
│  │  ┌──────────────────┐    │  - BasicTracerProvider            │    │   │
│  │  │  createSpan()    │    │    └── BatchSpanProcessor         │    │   │
│  │  │  export()        │    │         └── OTLPTraceExporter    │    │   │
│  │  │  startSpan()     │    │              │                     │    │   │
│  │  │  endSpanById()   │    │              ▼                     │    │   │
│  │  └──────────────────┘    │        HTTP POST → Langfuse       │    │   │
│  │                          └──────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

**核心流程**：
1. OpenClaw 执行过程中触发各种 Hook
2. 导出器拦截 Hook，创建/更新 Span 数据
3. LangfuseExporter 通过 OpenTelemetry SDK 批量上报到 Langfuse
4. Langfuse 接收 OTLP 数据，展示 Trace 可视化

---

## 2. 核心概念

### 2.1 Trace（追踪）

一个 Trace 代表一次完整的用户交互过程，从用户发送消息到收到 AI 回复的整个链路。

```typescript
interface TraceContext {
  traceId: string;          // 32 位 hex，唯一标识一个 Trace
  rootSpanId: string;       // Root Span ID
  runId: string;            // 运行 ID（可能从临时 ID 重新绑定为稳定 ID）
  turnId: string;           // 轮次 ID
  channelId: string;        // 通道标识（如 "user/123", "agent/abc"）
  sessionId?: string;       // 会话 ID
  createdAt: number;        // 创建时间戳

  userInput?: unknown;      // 用户输入内容
  lastOutput?: unknown;     // 最后输出内容
  // ... 更多字段
}
```

### 2.2 Span（跨度）

Span 是 Trace 中的一个节点，代表一个操作单元。Span 有父子关系，形成一棵树。

```typescript
interface SpanData {
  name: string;             // Span 名称（如 "chat claude-3.5"）
  type: SpanType;           // 类型（entry/model/tool/agent/step 等）
  startTime: number;        // 开始时间（毫秒时间戳）
  endTime?: number;         // 结束时间
  attributes: Record<string, string | number | boolean>;  // 属性
  input?: unknown;          // 输入数据
  output?: unknown;         // 输出数据
  parentSpanId?: string;    // 父 Span ID
  traceId?: string;         // 所属 Trace ID
  spanId?: string;          // Span ID
}
```

### 2.3 Span 类型

| 类型 | 说明 | 生命周期 | 对应 Hook |
|------|------|---------|-----------|
| `entry` | 入口（根 Span） | 长生命周期 | `message_received` 创建，`agent_end` 关闭 |
| `agent` | Agent 执行 | 长生命周期 | `before_agent_start` 创建，`agent_end` 关闭 |
| `step` | React 轮次（LLM+工具调用分组） | 长生命周期 | `llm_input` 创建，`after_tool_call`/`before_message_write` 关闭 |
| `model` | LLM 调用 | 短生命周期 | `before_message_write`/`llm_output` 导出 |
| `tool` | 工具调用 | 短生命周期 | `before_tool_call` 记录，`after_tool_call` 导出 |
| `session` | 会话事件 | 短生命周期 | `session_start`/`session_end` 导出 |
| `gateway` | 网关节点 | 短生命周期 | `gateway_start` 导出 |

---

## 3. 数据流转全景

### 3.1 一次完整对话的 Span 树

```
用户: "北京今天天气怎么样？"

enter_openclaw_system (root, entry)          ← message_received
  └── invoke_agent weather-agent (agent)     ← before_agent_start
        └── react step (step #1)             ← llm_input
              ├── chat claude-3.5 (model)    ← before_message_write
              │    [LLM 决定调用 get_weather]
              └── execute_tool get_weather (tool)  ← after_tool_call
        └── react step (step #2)             ← after_tool_call 创建新 step
              └── chat claude-3.5 (model)    ← before_message_write
                   [LLM 生成最终回答]
```

### 3.2 数据流向

```
Hook 触发
    │
    ▼
┌─────────────────────────┐
│ getOrCreateContext()    │  ← 获取或创建 TraceContext
│ (通过 channelId/runId   │
│  查找已有上下文)         │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ createSpan()            │  ← 构建 SpanData 对象
│ (填充 attributes,       │
│  input/output, 父子关系) │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ LangfuseExporter        │
│ .export() / .startSpan()│  ← 调用 OpenTelemetry Tracer
│ / .endSpanById()        │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ BasicTracerProvider     │
│   └── BatchSpanProcessor│  ← 批量处理队列
│         (max 10 spans   │
│          OR 每 5 秒)     │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ OTLPTraceExporter       │  ← 序列化为 Protobuf
│ HTTP POST → Langfuse    │  ← 带 Authorization 头
│ /v1/traces              │
└─────────────────────────┘
```

---

## 4. Hook 机制

### 4.1 Hook 注册

插件在 `activate()` 中注册 11 个 Hook：

```typescript
// src/index.ts 第 372 行
activate(api: OpenClawPluginApi) {
  // 读取配置
  const config: LangfuseTraceConfig = {
    endpoint: pluginConfig.endpoint,
    headers: pluginConfig.headers,
    serviceName: pluginConfig.serviceName || "openclaw-agent",
    debug: pluginConfig.debug || false,
    batchSize: pluginConfig.batchSize || 10,
    flushIntervalMs: pluginConfig.flushIntervalMs || 5000,
    enabledHooks: pluginConfig.enabledHooks,  // 可选白名单
  };
  const skillTaggingEnabled = pluginConfig.skillTaggingEnabled === true; // 默认 false

  // 创建 Exporter
  const exporter = new LangfuseExporter(api, config);

  // 注册 Hook（部分示例）
  if (shouldHookEnabled("message_received")) {
    api.on("message_received", async (event, hookCtx) => {
      // 处理逻辑...
    });
  }
  // ... 其他 Hook
}
```

### 4.2 Hook 执行时序

以一次带工具调用的 Agent 为例：

```
时间线:

T0   message_received     → 用户消息到达
     ├── 创建 TraceContext
     ├── 创建 entry Span (root)
     └── 记录 userInput

T1   before_agent_start   → Agent 开始执行
     ├── 确保 entry Span 存在（幂等）
     └── 创建 agent Span

T2   llm_input            → LLM 被调用
     ├── 创建 step Span (react round #1)
     ├── 记录 LLM provider、model、input messages
     └── 设置 llmPendingStartTime

T3   before_message_write → LLM 返回 assistant 消息（含 tool_call）
     ├── 提取 tool_calls 和文本内容
     ├── 导出 model Span (LLM 调用 #1)
     └── step 保持开放（等待 tool 结果）

T4   before_tool_call     → 工具调用开始
     └── 记录 pendingToolCall (toolName, toolCallId, startTime)

T5   after_tool_call      → 工具调用结束
     ├── 匹配 pendingToolCall
     ├── 导出 tool Span
     ├── 记录 tool result
     ├── 所有 tool 完成后：
     │   ├── 关闭当前 step Span
     │   ├── 创建新 step Span (react round #2)
     │   └── 准备下一轮 LLM input messages

T6   llm_input            → 第二轮 LLM 调用
     ├── 更新 llmPendingStartTime
     └── 记录 input messages (含 tool result)

T7   before_message_write → LLM 返回最终回答（纯文本）
     ├── 导出 model Span (LLM 调用 #2)
     └── 关闭 step Span（无 tool_call 了）

T8   llm_output           → LLM 调用完成
     └── 兼容性兜底（如果 before_message_write 未触发）

T9   agent_end            → Agent 执行结束
     ├── 关闭剩余 step Span
     ├── 延迟 100ms 后：
     │   ├── 补充 agent Span 属性（output、usage）
     │   ├── 关闭 agent Span
     │   ├── 补充 root Span 属性（input、output）
     │   ├── 关闭 root Span
     │   └── flush() → 强制上报所有 Span
     └── 清理 TraceContext
```

---

## 5. Trace Context 管理

### 5.1 多 Map 索引结构

插件使用多个 Map 来高效查找和管理 TraceContext：

```typescript
// src/index.ts 第 404-410 行
const contextByChannelId = new Map<string, TraceContext>();          // channelId → Context
const contextByRunId = new Map<string, TraceContext>();              // runId → Context
const contextsByChannelId = new Map<string, Set<TraceContext>>();    // channelId → 多个 Context（并发）
const activeContextByAgentChannel = new Map<string, TraceContext>(); // agent channel → Context
const pendingToolCalls = new Map<string, PendingToolCall>();         // toolCallKey → PendingToolCall
const traceTaskQueueByTraceId = new Map<string, Promise<void>>();    // traceId → 任务队列
const pendingAssistantByTraceId = new Map<string, PendingAssistantMessage>();
```

### 5.2 Context 查找逻辑

```typescript
const getOrCreateContext = (rawChannelId, runId, hookName) => {
  // 1. 优先通过 channelId 查找
  let activeCtx = getContextByChannel(rawChannelId);

  // 2. Agent channel 尝试查找绑定的 user context
  if (rawChannelId.startsWith("agent/") && effectiveRunId) {
    const originalChannelId = getOriginalChannelId(effectiveRunId);
    if (originalChannelId) {
      activeCtx = getContextByChannel(originalChannelId) || activeCtx;
    }
  }

  // 3. 通过 runId 查找
  if (!activeCtx) {
    activeCtx = getContextByRun(effectiveRunId);
  }

  // 4. Agent channel 没有 context 时，尝试关联最近的 user context
  if (!activeCtx && canLinkRecentUserContext()) {
    activeCtx = linkRecentUserContext();
  }

  // 5. 都没有则创建新 Trace
  if (!activeCtx) {
    activeCtx = startTurn(effectiveRunId, channelId);
    isNew = true;
  }

  return { ctx: activeCtx, channelId, isNew };
};
```

### 5.3 Run ID 重新绑定

OpenClaw 可能先使用临时 runId（如 `run-1234567890`），后续才提供稳定 ID。插件会自动重新绑定：

```typescript
const bindRealRunId = (ctx, runId, hookName) => {
  const realRunId = resolveOptionalRunId(runId);
  if (!realRunId || ctx.runId === realRunId) return;

  // 跳过已稳定绑定的
  if (!isTemporaryRunId(ctx.runId)) return;

  // 重新映射
  contextByRunId.delete(ctx.runId);
  ctx.runId = realRunId;
  ctx.turnId = realRunId;
  contextByRunId.set(realRunId, ctx);

  // 更新已导出 Span 的属性
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

### 5.4 过期 Context 清理

```typescript
const sweepStaleContexts = () => {
  const now = Date.now();
  // 清理超过 20 分钟的 context
  for (const [key, ctx] of contextByChannelId) {
    if (now - ctx.createdAt > CONTEXT_MAX_AGE_MS) {  // 20 分钟
      contextByChannelId.delete(key);
      contextByRunId.delete(ctx.runId);
    }
  }
  // 清理超过 15 秒的 pending assistant message
  for (const [traceId, pending] of pendingAssistantByTraceId) {
    if (now - pending.createdAt > PENDING_ASSISTANT_TTL_MS) {  // 15 秒
      pendingAssistantByTraceId.delete(traceId);
    }
  }
};
// 每 10 分钟执行一次
setInterval(sweepStaleContexts, CONTEXT_SWEEP_INTERVAL_MS);
```

---

## 6. Span 层级树

### 6.1 父子关系解析

```typescript
// Root Span 无 parentSpanId（默认为 undefined）
// Agent Span 的 parentSpanId = ctx.rootSpanId
// Step Span 的 parentSpanId = ctx.agentSpanId || ctx.rootSpanId
// LLM/Tool Span 的 parentSpanId = ctx.stepSpanId || ctx.agentSpanId || ctx.rootSpanId

const resolveAgentFirstParentSpanId = (ctx) =>
  ctx.agentSpanId || ctx.rootSpanId;

const resolveStepFirstParentSpanId = (ctx) =>
  ctx.stepSpanId || ctx.agentSpanId || ctx.rootSpanId;
```

### 6.2 Span 创建示例

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
      "langfuse.session.id": sessionId,       // Langfuse 特有属性
      "openclaw.run.id": ctx.runId,
      "openclaw.turn.id": ctx.turnId,
    },
    traceId: ctx.traceId,
    spanId: generateId(16),
    parentSpanId: parentSpanId || ctx.rootSpanId,  // 默认父为 root
  };
};
```

---

## 7. LangfuseExporter 工作原理

### 7.1 初始化

```typescript
// src/langfuse-exporter.ts 第 60-103 行
private async initialize(): Promise<void> {
  // 1. 创建 Resource（服务标识）
  const resource = resourceFromAttributes({
    [ATTR_SERVICE_NAME]: this.config.serviceName,
    "service.instance.id": `${instanceName}@${hostname()}:${process.pid}`,
    "host.name": hostname(),
    "telemetry.sdk.language": "nodejs",
  });

  // 2. 创建 OTLP Exporter（带 Authorization 头）
  const exporter = new OTLPTraceExporter({
    url: traceUrl,  // endpoint + "/v1/traces"
    headers: {
      ...this.config.headers,
      "x-langfuse-ingestion-version": "4",  // Langfuse 特有头
    },
  });

  // 3. 创建 BatchSpanProcessor（批量处理）
  const spanProcessor = new BatchSpanProcessor(exporter, {
    maxQueueSize: 100,                  // 最多缓存 100 个 span
    maxExportBatchSize: this.config.batchSize,       // 攒满 10 个发送
    scheduledDelayMillis: this.config.flushIntervalMs, // 或每 5 秒发送
  });

  // 4. 创建 BasicTracerProvider（不注册为全局，避免冲突）
  this.provider = new BasicTracerProvider({
    resource,
    spanProcessors: [spanProcessor],
  });

  // 5. 获取 Tracer（不调用 .register()）
  this.tracer = this.provider.getTracer("openclaw-exporter-to-langfuse", PLUGIN_VERSION);
}
```

### 7.2 两种导出模式

#### 模式 1：`export()` — 即发即忘（短生命周期）

适用：LLM span、Tool span、Session span

```typescript
async export(spanData: SpanData): Promise<void> {
  // 1. 创建 Span
  const span = this.tracer.startSpan(spanData.name, {
    kind: spanKind,
    startTime: spanData.startTime,
    attributes: exportSpanAttrs,
  }, parentContext);

  // 2. 设置状态
  span.setStatus({ code: hasError ? SpanStatusCode.ERROR : SpanStatusCode.OK });

  // 3. 立即关闭（自动进入 BatchSpanProcessor 队列）
  span.end(spanData.endTime || Date.now());

  // ⚠️ 注意：span 不会存入 openSpans，创建→关闭→入队一气呵成
}
```

#### 模式 2：`startSpan()` + `endSpanById()` — 长生命周期

适用：Root span、Agent span、Step span

```typescript
// 开启 Span
async startSpan(spanData: SpanData, spanId: string): Promise<void> {
  const span = this.tracer.startSpan(spanData.name, {
    kind: spanKind,
    startTime: spanData.startTime,
    attributes: spanAttrs,
  }, parentContext);

  this.openSpans.set(spanId, span);  // ← 存入 Map，保持活跃
}

// 中间可以动态补充属性
patchOpenSpanAttributes(spanId: string, attrs: Record<string, ...>): void {
  const span = this.openSpans.get(spanId);
  if (!span) return;
  for (const [key, value] of Object.entries(attrs)) {
    span.setAttribute(key, value);
  }
}

// 关闭 Span
endSpanById(spanId: string, endTime: number, additionalAttrs?): void {
  const span = this.openSpans.get(spanId);
  if (!span) return;

  // 补充最终属性
  if (additionalAttrs) {
    for (const [key, value] of Object.entries(additionalAttrs)) {
      span.setAttribute(key, value);
    }
  }

  span.setStatus({ code: SpanStatusCode.OK });
  span.end(endTime || Date.now());    // ← 关闭后自动进入队列
  this.openSpans.delete(spanId);      // ← 从 Map 移除
}
```

### 7.3 批量上报机制

```
Span 进入队列
    │
    ▼
┌─────────────────────────┐
│  BatchSpanProcessor     │
│                         │
│  队列 (max 100 spans)   │
│                         │
│  触发条件（任一满足）：   │
│  ① 攒满 10 个 span      │
│  ② 超过 5 秒未发送       │
│  ③ 手动调用 flush()     │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  OTLPTraceExporter      │
│  序列化为 Protobuf       │
│  HTTP POST → Langfuse   │
│  /api/public/otel/v1/   │
│  traces                 │
└─────────────────────────┘
```

### 7.4 父 Span Context 解析

由于不调用全局 `.register()`，需要手动管理父子关系：

```typescript
private resolveParentContext(parentSpanId?: string) {
  if (parentSpanId) {
    const parentSpan = this.openSpans.get(parentSpanId);
    if (parentSpan) {
      // 通过 openSpans Map 查找父 Span
      return trace.setSpan(context.active(), parentSpan);
    }
  }
  return context.active();
}
```

---

## 8. 分段 LLM Span 机制

### 8.1 为什么需要分段？

在多轮 React 循环中，LLM 会被多次调用（每次 tool call 前后各一次）：

```
如果不分段（旧方案）：
  一个 LLM span 包含所有轮次 → 无法区分每轮耗时/输入输出

分段方案：
  每次 LLM 调用 → 独立 LLM span → 清晰看到每轮细节
```

### 8.2 分段实现

```typescript
const exportPendingLlmSpan = async (ctx, channelId, params) => {
  // 1. 计算时间
  const startTime = ctx.llmPendingStartTime;  // 来自 llm_input
  const safeEndTime = params.endTime;          // 来自 before_message_write

  // 2. 构建属性（包含 usage/token）
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

  // 3. 创建并导出 Span
  const span = createSpan(ctx, channelId, `chat ${model}`, "model",
    startTime, safeEndTime, llmAttrs,
    undefined, undefined, resolveStepFirstParentSpanId(ctx));

  await exporter.export(span);  // ← 即发即忘

  // 4. 计数器 +1
  ctx.llmSegmentCount += 1;
};
```

### 8.3 `llmSegmentCount` 的作用

```typescript
// llm_output 中的兼容性兜底
if (ctx.llmSegmentCount === 0 && ctx.llmPendingStartTime) {
  // 只有当 before_message_write 没触发时才走这里
  await exportPendingLlmSpan(ctx, channelId, { endTime, usage: event.usage });
}
```

- `llmSegmentCount === 0` → 没有分段，用 `llm_output` 兜底导出
- `llmSegmentCount > 0` → 已通过 `before_message_write` 导出，跳过

---

## 9. 工具调用链路

### 9.1 工具调用生命周期

```
before_tool_call                     after_tool_call
     │                                    │
     ▼                                    ▼
记录 pendingToolCall              匹配 pendingToolCall
(toolName, toolCallId,            导出 tool Span
 startTime, params)               记录 tool result
                                  检查是否所有 tool 完成
                                        │
                                        ▼
                                  如果全部完成：
                                    - 关闭当前 step
                                    - 创建新 step
                                    - 准备下一轮 LLM input
```

### 9.2 工具匹配逻辑

```typescript
const consumePendingToolCall = (event: AfterToolCallEvent) => {
  // 1. 精确匹配（toolCallId + runId）
  const directKey = buildPendingToolCallKey(eventToolCallId, eventRunId);
  const direct = pendingToolCalls.get(directKey);
  if (direct) {
    pendingToolCalls.delete(directKey);
    return direct;
  }

  // 2. 降级匹配（toolName + runId 时间最晚的）
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

### 9.3 多工具批量处理

当 LLM 一次性调用多个工具时：

```typescript
// after_tool_call 中
if (hadWaitingTools) {
  // 从等待集合中移除当前工具
  traceContext.llmPendingToolCallIds.delete(toolCallId);

  // 检查是否所有工具都完成了
  const toolBatchFinished =
    traceContext.llmPendingToolCallIds.size === 0 &&
    traceContext.llmPendingToolCallCountFallback === 0;

  if (toolBatchFinished) {
    // 关闭当前 step
    endStepSpan(traceContext, now, "toolUse", channelId);

    // 创建新 step（下一轮 LLM）
    traceContext.llmPendingStartTime = now;
    await ensureStepSpan(traceContext, channelId, now);

    // 准备 input messages（含所有 tool results）
    traceContext.llmPendingInputMessages = formatInputMessages(nextInputHistory);
  }
}
```

---

## 10. 并发与异步任务队列

### 10.1 为什么需要任务队列？

Hook 可能乱序到达（如 `before_message_write` 在 `llm_input` 之前到达）。任务队列确保同一个 trace 的操作按顺序执行：

```typescript
const enqueueTraceTask = (traceId: string, task: () => Promise<void>): Promise<void> => {
  const prev = traceTaskQueueByTraceId.get(traceId) || Promise.resolve();
  const next = prev.catch(() => undefined).then(task);  // ← 链式执行

  const tracked = next.finally(() => {
    if (traceTaskQueueByTraceId.get(traceId) === tracked) {
      traceTaskQueueByTraceId.delete(traceId);  // ← 队列完成，清理
    }
  });

  traceTaskQueueByTraceId.set(traceId, tracked);
  return tracked;
};
```

### 10.2 使用场景

```typescript
// before_message_write 中的异步导出
void enqueueTraceTask(ctx.traceId, async () => {
  await processAssistantMessageForContext(ctx, channelId, message);
}).catch((err) => {
  api.logger.warn(`before_message_write segmented export failed: ${err}`);
});

// agent_end 中等待所有队列任务完成
await drainTraceTasks(ctx.traceId);  // ← 确保所有异步任务完成后再关闭 span
```

### 10.3 Pending Assistant 缓冲

当 `before_message_write` 在 `llm_input` 之前到达时，消息被缓冲：

```typescript
if (!ctx.hasSeenLlmInput) {
  // 缓冲消息，等待 llm_input 到来时处理
  pendingAssistantByTraceId.set(ctx.traceId, { message, createdAt: Date.now() });
  return;
}

// llm_input 中检查并处理缓冲消息
const pendingAssistant = pendingAssistantByTraceId.get(ctx.traceId);
if (pendingAssistant) {
  pendingAssistantByTraceId.delete(ctx.traceId);
  void enqueueTraceTask(ctx.traceId, async () => {
    await processAssistantMessageForContext(ctx, channelId, pendingAssistant.message);
  });
}
```

---

## 11. 配置与初始化

### 11.1 插件配置

```json
// openclaw.json 中
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
        "userId": "user_12345",
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

### 11.2 Langfuse OTLP 端点

```typescript
private resolveTraceUrl(): string {
  const endpoint = this.config.endpoint.replace(/\/+$/, "");
  // 自动补全 /v1/traces
  if (/\/v1\/traces$/i.test(endpoint)) {
    return endpoint;
  }
  return `${endpoint}/v1/traces`;
}
```

### 11.3 Langfuse 特有属性

| 属性名 | 说明 | 设置位置 |
|--------|------|----------|
| `langfuse.session.id` | 会话 ID | 所有 Span |
| `langfuse.user.id` | 用户 ID（`userId` 配置 > 操作系统用户名 > `"unknown"`） | Root Span |
| `langfuse.trace.input` | Trace 输入 | Root Span 创建时 |
| `langfuse.tags` | 自定义 Trace 标签（`tags` 配置） | Root Span 创建时 |
| `langfuse.observation.input` | 观察输入 | LLM/Agent Span |
| `langfuse.observation.output` | 观察输出 | LLM/Agent Span |

---

## 附录：关键常量

```typescript
const CONTEXT_LINK_TIMEOUT_MS = 3_000;       // Agent channel 关联 user context 的超时时间
const CONTEXT_MAX_AGE_MS = 20 * 60 * 1_000;  // Context 最大存活时间（20 分钟）
const CONTEXT_SWEEP_INTERVAL_MS = 10 * 60 * 1_000;  // 过期 Context 清理间隔（10 分钟）
const TEMP_RUN_ID_PREFIX = "run-";           // 临时 runId 前缀
const PENDING_ASSISTANT_TTL_MS = 15_000;     // Pending assistant 消息超时时间（15 秒）
const MAX_ATTR_LENGTH = 3_200_000;           // 属性最大长度（3.2M 字符）
```
