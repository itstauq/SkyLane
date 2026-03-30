import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  prepareWidgetBundleSource,
  WIDGET_PRELUDE_LINE_COUNT,
} from "../widget-loader.mjs";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const runtimeRoot = path.resolve(testDir, "..");
const securityModuleUrl = pathToFileURL(path.join(runtimeRoot, "security.mjs")).href;
const widgetLoaderModuleUrl = pathToFileURL(path.join(runtimeRoot, "widget-loader.mjs")).href;

function createTempDir(t, prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

function runNodeEval(script, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--input-type=module", "--eval", script], {
      cwd: runtimeRoot,
      env: options.env ?? process.env,
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

test("installRuntimeSecurity allows the trusted entry path and blocks nested path requires", async (t) => {
  const dir = createTempDir(t, "notch-runtime-entry-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const nestedPath = path.join(dir, "secret.json");

  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    const bundlePath = ${JSON.stringify(bundlePath)};
    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
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
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /entry function/);
  assert.match(
    result.stdout,
    /nested Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity allows approved built-in subpaths", async () => {
  const result = await runNodeEval(`
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const require = Module.createRequire(import.meta.url);
    const posix = require("node:path/posix");
    const utilTypes = require("node:util/types");
    console.log("path", posix.join("a", "b"));
    console.log("util", typeof utilTypes.isAsyncFunction);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /path a\/b/);
  assert.match(result.stdout, /util function/);
});

test("installRuntimeSecurity still resolves runtime-provided modules", async () => {
  const reactPath = path.join(runtimeRoot, "node_modules", "react", "index.js");
  const result = await runNodeEval(`
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map([["react", ${JSON.stringify(reactPath)}]]),
    });

    const require = Module.createRequire(import.meta.url);
    const React = require("react");
    console.log("react", typeof React.createElement);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /react function/);
});

test("installRuntimeSecurity preserves NODE_ENV for runtime-owned React loading", async () => {
  const reactShimPath = path.join(runtimeRoot, "react-shim.cjs");
  const result = await runNodeEval(`
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map([["react", ${JSON.stringify(reactShimPath)}]]),
    });

    const require = Module.createRequire(import.meta.url);
    require("react");
    const cacheKeys = Object.keys(require.cache);
    console.log("nodeEnv", process.env.NODE_ENV);
    console.log("prod", cacheKeys.some((key) => key.endsWith("react.production.min.js")));
    console.log("dev", cacheKeys.some((key) => key.endsWith("react.development.js")));
  `, {
    env: {
      ...process.env,
      NODE_ENV: "production",
    },
  });

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /nodeEnv production/);
  assert.match(result.stdout, /prod true/);
  assert.match(result.stdout, /dev false/);
});

