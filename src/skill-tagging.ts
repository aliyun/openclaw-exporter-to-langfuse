// ---------------------------------------------------------------------------
// Skill -> Langfuse tag detection (read SKILL.md, exec under skill dir, etc.)
// ---------------------------------------------------------------------------

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { SkillTagDetectionConfig } from "./skill-tags-types.js";

export type { SkillTagDetectionConfig } from "./skill-tags-types.js";

export const DEFAULT_SKILL_READ_TOOL_NAMES = [
  "read",
  "readfile",
  "files_read",
  "read_file",
  "file_read",
];

export const DEFAULT_SKILL_EXEC_TOOL_NAMES = [
  "exec",
  "bash",
  "shell",
  "run_terminal_cmd",
  "terminal",
];

const MAX_TAG_LEN = 200;

function toTrimmedStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((x) => (typeof x === "string" ? x.trim() : String(x)))
    .filter(Boolean);
}

function normalizeFsPath(p: string): string {
  let s = p.trim().replace(/\\/g, "/");
  s = s.replace(/\/{2,}/g, "/");
  if (s.length > 1 && s.endsWith("/")) s = s.slice(0, -1);
  return s;
}

function normalizeSkillTag(raw: string): string {
  const t = raw.trim();
  if (!t) return t;
  const withPrefix = t.startsWith("skill:") ? t : `skill:${t}`;
  return withPrefix.length > MAX_TAG_LEN ? withPrefix.slice(0, MAX_TAG_LEN) : withPrefix;
}

function normalizeSkillRoots(roots: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const r of roots) {
    const n = normalizeFsPath(r);
    if (!n || seen.has(n)) continue;
    seen.add(n);
    out.push(n);
  }
  return out.sort((a, b) => b.length - a.length);
}

function canReadDir(dir: string): boolean {
  try {
    const st = fs.statSync(dir);
    return st.isDirectory();
  } catch {
    return false;
  }
}

function hasAnyImmediateSkillDir(root: string): boolean {
  try {
    const entries = fs.readdirSync(root, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const skillMd = path.join(root, entry.name, "SKILL.md");
      const skillMdLower = path.join(root, entry.name, "skill.md");
      if (fs.existsSync(skillMd) || fs.existsSync(skillMdLower)) {
        return true;
      }
    }
  } catch {
    return false;
  }
  return false;
}

/**
 * Read plugin load paths from openclaw.json and derive their skills/ subdirectories.
 */
function readPluginSkillRoots(openclawDir: string): string[] {
  try {
    const configPath = path.join(openclawDir, "openclaw.json");
    const raw = fs.readFileSync(configPath, "utf-8");
    const cfg = JSON.parse(raw) as Record<string, unknown>;
    const plugins = cfg.plugins as Record<string, unknown> | undefined;
    const load = plugins?.load as Record<string, unknown> | undefined;
    const paths = load?.paths;
    if (!Array.isArray(paths)) return [];
    return paths
      .filter((p): p is string => typeof p === "string" && p.trim().length > 0)
      .map((p) => path.join(p.trim(), "skills"));
  } catch {
    return [];
  }
}

/**
 * Auto-detect skill roots based on real OpenClaw path conventions:
 *
 * 1. Workspace skills:  <openclawDir>/workspace/skills/
 * 2. Common skills:     /opt/openclaw/skills/, /opt/git/openclaw/skills, /custom/skills
 * 3. Native skills:     /usr/lib/node_modules/openclaw/skills/
 * 4. Plugin skills:     <plugin-path>/skills/ for each plugins.load.paths entry
 * 5. This plugin's own: <moduleDir>/../skills/, <moduleDir>/../../skills/
 */
function resolveAutoDetectedSkillRoots(env: NodeJS.ProcessEnv = process.env): string[] {
  const homeDir = env.HOME || env.USERPROFILE || "";
  const openclawDir = env.OPENCLAW_STATE_DIR || (homeDir ? path.join(homeDir, ".openclaw") : "");
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));

  const candidates: string[] = [];

  // 1. Workspace skills (<openclawDir>/workspace/skills)
  if (openclawDir) {
    candidates.push(path.join(openclawDir, "workspace", "skills"));
  }

  // 2. Common skills roots
  candidates.push("/opt/openclaw/skills");
  candidates.push("/opt/git/openclaw/skills");
  candidates.push("/custom/skills");

  // 3. Native skills (global openclaw install)
  candidates.push("/usr/lib/node_modules/openclaw/skills");

  // 4. Plugin skills (from openclaw.json plugins.load.paths)
  if (openclawDir) {
    candidates.push(...readPluginSkillRoots(openclawDir));
  }

  // 5. This plugin's own skills directory
  candidates.push(path.join(moduleDir, "..", "skills"));
  candidates.push(path.join(moduleDir, "..", "..", "skills"));

  // Round 1: keep accessible directories.
  const accessible = normalizeSkillRoots(candidates.filter(Boolean)).filter(canReadDir);
  if (accessible.length === 0) {
    return [];
  }

  // Round 2: prefer roots that contain immediate skill dirs.
  const withSkillDirs = accessible.filter(hasAnyImmediateSkillDir);
  if (withSkillDirs.length > 0) {
    return normalizeSkillRoots(withSkillDirs);
  }
  return accessible;
}

