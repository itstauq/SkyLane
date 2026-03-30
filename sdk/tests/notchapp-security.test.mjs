import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const sdkRoot = path.resolve(testDir, "..");
const repoRoot = path.resolve(sdkRoot, "..");
const cliPath = path.join(repoRoot, "sdk", "packages", "notchapp", "cli.mjs");
const securityModuleUrl = pathToFileURL(path.join(repoRoot, "runtime", "security.mjs")).href;

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
      resolve({
        code,
        signal,
        stdout,
        stderr,
      });
    });
  });
}

function runCli(args, options = {}) {
  return runProcess(process.execPath, [cliPath, ...args], options);
}

function runNodeEval(script, options = {}) {
  return runProcess(process.execPath, ["--input-type=module", "--eval", script], options);
}

test("runtime security allows the entry bundle and blocks nested path requires", async (t) => {
  const dir = createTempDir(t, "notch-runtime-security-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const secretPath = path.join(dir, "secret.json");

  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    const bundlePath = ${JSON.stringify(bundlePath)};
    fs.writeFileSync(${JSON.stringify(secretPath)}, JSON.stringify({ secret: true }));
    fs.writeFileSync(
      bundlePath,
      'module.exports.default = () => require(__dirname + "/secret.json");\\n'
    );

    const internalRequire = Module.createRequire(import.meta.url);
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([bundlePath]),
    });

    const widgetModule = internalRequire(bundlePath);
    console.log("entry", typeof widgetModule.default);

    try {
      widgetModule.default();
      console.log("nested unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("nested", error.message);
    }
  `, { cwd: repoRoot });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /entry function/);
  assert.match(
    result.stdout,
    /nested Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("CLI build accepts allowed built-in subpath imports", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-allowed-");
  const outfile = path.join(widgetDir, ".notch", "build", "index.cjs");
  writeWidgetFixture(widgetDir, `
    import posix from "node:path/posix";
    import utilTypes from "node:util/types";

    export default function Widget() {
      return posix.join("a", "b") + String(typeof utilTypes.isAsyncFunction);
    }
  `);

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.ok(fs.existsSync(outfile));
  const emitted = fs.readFileSync(outfile, "utf8");
  assert.match(emitted, /require\("node:path\/posix"\)|require\("path\/posix"\)/);
  assert.match(emitted, /require\("node:util\/types"\)|require\("util\/types"\)/);
});

test("CLI build bundles vendored packages whose names match built-ins", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-vendored-builtin-name-");
  const outfile = path.join(widgetDir, ".notch", "build", "index.cjs");
  writeWidgetFixture(widgetDir, `
    import value from "buffer";

    export default function Widget() {
      return value;
    }
  `);

  fs.mkdirSync(path.join(widgetDir, "node_modules", "buffer"), { recursive: true });
  fs.writeFileSync(
    path.join(widgetDir, "node_modules", "buffer", "package.json"),
    JSON.stringify({
      name: "buffer",
      version: "1.0.0",
      main: "index.js",
    }, null, 2)
  );
  fs.writeFileSync(
    path.join(widgetDir, "node_modules", "buffer", "index.js"),
    'module.exports = "vendored-buffer-package";\n'
  );

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.ok(fs.existsSync(outfile));
  const emitted = fs.readFileSync(outfile, "utf8");
  assert.doesNotMatch(emitted, /require\("node:buffer"\)|require\("buffer"\)/);
  assert.match(emitted, /vendored-buffer-package/);
});

test("CLI build bundles vendored builtin-like package subpaths", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-vendored-builtin-subpath-");
  const outfile = path.join(widgetDir, ".notch", "build", "index.cjs");
  writeWidgetFixture(widgetDir, `
    import { value } from "events/sub";

    export default function Widget() {
      return value;
    }
  `);

  fs.mkdirSync(path.join(widgetDir, "node_modules", "events"), { recursive: true });
  fs.writeFileSync(
    path.join(widgetDir, "node_modules", "events", "package.json"),
    JSON.stringify({
      name: "events",
      version: "1.0.0",
      main: "index.js",
      exports: {
        "./sub": "./sub.js",
      },
    }, null, 2)
  );
  fs.writeFileSync(
    path.join(widgetDir, "node_modules", "events", "index.js"),
    "exports.root = true;\n"
  );
  fs.writeFileSync(
    path.join(widgetDir, "node_modules", "events", "sub.js"),
    'exports.value = "vendored-events-subpath";\n'
  );

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.ok(fs.existsSync(outfile));
  const emitted = fs.readFileSync(outfile, "utf8");
  assert.doesNotMatch(emitted, /require\("node:events\/sub"\)|require\("events\/sub"\)/);
  assert.match(emitted, /vendored-events-subpath/);
});

test("CLI build rejects blocked built-in modules", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-blocked-");
  writeWidgetFixture(widgetDir, `
    import fs from "node:fs";

    export default function Widget() {
      return Boolean(fs);
    }
  `);

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.notEqual(result.code, 0);
  assert.match(
    result.stderr + result.stdout,
    /Built-in module "node:fs" is not available in the widget runtime\./
  );
  assert.equal(fs.existsSync(path.join(widgetDir, ".notch", "build", "index.cjs")), false);
});

test("CLI build rejects blocked built-in subpath imports", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-blocked-subpath-");
  writeWidgetFixture(widgetDir, `
    import webcrypto from "crypto/webcrypto";

    export default function Widget() {
      return Boolean(webcrypto);
    }
  `);

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.notEqual(result.code, 0);
  assert.match(
    result.stderr + result.stdout,
    /Built-in module "crypto\/webcrypto" is not available in the widget runtime\./
  );
  assert.equal(fs.existsSync(path.join(widgetDir, ".notch", "build", "index.cjs")), false);
});

test("CLI build rejects buffer slash imports too", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-buffer-slash-");
  writeWidgetFixture(widgetDir, `
    import badBuffer from "buffer/";

    export default function Widget() {
      return Boolean(badBuffer);
    }
  `);

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.notEqual(result.code, 0);
  assert.match(
    result.stderr + result.stdout,
    /Built-in module "buffer\/" is not available in the widget runtime\./
  );
  assert.equal(fs.existsSync(path.join(widgetDir, ".notch", "build", "index.cjs")), false);
});

test("CLI build allows literal import text when no dynamic import is present", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-literal-import-");
  const outfile = path.join(widgetDir, ".notch", "build", "index.cjs");
  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return "literal import(";
    }
  `);

  const result = await runCli(["build"], { cwd: widgetDir });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.ok(fs.existsSync(outfile));
});

