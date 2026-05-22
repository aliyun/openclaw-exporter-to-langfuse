/**
 * Root entry point for OpenClaw's direct TypeScript loading (via jiti).
 *
 * Re-exports the plugin from src/index.ts and wraps it with the configSchema
 * and register() method that OpenClaw's plugin-sdk loader expects.
 */
import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import langfuseTracePlugin from "./dist/index.js";

const plugin = {
  id: langfuseTracePlugin.id,
  name: langfuseTracePlugin.name,
  description: langfuseTracePlugin.description,
  configSchema: {
    type: "object",
    properties: {
      endpoint: {
        type: "string",
        default: "",
        description: "Langfuse OTLP endpoint URL",
      },
      headers: {
        type: "object",
        default: {},
        description: "HTTP headers for Langfuse authentication",
      },
      serviceName: {
        type: "string",
        default: "openclaw-agent",
        description: "Service name for traces",
      },
      tags: {
        type: "array",
        items: { type: "string" },
        default: [],
        description:
          "Custom Langfuse tags applied to the trace root span (e.g. [\"id:openclaw\", \"ip:127.0.0.1\"]).",
      },
      userId: {
        type: "string",
        default: "",
        description:
          "Static user ID applied to traces when the hook event does not provide one. Priority: hook event > config > \"unknown\".",
      },
      debug: {
        type: "boolean",
        default: false,
        description: "Enable debug logging",
      },
      batchSize: {
        type: "number",
        default: 10,
        description: "Number of spans to buffer before sending",
      },
      flushIntervalMs: {
        type: "number",
        default: 5000,
        description: "Maximum time (ms) to wait before sending buffered spans",
      },
      enabledHooks: {
        type: "array",
        items: { type: "string" },
        description:
          "List of hooks to enable (if not set, all hooks are enabled)",
      },
      skillsRoots: {
        type: "array",
        items: { type: "string" },
        default: [],
        description:
          "Explicit skill roots for skill tag detection. Highest priority; when set, auto-detection is skipped.",
      },
      skillTaggingEnabled: {
        type: "boolean",
        default: false,
        description:
          "Enable skill tag detection and emit skill:* tags to Langfuse tool observations.",
      },
    },
  },

  register(api: OpenClawPluginApi) {
    langfuseTracePlugin.activate(api as any);
  },
};

export default plugin;
