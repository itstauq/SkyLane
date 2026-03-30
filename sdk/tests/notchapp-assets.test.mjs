import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const sdkRoot = path.resolve(testDir, "..");
const repoRoot = path.resolve(sdkRoot, "..");
const cliPath = path.join(repoRoot, "sdk", "packages", "notchapp", "cli.mjs");

function createTempDir(t, prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

function writeWidgetFixture(widgetDir, source) {
  fs.mkdirSync(path.join(widgetDir, "src"), { recursive: true });
  fs.writeFileSync(
    path.join(widgetDir, "package.json"),
    JSON.stringify({
      name: "tmp-widget",
      private: true,
      notch: {
        id: "tmp.widget",
        title: "Tmp Widget",
        minSpan: 1,
        maxSpan: 1,
        entry: "src/index.js",
      },
    }, null, 2)
  );
  fs.writeFileSync(path.join(widgetDir, "src", "index.js"), source);
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      ...options,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function runCli(args, options = {}) {
  return runProcess(process.execPath, [cliPath, ...args], options);
}

function waitFor(predicate, timeoutMs = 5000, intervalMs = 50) {
  const startedAt = Date.now();

  return new Promise((resolve, reject) => {
    const poll = () => {
      if (predicate()) {
        resolve();
        return;
      }

      if (Date.now() - startedAt >= timeoutMs) {
        reject(new Error(`Timed out after ${timeoutMs}ms waiting for condition`));
        return;
      }

      setTimeout(poll, intervalMs);
    };

    poll();
  });
}

test("CLI build copies local assets into .notch/build/assets", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-assets-copy-");
  const assetPath = path.join(widgetDir, "assets", "covers", "hero.txt");
  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return null;
    }
  `);

  fs.mkdirSync(path.dirname(assetPath), { recursive: true });
  fs.writeFileSync(assetPath, "cover-art");

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.equal(
    fs.readFileSync(path.join(widgetDir, ".notch", "build", "assets", "covers", "hero.txt"), "utf8"),
    "cover-art"
  );
});

test("CLI build removes stale copied assets when the source assets directory disappears", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-assets-prune-");
  const sourceAssetsDir = path.join(widgetDir, "assets");
  const builtAssetPath = path.join(widgetDir, ".notch", "build", "assets", "icon.txt");
  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return null;
    }
  `);

  fs.mkdirSync(sourceAssetsDir, { recursive: true });
  fs.writeFileSync(path.join(sourceAssetsDir, "icon.txt"), "present");

  let result = await runCli(["build"], { cwd: widgetDir });
  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.equal(fs.existsSync(builtAssetPath), true);

  fs.rmSync(sourceAssetsDir, { recursive: true, force: true });

  result = await runCli(["build"], { cwd: widgetDir });
  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.equal(fs.existsSync(builtAssetPath), false);
});

test("CLI build preserves the last good bundle when asset copying fails", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-assets-staging-");
  const sourceAssetsDir = path.join(widgetDir, "assets");
  const builtBundlePath = path.join(widgetDir, ".notch", "build", "index.cjs");
  const builtAssetPath = path.join(widgetDir, ".notch", "build", "assets", "icon.txt");

  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return "version-one";
    }
  `);

  fs.mkdirSync(sourceAssetsDir, { recursive: true });
  fs.writeFileSync(path.join(sourceAssetsDir, "icon.txt"), "present");

  let result = await runCli(["build"], { cwd: widgetDir });
  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(fs.readFileSync(builtBundlePath, "utf8"), /version-one/);
  assert.equal(fs.readFileSync(builtAssetPath, "utf8"), "present");

  fs.writeFileSync(path.join(widgetDir, "src", "index.js"), `
    export default function Widget() {
      return "version-two";
    }
  `);
  fs.rmSync(sourceAssetsDir, { recursive: true, force: true });
  fs.mkdirSync(sourceAssetsDir, { recursive: true });
  fs.symlinkSync(path.join(widgetDir, "missing.txt"), path.join(sourceAssetsDir, "broken.txt"));

  result = await runCli(["build"], { cwd: widgetDir });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr || result.stdout, /ENOENT|broken\.txt/);
  assert.match(fs.readFileSync(builtBundlePath, "utf8"), /version-one/);
  assert.equal(fs.readFileSync(builtAssetPath, "utf8"), "present");
});

test("CLI dev rebuilds when assets are added after startup", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-assets-dev-");
  const fakeHome = createTempDir(t, "notch-cli-home-");
  const builtBundlePath = path.join(widgetDir, ".notch", "build", "index.cjs");
  const builtAssetPath = path.join(widgetDir, ".notch", "build", "assets", "late.txt");

  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return null;
    }
  `);

  const child = spawn(process.execPath, [cliPath, "dev"], {
    cwd: widgetDir,
    env: { ...process.env, HOME: fakeHome },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  const stopChild = async () => {
    if (child.exitCode != null) {
      return;
    }

    child.kill("SIGTERM");
    await Promise.race([
      new Promise((resolve) => child.once("close", resolve)),
      new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);

    if (child.exitCode == null) {
      child.kill("SIGKILL");
      await new Promise((resolve) => child.once("close", resolve));
    }
  };

  t.after(async () => {
    await stopChild();
  });

  await waitFor(() => fs.existsSync(builtBundlePath), 10000);

  fs.mkdirSync(path.join(widgetDir, "assets"), { recursive: true });
  fs.writeFileSync(path.join(widgetDir, "assets", "late.txt"), "late");

  await waitFor(() => fs.existsSync(builtAssetPath), 10000);
  assert.equal(fs.readFileSync(builtAssetPath, "utf8"), "late");
  assert.equal(stderr, "", stderr);
  assert.match(stdout, /Built tmp\.widget ->/);
});