/**
 * Priority:
 * 1) pluginConfig.skillsRoots (if set, skip auto-detect)
 * 2) OPENCLAW_SKILLS_ROOT (if set and no config roots, skip auto-detect)
 * 3) auto-detect
 */
export function resolveSkillTagDetectionConfig(
  pluginConfig: Record<string, unknown>,
  env: NodeJS.ProcessEnv = process.env,
): SkillTagDetectionConfig | null {
  const skillTaggingEnabled = pluginConfig.skillTaggingEnabled === true;
  if (!skillTaggingEnabled) {
    return null;
  }
  const configRoots = toTrimmedStringArray(pluginConfig.skillsRoots);
  const envRoot = env.OPENCLAW_SKILLS_ROOT?.trim();

  let roots: string[] = [];
  if (configRoots.length > 0) {
    roots = envRoot ? [...configRoots, envRoot] : configRoots;
  } else if (envRoot) {
    roots = [envRoot];
  } else {
    roots = resolveAutoDetectedSkillRoots(env);
  }

  const normalized = normalizeSkillRoots(roots);

  return {
    skillsRoots: normalized,
    skillReadToolNames: new Set(
      DEFAULT_SKILL_READ_TOOL_NAMES.map((s) => s.toLowerCase()),
    ),
    skillExecToolNames: new Set(
      DEFAULT_SKILL_EXEC_TOOL_NAMES.map((s) => s.toLowerCase()),
    ),
    skillBuiltinToolMap: new Map(),
    skillEmitMetadata: true,
  };
}

const PARAM_STRING_KEYS = new Set([
  "path",
  "file_path",
  "target_path",
  "filepath",
  "filePath",
  "command",
  "cmd",
  "shell_command",
  "shellCommand",
  "script",
  "arguments",
  "input",
  "query",
]);

function collectStringsFromValue(value: unknown, depth: number, out: string[]): void {
  if (depth > 8) return;
  if (typeof value === "string") {
    if (value.length > 0 && value.length < 500_000) out.push(value);
    return;
  }
  if (value === null || value === undefined) return;
  if (Array.isArray(value)) {
    for (const item of value) collectStringsFromValue(item, depth + 1, out);
    return;
  }
  if (typeof value === "object") {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (PARAM_STRING_KEYS.has(k) || depth <= 2) {
        collectStringsFromValue(v, depth + 1, out);
      }
    }
  }
}

function extractStringsFromToolParams(params: Record<string, unknown>): string[] {
  const out: string[] = [];
  collectStringsFromValue(params, 0, out);
  return out;
}

function pathUnderRoot(normalizedPath: string, root: string): boolean {
  return normalizedPath === root || normalizedPath.startsWith(`${root}/`);
}

function skillFromSkillMdPath(normalizedPath: string, roots: string[]): string | undefined {
  if (!normalizedPath.toLowerCase().endsWith("/skill.md")) return undefined;
  const parent = normalizedPath.slice(0, Math.max(0, normalizedPath.lastIndexOf("/")));
  if (!parent) return undefined;
  for (const root of roots) {
    if (!pathUnderRoot(parent, root)) continue;
    const rest = parent.slice(root.length).replace(/^\//, "");
    const firstSeg = rest.split("/")[0];
    if (firstSeg && firstSeg !== "." && firstSeg !== "..") {
      return firstSeg;
    }
  }
  return undefined;
}

function skillDirsFromCommand(cmd: string, roots: string[]): string[] {
  const found = new Set<string>();
  for (const root of roots) {
    const escaped = root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`${escaped}/([^/\\s"']+)`, "g");
    let m: RegExpExecArray | null;
    while ((m = re.exec(cmd)) !== null) {
      const seg = m[1];
      if (seg && seg !== "." && seg !== "..") found.add(seg);
    }
  }
  return [...found];
}

function mergeUniqueTags(tags: Iterable<string>): string[] {
  const set = new Set<string>();
  for (const t of tags) {
    const n = normalizeSkillTag(t);
    if (n) set.add(n);
  }
  return [...set].sort();
}

export function detectSkillTagsFromToolCall(
  toolName: string,
  params: Record<string, unknown>,
  cfg: SkillTagDetectionConfig,
): string[] {
  const tags = new Set<string>();
  const tn = toolName.toLowerCase().trim();
  const builtin = cfg.skillBuiltinToolMap.get(tn);
  if (builtin) {
    tags.add(normalizeSkillTag(builtin));
  }
  const roots = cfg.skillsRoots;
  if (roots.length === 0) {
    return [];
  }
  const strings = extractStringsFromToolParams(params);

  if (cfg.skillReadToolNames.has(tn)) {
    for (const s of strings) {
      let decoded = s;
      try {
        decoded = decodeURIComponent(s);
      } catch {
        // Keep original string when URL decoding fails.
      }
      const norm = normalizeFsPath(decoded);
      const skill = skillFromSkillMdPath(norm, roots);
      if (skill) tags.add(normalizeSkillTag(skill));
    }
  }

  if (cfg.skillExecToolNames.has(tn)) {
    for (const s of strings) {
      for (const skillDir of skillDirsFromCommand(s, roots)) {
        tags.add(normalizeSkillTag(skillDir));
      }
    }
  }

  return mergeUniqueTags(tags);
}

