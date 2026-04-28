import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const PLUGIN_VERSION: string = readFileSync(
  resolve(__dirname, "..", "VERSION"),
  "utf8",
).trim();