test("widget bundle loading hides WebAssembly without mutating the runtime global", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-globals-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    const bundlePath = ${JSON.stringify(bundlePath)};
    await import("node:fs").then(({ default: fs }) => {
      fs.writeFileSync(
        bundlePath,
        'module.exports = {\\n'
          + '  wasmType: typeof WebAssembly,\\n'
          + '  globalWasmType: typeof globalThis.WebAssembly,\\n'
          + '  selfWasmType: typeof self.WebAssembly,\\n'
          + '  hasWasm: "WebAssembly" in globalThis,\\n'
          + '  hasWebSocket: "WebSocket" in globalThis,\\n'
          + '  hasSharedArrayBuffer: "SharedArrayBuffer" in globalThis,\\n'
          + '  hasAtomics: "Atomics" in globalThis,\\n'
          + '  descriptorType: typeof Object.getOwnPropertyDescriptor(globalThis, "WebAssembly"),\\n'
          + '  globalDescriptorWasmType: typeof Object.getOwnPropertyDescriptor(globalThis, "globalThis").value.WebAssembly,\\n'
          + '  globalDescriptorSelfType: typeof Object.getOwnPropertyDescriptor(globalThis, "self").value.WebAssembly,\\n'
          + '  accessorLeakType: (() => {\\n'
          + '    Object.defineProperty(globalThis, "leak", {\\n'
          + '      configurable: true,\\n'
          + '      get() { return this.WebAssembly; },\\n'
          + '    });\\n'
          + '    const value = typeof globalThis.leak;\\n'
          + '    delete globalThis.leak;\\n'
          + '    return value;\\n'
          + '  })(),\\n'
          + '  descriptorGetterLeakType: (() => {\\n'
          + '    Object.defineProperty(globalThis, "leak", {\\n'
          + '      configurable: true,\\n'
          + '      get() { return this.WebAssembly; },\\n'
          + '    });\\n'
          + '    const getter = Object.getOwnPropertyDescriptor(globalThis, "leak").get;\\n'
          + '    const value = typeof getter();\\n'
          + '    delete globalThis.leak;\\n'
          + '    return value;\\n'
          + '  })(),\\n'
          + '  plainFunctionThisLeakType: (() => {\\n'
          + '    const wasm = function () { return this?.WebAssembly; }();\\n'
          + '    return typeof wasm;\\n'
          + '  })(),\\n'
          + '  cryptoUUIDType: typeof crypto.randomUUID(),\\n'
          + '  cryptoBufferLength: (() => {\\n'
          + '    const bytes = new Uint8Array(8);\\n'
          + '    globalThis.crypto.getRandomValues(bytes);\\n'
          + '    return bytes.length;\\n'
          + '  })(),\\n'
          + '  leakedHelperType: typeof __notchRealGlobalThis,\\n'
          + '  leakedScopeType: typeof __notchWidgetScope,\\n'
          + '};\\n'
      );
    });

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([bundlePath]),
    });

    console.log("outside", typeof globalThis.WebAssembly);
    const widgetModule = loadWidgetBundle(bundlePath);
    console.log("inside wasm", widgetModule.wasmType);
    console.log("inside global", widgetModule.globalWasmType);
    console.log("inside self", widgetModule.selfWasmType);
    console.log("inside has", widgetModule.hasWasm);
    console.log("inside has websocket", widgetModule.hasWebSocket);
    console.log("inside has sab", widgetModule.hasSharedArrayBuffer);
    console.log("inside has atomics", widgetModule.hasAtomics);
    console.log("inside descriptor", widgetModule.descriptorType);
    console.log("inside global descriptor", widgetModule.globalDescriptorWasmType);
    console.log("inside self descriptor", widgetModule.globalDescriptorSelfType);
    console.log("inside accessor", widgetModule.accessorLeakType);
    console.log("inside descriptor accessor", widgetModule.descriptorGetterLeakType);
    console.log("inside plain function", widgetModule.plainFunctionThisLeakType);
    console.log("inside crypto uuid", widgetModule.cryptoUUIDType);
    console.log("inside crypto bytes", widgetModule.cryptoBufferLength);
    console.log("inside helper", widgetModule.leakedHelperType);
    console.log("inside scope", widgetModule.leakedScopeType);
    console.log("outside after", typeof globalThis.WebAssembly);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /outside object/);
  assert.match(result.stdout, /inside wasm undefined/);
  assert.match(result.stdout, /inside global undefined/);
  assert.match(result.stdout, /inside self undefined/);
  assert.match(result.stdout, /inside has false/);
  assert.match(result.stdout, /inside has websocket false/);
  assert.match(result.stdout, /inside has sab false/);
  assert.match(result.stdout, /inside has atomics false/);
  assert.match(result.stdout, /inside descriptor undefined/);
  assert.match(result.stdout, /inside global descriptor undefined/);
  assert.match(result.stdout, /inside self descriptor undefined/);
  assert.match(result.stdout, /inside accessor undefined/);
  assert.match(result.stdout, /inside descriptor accessor undefined/);
  assert.match(result.stdout, /inside plain function undefined/);
  assert.match(result.stdout, /inside crypto uuid string/);
  assert.match(result.stdout, /inside crypto bytes 8/);
  assert.match(result.stdout, /inside helper undefined/);
  assert.match(result.stdout, /inside scope undefined/);
  assert.match(result.stdout, /outside after object/);
});

