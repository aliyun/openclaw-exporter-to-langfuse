#!/usr/bin/env node
import { Command } from "commander";
import inquirer from "inquirer";
import { execSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PLUGIN_VERSION } from "./version.js";

const PLUGIN_NAME = "openclaw-exporter-to-langfuse";
const PACKAGE_PATH = "openclaw-exporter-to-langfuse";

function getOpenClawDir(): string {
  return process.env.OPENCLAW_STATE_DIR || path.join(os.homedir(), ".openclaw");
}

function getConfigPath(): string {
  return path.join(getOpenClawDir(), "openclaw.json");
}

function getExtensionsDir(): string {
  return path.join(getOpenClawDir(), "extensions");
}

async function readConfig(): Promise<Record<string, any>> {
  try {
    const raw = await fs.readFile(getConfigPath(), "utf8");
    return JSON.parse(raw);
  } catch (error: any) {
    if (error.code === "ENOENT") return {};
    throw error;
  }
}

async function writeConfig(config: Record<string, any>): Promise<void> {
  const configPath = getConfigPath();
  await fs.mkdir(path.dirname(configPath), { recursive: true });
  await fs.writeFile(configPath, JSON.stringify(config, null, 2), "utf8");
}

function getPlatformCommand(command: string): string {
  if (
    process.platform === "win32" &&
    (command === "openclaw" || command === "npm")
  ) {
    return `${command}.cmd`;
  }
  return command;
}

function runCommand(command: string): void {
  execSync(command, { stdio: "inherit" });
}

function runCommandQuiet(command: string): string {
  return execSync(command, { encoding: "utf8" }).trim();
}

interface LangfusePluginConfig {
  endpoint: string;
  headers: {
    "Authorization": string;
  };
  serviceName: string;
  skillTaggingEnabled: boolean;
}

/**
 * Generate Basic Authorization header from public key and secret key
 */
function generateAuthorization(publicKey: string, secretKey: string): string {
  const credentials = `${publicKey}:${secretKey}`;
  const base64 = Buffer.from(credentials).toString("base64");
  return `Basic ${base64}`;
}

/**
 * Parse existing Authorization header to extract pk/sk if possible
 */
function parseAuthorization(auth: string): { pk: string; sk: string } | null {
  if (!auth?.startsWith("Basic ")) return null;
  try {
    const base64 = auth.slice(6);
    const decoded = Buffer.from(base64, "base64").toString("utf8");
    const [pk, sk] = decoded.split(":");
    if (pk && sk) return { pk, sk };
  } catch {
    // ignore parse errors
  }
  return null;
}

async function collectPluginConfig(): Promise<LangfusePluginConfig> {
  const config = await readConfig();
  const existingEntry = config.plugins?.entries?.[PLUGIN_NAME];
  const existingConfig = existingEntry?.config || {};
  
  // Try to parse existing authorization to get default pk/sk
  const existingAuth = existingConfig.headers?.["Authorization"];
  const parsedAuth = existingAuth ? parseAuthorization(existingAuth) : null;

  const answers = await inquirer.prompt([
    {
      name: "endpoint",
      type: "input",
      message:
        "Enter Langfuse OTLP Endpoint URL\n(e.g. https://cloud.langfuse.com/api/public/otel/v1/traces):",
      default: existingConfig.endpoint || undefined,
      validate: (input: string) => {
        if (input?.trim()) return true;
        return "Endpoint is required";
      },
    },
    {
      name: "publicKey",
      type: "input",
      message:
        "Enter Langfuse Public Key (pk-lf-xxx):",
      default: parsedAuth?.pk || undefined,
      validate: (input: string) => {
        if (input?.trim()) return true;
        return "Public Key is required";
      },
    },
    {
      name: "secretKey",
      type: "password",
      message:
        "Enter Langfuse Secret Key (sk-lf-xxx):",
      mask: "*",
      validate: (input: string) => {
        if (input?.trim()) return true;
        if (parsedAuth?.sk) return true;
        return "Secret Key is required";
      },
    },
    {
      name: "serviceName",
      type: "input",
      message: "Enter service name (serviceName):",
      default: existingConfig.serviceName || "openclaw-agent",
    },
  ]);

  const endpoint = answers.endpoint.trim();
  const publicKey = answers.publicKey?.trim() || "";
  const secretKey = answers.secretKey?.trim() || parsedAuth?.sk || "";
  const serviceName = answers.serviceName?.trim() || "openclaw-agent";

  if (!endpoint || !publicKey || !secretKey) {
    throw new Error("Missing required config: endpoint, publicKey or secretKey");
  }

  const authorization = generateAuthorization(publicKey, secretKey);

  return {
    endpoint,
    headers: {
      "Authorization": authorization,
    },
    serviceName,
    skillTaggingEnabled: false,
  };
}

