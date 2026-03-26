import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const command = process.argv[2];

if (command === "helper") {
  const rootDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
  await import(pathToFileURL(path.join(rootDir, "scripts", "widget-helper.mjs")).href);
} else {
  await import("../packages/notchapp/cli.mjs");
}