test("widget bundle loading still allows local global-like identifiers", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-locals-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      '"use strict";\\n'
        + 'const globalThis = { sentinel: 1 };\\n'
        + 'const self = { sentinel: 2 };\\n'
        + 'const WebAssembly = 3;\\n'
        + 'module.exports = { globalThis, self, WebAssembly };\\n'
    );

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    const loaded = loadWidgetBundle(${JSON.stringify(bundlePath)});
    console.log("globalThis", loaded.globalThis.sentinel);
    console.log("self", loaded.self.sentinel);
    console.log("wasm", loaded.WebAssembly);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /globalThis 1/);
  assert.match(result.stdout, /self 2/);
  assert.match(result.stdout, /wasm 3/);
});

test("widget bundle loading keeps global deletions scoped to the widget overlay", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-deletes-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      'module.exports = {\\n'
        + '  deletedPerformance: delete globalThis.performance,\\n'
        + '  insidePerformanceType: typeof globalThis.performance,\\n'
        + '  insideBarePerformanceType: typeof performance,\\n'
        + '  deletedFetch: delete globalThis.fetch,\\n'
        + '  insideFetchType: typeof globalThis.fetch,\\n'
        + '  insideBareFetchType: typeof fetch,\\n'
        + '  deletedStructuredClone: delete globalThis.structuredClone,\\n'
        + '  insideStructuredCloneType: typeof globalThis.structuredClone,\\n'
        + '};\\n'
    );

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    const loaded = loadWidgetBundle(${JSON.stringify(bundlePath)});
    console.log("deleted performance", loaded.deletedPerformance);
    console.log("inside performance", loaded.insidePerformanceType);
    console.log("inside bare performance", loaded.insideBarePerformanceType);
    console.log("deleted fetch", loaded.deletedFetch);
    console.log("inside fetch", loaded.insideFetchType);
    console.log("inside bare fetch", loaded.insideBareFetchType);
    console.log("deleted structuredClone", loaded.deletedStructuredClone);
    console.log("inside structuredClone", loaded.insideStructuredCloneType);
    console.log("outside performance", typeof globalThis.performance);
    console.log("outside fetch", typeof globalThis.fetch);
    console.log("outside structuredClone", typeof globalThis.structuredClone);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /deleted performance true/);
  assert.match(result.stdout, /inside performance undefined/);
  assert.match(result.stdout, /inside bare performance undefined/);
  assert.match(result.stdout, /deleted fetch true/);
  assert.match(result.stdout, /inside fetch undefined/);
  assert.match(result.stdout, /inside bare fetch undefined/);
  assert.match(result.stdout, /deleted structuredClone true/);
  assert.match(result.stdout, /inside structuredClone undefined/);
  assert.match(result.stdout, /outside performance object/);
  assert.match(result.stdout, /outside fetch function/);
  assert.match(result.stdout, /outside structuredClone function/);
});

test("widget bundle loading exposes runtime-owned globals through configurable proxy descriptors", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-descriptors-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      'const processDescriptor = Object.getOwnPropertyDescriptor(globalThis, "process");\\n'
        + 'module.exports = {\\n'
        + '  processOwn: Object.prototype.hasOwnProperty.call(globalThis, "process"),\\n'
        + '  processDescriptorConfigurable: processDescriptor.configurable,\\n'
        + '  processDescriptorWritable: processDescriptor.writable,\\n'
        + '};\\n'
    );

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    const loaded = loadWidgetBundle(${JSON.stringify(bundlePath)});
    console.log("process own", loaded.processOwn);
    console.log("process configurable", loaded.processDescriptorConfigurable);
    console.log("process writable", loaded.processDescriptorWritable);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /process own true/);
  assert.match(result.stdout, /process configurable true/);
  assert.match(result.stdout, /process writable false/);
});

