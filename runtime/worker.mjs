import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { parentPort, workerData } from "node:worker_threads";

import { clear as clearCallbacks, invoke as invokeCallback } from "./callback-registry.mjs";
import { createRenderer } from "./reconciler.mjs";

if (!parentPort) {
  throw new Error("runtime/worker.mjs must run inside a worker thread.");
}

const {
  widgetId = "unknown-widget",
  instanceId,
  bundlePath = "",
  props = {},
  sessionId,
} = workerData ?? {};

const runtimeDir = path.dirname(fileURLToPath(import.meta.url));
const bundledApiDir = path.join(runtimeDir, "api");
const devApiDir = path.resolve(runtimeDir, "..", "sdk", "packages", "api");
const apiDir = fs.existsSync(path.join(bundledApiDir, "index.js")) ? bundledApiDir : devApiDir;

const require = createRequire(import.meta.url);
const Module = require("node:module");
const originalResolveFilename = Module._resolveFilename;
const runtimeModuleMap = new Map([
  ["react-shim", path.join(runtimeDir, "react-shim.cjs")],
  ["react", path.join(runtimeDir, "react-shim.cjs")],
  ["react/jsx-runtime", path.join(runtimeDir, "node_modules", "react", "jsx-runtime.js")],
  ["@notchapp/api", path.join(apiDir, "index.js")],
  ["@notchapp/api/jsx-runtime", path.join(apiDir, "jsx-runtime.js")],
]);

Module._resolveFilename = function resolveRuntimeModule(request, parent, isMain, options) {
  if (runtimeModuleMap.has(request)) {
    return runtimeModuleMap.get(request);
  }

  return originalResolveFilename.call(this, request, parent, isMain, options);
};

const React = require("react");
const renderer = createRenderer();
let currentProps = props ?? {};

function send(method, params) {
  parentPort.postMessage({
    jsonrpc: "2.0",
    method,
    params,
  });
}

function stringifyLogPart(part) {
  if (typeof part === "string") {
    return part;
  }

  try {
    return JSON.stringify(part);
  } catch {
    return String(part);
  }
}

function createLogger() {
  const emit = (level) => (...parts) => {
    send("log", {
      level,
      message: parts.map(stringifyLogPart).join(" "),
    });
  };

  return {
    log: emit("log"),
    info: emit("info"),
    warn: emit("warn"),
    error: emit("error"),
  };
}

function buildWidgetProps(widgetModule) {
  return {
    ...currentProps,
    state: structuredClone(widgetModule.initialState ?? {}),
    logger: createLogger(),
  };
}

function reportError(error) {
  const payload = error instanceof Error
    ? { message: error.message, stack: error.stack }
    : { message: String(error) };

  send("error", {
    instanceId,
    sessionId,
    error: payload,
  });
}

process.on("uncaughtException", (error) => {
  reportError(error);
  process.exit(1);
});

process.on("unhandledRejection", (error) => {
  reportError(error instanceof Error ? error : new Error(String(error)));
  process.exit(1);
});

renderer.onCommit((payload) => {
  send("render", {
    instanceId,
    sessionId,
    ...payload,
  });
});

const widgetModule = require(bundlePath);
const WidgetComponent = typeof widgetModule?.default === "function"
  ? widgetModule.default
  : typeof widgetModule === "function"
    ? widgetModule
    : null;

if (!WidgetComponent) {
  throw new Error(`Widget bundle at ${bundlePath} must export a default component function.`);
}

renderer.render(
  React.createElement(WidgetComponent, buildWidgetProps(widgetModule))
);

parentPort.on("message", (message) => {
  if (message?.jsonrpc !== "2.0" || typeof message.method !== "string") {
    return;
  }

  if (message.method === "callback") {
    const callbackId = typeof message.params?.callbackId === "string"
      ? message.params.callbackId
      : "";
    if (!callbackId) {
      return;
    }

    const result = invokeCallback(callbackId, message.params?.payload ?? {});
    if (result && typeof result.then === "function") {
      result.catch((error) => {
        reportError(error instanceof Error ? error : new Error(String(error)));
        process.exit(1);
      });
    }
    return;
  }

  if (message.method === "requestFullTree") {
    renderer.emitFullTree();
    return;
  }

  if (message.method === "shutdown") {
    clearCallbacks();
    process.exit(0);
  }
});
