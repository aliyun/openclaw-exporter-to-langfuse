import assert from "node:assert/strict";
import test from "node:test";

import {
  detectSkillTagsFromToolCall,
  resolveSkillTagDetectionConfig,
} from "../dist/skill-tagging.js";

test("detects skill tag from read SKILL.md path", () => {
  const cfg = {
    skillsRoots: ["/opt/git/openclaw/skills"],
    skillReadToolNames: new Set(["read"]),
    skillExecToolNames: new Set(["exec", "bash"]),
    skillBuiltinToolMap: new Map(),
    skillEmitMetadata: true,
  };

  const tags = detectSkillTagsFromToolCall(
    "read",
    { path: "/opt/git/openclaw/skills/nano-pdf/SKILL.md" },
    cfg,
  );
  assert.deepEqual(tags, ["skill:nano-pdf"]);
});

test("detects skill tag from exec command path", () => {
  const cfg = {
    skillsRoots: ["/opt/git/openclaw/skills"],
    skillReadToolNames: new Set(["read"]),
    skillExecToolNames: new Set(["exec", "bash"]),
    skillBuiltinToolMap: new Map(),
    skillEmitMetadata: true,
  };

  const tags = detectSkillTagsFromToolCall(
    "exec",
    {
      command:
        'uv run /opt/git/openclaw/skills/nano-banana-pro/scripts/generate_image.py --prompt "demo"',
    },
    cfg,
  );
  assert.deepEqual(tags, ["skill:nano-banana-pro"]);
});

test("ignores non-matching tool call", () => {
  const cfg = {
    skillsRoots: ["/opt/git/openclaw/skills"],
    skillReadToolNames: new Set(["read"]),
    skillExecToolNames: new Set(["exec", "bash"]),
    skillBuiltinToolMap: new Map(),
    skillEmitMetadata: true,
  };

  const tags = detectSkillTagsFromToolCall("exec", {
    command: "curl https://example.com",
  }, cfg);
  assert.deepEqual(tags, []);
});

test("resolve config uses skillsRoots first, then env", () => {
  const cfg = resolveSkillTagDetectionConfig(
    { skillTaggingEnabled: true, skillsRoots: ["/configured/skills"] },
    { OPENCLAW_SKILLS_ROOT: "/env/skills" },
  );
  assert.ok(cfg);
  assert.deepEqual(cfg.skillsRoots, ["/configured/skills", "/env/skills"]);
});

test("resolve config uses env when skillsRoots missing", () => {
  const cfg = resolveSkillTagDetectionConfig(
    { skillTaggingEnabled: true },
    { OPENCLAW_SKILLS_ROOT: "/env/skills" },
  );
  assert.ok(cfg);
  assert.deepEqual(cfg.skillsRoots, ["/env/skills"]);
});

test("resolve config returns null when skill tagging disabled", () => {
  const cfg = resolveSkillTagDetectionConfig(
    { skillsRoots: ["/configured/skills"] },
    { OPENCLAW_SKILLS_ROOT: "/env/skills" },
  );
  assert.equal(cfg, null);
});

test("resolve config stays enabled with explicit empty roots", () => {
  const cfg = resolveSkillTagDetectionConfig(
    { skillTaggingEnabled: true, skillsRoots: [] },
    { OPENCLAW_SKILLS_ROOT: "" },
  );
  assert.ok(cfg);
  assert.ok(Array.isArray(cfg.skillsRoots));
});