test("widget bundle loading shadows runtime-owned globals without mutating the runtime global", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-shadows-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      '"use strict";\\n'
        + 'globalThis.fetch = () => 123;\\n'
        + 'module.exports = {\\n'
        + '  insideFetchValue: globalThis.fetch(),\\n'
        + '  insideFetchType: typeof fetch,\\n'
        + '};\\n'
    );

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    Object.defineProperty(globalThis, "fetch", {
      value: () => 1,
      enumerable: true,
      configurable: true,
      writable: false,
    });

    const loaded = loadWidgetBundle(${JSON.stringify(bundlePath)});
    console.log("inside fetch value", loaded.insideFetchValue);
    console.log("inside fetch type", loaded.insideFetchType);
    console.log("outside fetch value", globalThis.fetch());
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /inside fetch value 123/);
  assert.match(result.stdout, /inside fetch type function/);
  assert.match(result.stdout, /outside fetch value 1/);
});

test("widget bundle loading preserves CommonJS parent and top-level arguments", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-cjs-wrapper-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      'module.exports = {\\n'
        + '  parentType: typeof module.parent,\\n'
        + '  parentTruthy: Boolean(module.parent),\\n'
        + '  argumentsLength: arguments.length,\\n'
        + '  requireMatches: arguments[1] === require,\\n'
        + '  moduleMatches: arguments[2] === module,\\n'
        + '  filenameMatches: arguments[3] === __filename,\\n'
        + '  dirnameMatches: arguments[4] === __dirname,\\n'
        + '};\\n'
    );

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    const loaded = loadWidgetBundle(${JSON.stringify(bundlePath)});
    console.log("parent type", loaded.parentType);
    console.log("parent truthy", loaded.parentTruthy);
    console.log("arguments length", loaded.argumentsLength);
    console.log("require matches", loaded.requireMatches);
    console.log("module matches", loaded.moduleMatches);
    console.log("filename matches", loaded.filenameMatches);
    console.log("dirname matches", loaded.dirnameMatches);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /parent type object/);
  assert.match(result.stdout, /parent truthy true/);
  assert.match(result.stdout, /arguments length 5/);
  assert.match(result.stdout, /require matches true/);
  assert.match(result.stdout, /module matches true/);
  assert.match(result.stdout, /filename matches true/);
  assert.match(result.stdout, /dirname matches true/);
});