test("CLI preserves the last good bundle when dynamic import validation fails", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-staging-");
  const buildDir = path.join(widgetDir, ".notch", "build");
  const outfile = path.join(buildDir, "index.cjs");
  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return 1;
    }
  `);

  const initialBuild = await runCli(["build"], { cwd: widgetDir });
  assert.equal(initialBuild.code, 0, initialBuild.stderr || initialBuild.stdout);
  const originalBundle = fs.readFileSync(outfile, "utf8");

  writeWidgetFixture(widgetDir, `
    export default async function Widget() {
      return import("node:path");
    }
  `);

  const failedBuild = await runCli(["build"], { cwd: widgetDir });

  assert.notEqual(failedBuild.code, 0);
  assert.equal(fs.readFileSync(outfile, "utf8"), originalBundle);
  assert.deepEqual(
    fs.readdirSync(buildDir).filter((entry) => entry.includes(".staging.")),
    []
  );
  assert.match(
    failedBuild.stderr + failedBuild.stdout,
    /Dynamic import is unsupported in the widget runtime\./
  );
});

test("CLI preserves the last good bundle when builtin policy rejects a rebuild", async (t) => {
  const widgetDir = createTempDir(t, "notch-cli-plugin-failure-");
  const buildDir = path.join(widgetDir, ".notch", "build");
  const outfile = path.join(buildDir, "index.cjs");
  writeWidgetFixture(widgetDir, `
    export default function Widget() {
      return 1;
    }
  `);

  const initialBuild = await runCli(["build"], { cwd: widgetDir });
  assert.equal(initialBuild.code, 0, initialBuild.stderr || initialBuild.stdout);
  const originalBundle = fs.readFileSync(outfile, "utf8");

  writeWidgetFixture(widgetDir, `
    import webcrypto from "crypto/webcrypto";

    export default function Widget() {
      return Boolean(webcrypto);
    }
  `);

  const failedBuild = await runCli(["build"], { cwd: widgetDir });

  assert.notEqual(failedBuild.code, 0);
  assert.equal(fs.readFileSync(outfile, "utf8"), originalBundle);
  assert.deepEqual(
    fs.readdirSync(buildDir).filter((entry) => entry.includes(".staging.")),
    []
  );
  assert.match(
    failedBuild.stderr + failedBuild.stdout,
    /Built-in module "crypto\/webcrypto" is not available in the widget runtime\./
  );
});