async function updateOpenClawConfig(
  pluginConfig: LangfusePluginConfig,
): Promise<void> {
  const config = await readConfig();
  if (!config.plugins) config.plugins = {};
  if (!config.plugins.allow) config.plugins.allow = [];
  if (!config.plugins.allow.includes(PLUGIN_NAME)) {
    config.plugins.allow.push(PLUGIN_NAME);
  }
  if (!config.plugins.entries) config.plugins.entries = {};
  if (!config.plugins.entries[PLUGIN_NAME]) {
    config.plugins.entries[PLUGIN_NAME] = { enabled: true };
  }

  const entry = config.plugins.entries[PLUGIN_NAME];
  entry.enabled = true;
  const existing =
    entry.config && typeof entry.config === "object" ? entry.config : {};
  entry.config = {
    ...existing,
    endpoint: pluginConfig.endpoint,
    headers: pluginConfig.headers,
    serviceName: pluginConfig.serviceName,
    skillTaggingEnabled:
      typeof existing.skillTaggingEnabled === "boolean"
        ? existing.skillTaggingEnabled
        : pluginConfig.skillTaggingEnabled,
  };

  await writeConfig(config);
}

async function clearPluginConfig(): Promise<void> {
  const config = await readConfig();
  if (!config.plugins) return;
  if (config.plugins.entries?.[PLUGIN_NAME]) {
    delete config.plugins.entries[PLUGIN_NAME];
  }
  if (config.plugins.allow) {
    config.plugins.allow = config.plugins.allow.filter(
      (name: string) => name !== PLUGIN_NAME,
    );
  }
  await writeConfig(config);
}

async function clearInstalledPlugin(): Promise<void> {
  const config = await readConfig();
  const installPath = config.installs?.[PLUGIN_NAME]?.installPath;
  if (installPath) {
    await fs.rm(installPath, { recursive: true, force: true });
    return;
  }
  const fallbackPath = path.join(getExtensionsDir(), PLUGIN_NAME);
  await fs.rm(fallbackPath, { recursive: true, force: true });
}

function resolveLocalPluginDir(): string {
  // When running via `node dist/onboard-cli.js`, __dirname points to dist/
  const distDir = new URL(".", import.meta.url).pathname;
  return path.resolve(distDir, "..");
}

async function installPlugin(): Promise<void> {
  const openclawCmd = getPlatformCommand("openclaw");
  try {
    runCommandQuiet(`${openclawCmd} --version`);
  } catch {
    throw new Error("OpenClaw CLI not found. Please install openclaw first.");
  }

  // Try npm registry first; fall back to local symlink if the package is not published
  try {
    runCommand(`${openclawCmd} plugins install ${PACKAGE_PATH}`);
  } catch {
    console.log("npm package not published, falling back to local exporter install mode...");
    await installPluginLocal();
  }
}

async function installPluginLocal(): Promise<void> {
  const localDir = resolveLocalPluginDir();
  const config = await readConfig();

  // Register via plugins.load.paths so OpenClaw discovers the plugin
  // from its original directory (avoids symlink issues with Dirent.isDirectory)
  if (!config.plugins) config.plugins = {};
  if (!config.plugins.load) config.plugins.load = {};
  if (!Array.isArray(config.plugins.load.paths)) config.plugins.load.paths = [];

  if (!config.plugins.load.paths.includes(localDir)) {
    config.plugins.load.paths.push(localDir);
  }
  await writeConfig(config);
  console.log(`Registered local exporter path: ${localDir}`);
}

async function restartGateway(): Promise<void> {
  const openclawCmd = getPlatformCommand("openclaw");
  try {
    runCommand(`${openclawCmd} gateway restart`);
  } catch {
    console.log("Gateway restart failed. Run manually: openclaw gateway restart");
  }
}

async function handleInstall(): Promise<void> {
  console.log("\nOpenClaw Exporter to Langfuse - Install Wizard\n");
  const pluginConfig = await collectPluginConfig();
  await clearPluginConfig();
  await clearInstalledPlugin();
  await installPlugin();
  await updateOpenClawConfig(pluginConfig);
  await restartGateway();
  console.log("\nInstallation complete. openclaw-exporter-to-langfuse is now enabled.");
  console.log(
    `   Endpoint: ${pluginConfig.endpoint}`,
  );
  console.log(
    `   Service:  ${pluginConfig.serviceName}`,
  );
}

async function handleConfigOnly(): Promise<void> {
  console.log("\nOpenClaw Exporter to Langfuse - Update Configuration\n");
  const pluginConfig = await collectPluginConfig();
  await updateOpenClawConfig(pluginConfig);
  console.log("\nConfiguration updated.");
  console.log("   To apply changes, run: openclaw gateway restart");
}

const program = new Command();
program
  .name("openclaw-exporter-to-langfuse-onboard-cli")
  .version(PLUGIN_VERSION)
  .description("Install / configure the OpenClaw exporter to Langfuse");

program
  .command("install", { isDefault: true })
  .description("Install openclaw-exporter-to-langfuse and configure Langfuse connection")
  .action(async () => {
    try {
      await handleInstall();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error);
      console.error(`\nInstall failed: ${message}`);
      process.exit(1);
    }
  });

program
  .command("config")
  .description("Update Langfuse configuration only (no reinstall)")
  .action(async () => {
    try {
      await handleConfigOnly();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : String(error);
      console.error(`\nConfig update failed: ${message}`);
      process.exit(1);
    }
  });

program.parse(process.argv);