test("worker bootstrap keeps runtime fetch deletable at the widget layer", async (t) => {
  const dir = createTempDir(t, "notch-runtime-worker-fetch-delete-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const workerModuleUrl = pathToFileURL(path.join(runtimeRoot, "worker.mjs")).href;
  fs.writeFileSync(
    bundlePath,
    '"use strict";\n'
      + 'const deletedFetch = delete globalThis.fetch;\n'
      + 'const fetchType = typeof fetch;\n'
      + 'if (!deletedFetch) throw new Error("delete fetch returned false");\n'
      + 'if (fetchType !== "undefined") throw new Error(`fetch remained ${fetchType}`);\n'
      + 'module.exports.default = function Widget() { return null; };\n'
  );

  const result = await runNodeEval(`
    import { Worker } from "node:worker_threads";
    import { URL } from "node:url";

    const worker = new Worker(new URL(${JSON.stringify(workerModuleUrl)}), {
      execArgv: [],
      type: "module",
      workerData: {
        widgetId: "test.widget",
        instanceId: "instance-1",
        sessionId: "session-1",
        bundlePath: ${JSON.stringify(bundlePath)},
        props: {},
      },
    });

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        worker.terminate().catch(() => {});
        reject(new Error("Timed out waiting for worker"));
      }, 5000);

      worker.on("message", (message) => {
        if (message?.method === "rpc" && message.params?.method === "localStorage.allItems") {
          worker.postMessage({
            jsonrpc: "2.0",
            id: message.id,
            result: {},
          });
          return;
        }

        if (message?.method === "render") {
          console.log("render ok");
          worker.postMessage({
            jsonrpc: "2.0",
            method: "shutdown",
          });
          return;
        }

        if (message?.method === "error") {
          clearTimeout(timeout);
          reject(new Error(message.params?.error?.message ?? "Worker reported an error"));
        }
      });

      worker.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });

      worker.on("exit", (code) => {
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(\`Worker exited with code \${code}\`));
          return;
        }
        resolve();
      });
    });
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /render ok/);
});

test("widget bundle loading rejects dynamic import in prebuilt bundles", async (t) => {
  const dir = createTempDir(t, "notch-runtime-widget-dynamic-import-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};
    import { loadWidgetBundle } from ${JSON.stringify(widgetLoaderModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      'module.exports = async function Widget() {\\n'
        + '  return import("node:fs");\\n'
        + '};\\n'
    );

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    try {
      loadWidgetBundle(${JSON.stringify(bundlePath)});
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Dynamic import is unsupported in the widget runtime\..*bundle\.cjs still contains import\(\.\.\.\)\./
  );
  assert.doesNotMatch(result.stdout, /unexpected/);
});

test("prepareWidgetBundleSource shifts trailing inline source maps by the wrapper line count", () => {
  const sourceMap = {
    version: 3,
    sources: ["widget.js"],
    sourcesContent: ['console.log("line 1");\nthrow new Error("boom");\n'],
    names: [],
    mappings: "AAAA;AACA",
  };
  const inlineSourceMap = Buffer.from(JSON.stringify(sourceMap), "utf8").toString("base64");
  const wrappedSource = prepareWidgetBundleSource(
    `console.log("line 1");\nthrow new Error("boom");\n//# sourceMappingURL=data:application/json;charset=utf-8;base64,${inlineSourceMap}`
  );

  const sourceMapMatch = wrappedSource.match(
    /\/\/# sourceMappingURL=data:application\/json;charset=utf-8;base64,([A-Za-z0-9+/=]+)\s*$/
  );

  assert.ok(sourceMapMatch);
  const adjustedSourceMap = JSON.parse(
    Buffer.from(sourceMapMatch[1], "base64").toString("utf8")
  );
  assert.equal(
    adjustedSourceMap.mappings,
    `${";".repeat(WIDGET_PRELUDE_LINE_COUNT)}${sourceMap.mappings}`
  );
});

test("installRuntimeSecurity blocks disallowed built-ins", async () => {
  const result = await runNodeEval(`
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const require = Module.createRequire(import.meta.url);
    try {
      require("node:fs");
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Module "node:fs" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity blocks file URL and require.resolve path specifiers", async (t) => {
  const dir = createTempDir(t, "notch-runtime-path-specifiers-");
  const nestedPath = path.join(dir, "secret.json");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { pathToFileURL } from "node:url";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const require = Module.createRequire(import.meta.url);
    for (const probe of [
      () => require.resolve(${JSON.stringify(`./${path.basename(nestedPath)}`)}),
      () => require(pathToFileURL(${JSON.stringify(nestedPath)}).href),
    ]) {
      try {
        probe();
        console.log("unexpected");
        process.exitCode = 1;
      } catch (error) {
        console.log("blocked", error.message);
      }
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /blocked Path specifier "\.\/secret\.json" is not available in the widget runtime\./);
  assert.match(result.stdout, /blocked Path specifier "file:.*secret\.json" is not available in the widget runtime\./);
});

test("installRuntimeSecurity does not trust caller-controlled createRequire filenames", async (t) => {
  const dir = createTempDir(t, "notch-runtime-create-require-");
  const nestedPath = path.join(dir, "secret.json");
  const workerPath = path.join(runtimeRoot, "worker.mjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map([["react-shim", ${JSON.stringify(path.join(runtimeRoot, "react-shim.cjs"))}]])
    });

    const forgedRequire = Module.createRequire(${JSON.stringify(workerPath)});
    try {
      forgedRequire(${JSON.stringify(nestedPath)});
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity does not trust forged parent objects in Module._load", async (t) => {
  const dir = createTempDir(t, "notch-runtime-forged-parent-");
  const nestedPath = path.join(dir, "secret.json");
  const workerPath = path.join(runtimeRoot, "worker.mjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map([["react-shim", ${JSON.stringify(path.join(runtimeRoot, "react-shim.cjs"))}]])
    });

    try {
      Module._load(${JSON.stringify(nestedPath)}, { filename: ${JSON.stringify(workerPath)} }, false);
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity does not trust runtime modules leaked through require.cache", async (t) => {
  const dir = createTempDir(t, "notch-runtime-cache-parent-");
  const nestedPath = path.join(dir, "secret.json");
  const reactShimPath = path.join(runtimeRoot, "react-shim.cjs");
  const reactPath = path.join(runtimeRoot, "node_modules", "react", "index.js");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map([
        ["react", ${JSON.stringify(reactShimPath)}],
        ["react/jsx-runtime", ${JSON.stringify(path.join(runtimeRoot, "node_modules", "react", "jsx-runtime.js"))}],
      ]),
    });

    const require = Module.createRequire(import.meta.url);
    require("react");
    const trustedParent = Object.values(require.cache).find((cachedModule) => (
      cachedModule?.filename === ${JSON.stringify(reactShimPath)}
        || cachedModule?.filename === ${JSON.stringify(reactPath)}
    ));

    if (!trustedParent) {
      console.log("missing trusted parent");
      process.exitCode = 1;
    } else {
      try {
        Module._load(${JSON.stringify(nestedPath)}, trustedParent, false);
        console.log("unexpected");
        process.exitCode = 1;
      } catch (error) {
        console.log("blocked", error.message);
      }
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.doesNotMatch(result.stdout, /missing trusted parent/);
  assert.match(
    result.stdout,
    /blocked Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity does not open a trust window for cached runtime modules", async (t) => {
  const dir = createTempDir(t, "notch-runtime-cache-rerequire-");
  const nestedPath = path.join(dir, "secret.json");
  const reactShimPath = path.join(runtimeRoot, "react-shim.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map([["react", ${JSON.stringify(reactShimPath)}]]),
    });

    const require = Module.createRequire(import.meta.url);
    require("react");

    const cachedModule = require.cache[${JSON.stringify(reactShimPath)}];
    const originalExports = cachedModule.exports;
    Object.defineProperty(cachedModule, "exports", {
      configurable: true,
      enumerable: true,
      get() {
        try {
          Module._load(${JSON.stringify(nestedPath)}, { filename: ${JSON.stringify(reactShimPath)} }, false);
          console.log("unexpected");
          process.exitCode = 1;
        } catch (error) {
          console.log("blocked", error.message);
        }

        return originalExports;
      },
    });

    require("react");
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
  assert.doesNotMatch(result.stdout, /unexpected/);
});

test("installRuntimeSecurity blocks direct Module.prototype.load escapes", async (t) => {
  const dir = createTempDir(t, "notch-runtime-module-load-");
  const nestedPath = path.join(dir, "secret.json");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const FreshModule = Module.Module ?? Module;
    const attackerModule = new FreshModule(${JSON.stringify(nestedPath)});
    attackerModule.filename = ${JSON.stringify(nestedPath)};
    attackerModule.paths = [];

    try {
      attackerModule.load(${JSON.stringify(nestedPath)});
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity blocks direct Module._extensions loader escapes", async (t) => {
  const dir = createTempDir(t, "notch-runtime-module-extensions-");
  const nestedPath = path.join(dir, "secret.json");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(${JSON.stringify(nestedPath)}, JSON.stringify({ secret: true }));
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const FreshModule = Module.Module ?? Module;
    const attackerModule = new FreshModule(${JSON.stringify(nestedPath)});
    attackerModule.filename = ${JSON.stringify(nestedPath)};
    attackerModule.paths = [];

    try {
      FreshModule._extensions[".json"](attackerModule, ${JSON.stringify(nestedPath)});
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked Path specifier ".*secret\.json" is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity blocks direct module._compile escapes", async (t) => {
  const result = await runNodeEval(`
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const FreshModule = Module.Module ?? Module;
    const attackerModule = new FreshModule("/tmp/evil.cjs");

    try {
      attackerModule._compile("module.exports = 40 + 2;", "/tmp/evil.cjs");
      console.log("unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("blocked", error.message);
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /blocked module\._compile is not available in the widget runtime\./
  );
});

test("installRuntimeSecurity blocks top-level recursive module._compile escapes", async (t) => {
  const dir = createTempDir(t, "notch-runtime-compile-recursive-");
  const bundlePath = path.join(dir, "bundle.cjs");
  const result = await runNodeEval(`
    import fs from "node:fs";
    import Module from "node:module";
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    fs.writeFileSync(
      ${JSON.stringify(bundlePath)},
      'try {\\n'
        + '  module._compile("module.exports = 42;", "/tmp/evil.cjs");\\n'
        + '  console.log("unexpected");\\n'
        + '  process.exitCode = 1;\\n'
        + '} catch (error) {\\n'
        + '  console.log("blocked", error.message);\\n'
        + '}\\n'
        + 'module.exports = "ok";\\n'
    );

    const internalRequire = Module.createRequire(import.meta.url);
    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
      allowedPathSpecifiers: new Set([${JSON.stringify(bundlePath)}]),
    });

    const loaded = internalRequire(${JSON.stringify(bundlePath)});
    console.log("loaded", loaded);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /blocked module\._compile is not available in the widget runtime\./);
  assert.match(result.stdout, /loaded ok/);
  assert.doesNotMatch(result.stdout, /unexpected/);
});

test("installRuntimeSecurity blocks dynamic code execution primitives", async () => {
  const result = await runNodeEval(`
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    for (const probe of [
      () => Function("return 1"),
      () => (async () => {}).constructor("return 1"),
      () => eval("1 + 1"),
      () => setTimeout("1 + 1", 0),
      () => setInterval("1 + 1", 0),
    ]) {
      try {
        probe();
        console.log("unexpected");
        process.exitCode = 1;
      } catch (error) {
        console.log("blocked", error.message);
      }
    }
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /blocked Function is not available in the widget runtime\./);
  assert.match(result.stdout, /blocked Function is not available in the widget runtime\./);
  assert.match(result.stdout, /blocked eval is not available in the widget runtime\./);
  assert.match(
    result.stdout,
    /blocked setTimeout does not allow string callbacks in the widget runtime\./
  );
  assert.match(
    result.stdout,
    /blocked setInterval does not allow string callbacks in the widget runtime\./
  );
});

test("installRuntimeSecurity preserves safe Function introspection and hrtime.bigint", async () => {
  const result = await runNodeEval(`
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    const fn = () => 1;
    console.log("instanceof", fn instanceof Function);
    console.log("constructor", Function.prototype.constructor === Function);
    console.log("call", typeof Function.prototype.call);
    console.log("apply", typeof Function.prototype.apply);
    console.log("bind", typeof Function.prototype.bind);
    console.log("hrtime bigint", typeof process.hrtime.bigint);
    console.log("hrtime bigint value", typeof process.hrtime.bigint());
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /instanceof true/);
  assert.match(result.stdout, /constructor true/);
  assert.match(result.stdout, /call function/);
  assert.match(result.stdout, /apply function/);
  assert.match(result.stdout, /bind function/);
  assert.match(result.stdout, /hrtime bigint function/);
  assert.match(result.stdout, /hrtime bigint value bigint/);
});

test("installRuntimeSecurity exposes blocked globals as unavailable when appropriate", async () => {
  const result = await runNodeEval(`
    import { installRuntimeSecurity } from ${JSON.stringify(securityModuleUrl)};

    installRuntimeSecurity({
      realProcess: globalThis.process,
      runtimeModuleMap: new Map(),
    });

    try {
      globalThis.WebSocket = function nope() {};
      console.log("assign unexpected", typeof globalThis.WebSocket);
      process.exitCode = 1;
    } catch (error) {
      console.log("assign blocked", error.message);
    }

    try {
      Object.defineProperty(globalThis, "WebSocket", { value: function nope() {} });
      console.log("define unexpected");
      process.exitCode = 1;
    } catch (error) {
      console.log("define blocked", error.message);
    }

    console.log("websocket", typeof globalThis.WebSocket);
    console.log("sab", typeof globalThis.SharedArrayBuffer);
    console.log("atomics", typeof globalThis.Atomics);
  `);

  assert.equal(result.code, 0, result.stderr || result.stdout);
  assert.match(result.stdout, /assign blocked .*WebSocket/);
  assert.match(result.stdout, /define blocked Cannot redefine property: WebSocket/);
  assert.match(result.stdout, /websocket undefined/);
  assert.match(result.stdout, /sab undefined/);
  assert.match(result.stdout, /atomics undefined/);
});
