import fs from "node:fs";
import path from "node:path";
import Module from "node:module";
import { fileURLToPath } from "node:url";
import { parentPort, workerData } from "node:worker_threads";

import { clear as clearCallbacks, invoke as invokeCallback } from "./callback-registry.mjs";
import { createRuntimeFetch } from "./fetch.mjs";
import { createRenderer } from "./reconciler.mjs";
import { installRuntimeSecurity } from "./security.mjs";
import { createStorage } from "./storage.mjs";
import { loadWidgetBundle } from "./widget-loader.mjs";

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

const realProcess = globalThis.process;
const runtimeModuleMap = new Map([
  ["react-shim", path.join(runtimeDir, "react-shim.cjs")],
  ["react", path.join(runtimeDir, "react-shim.cjs")],
  ["react/jsx-runtime", path.join(runtimeDir, "node_modules", "react", "jsx-runtime.js")],
  ["@notchapp/api", path.join(apiDir, "index.js")],
  ["@notchapp/api/jsx-runtime", path.join(apiDir, "jsx-runtime.js")],
]);

installRuntimeSecurity({
  realProcess,
  runtimeModuleMap,
  allowedPathSpecifiers: new Set([bundlePath]),
});

const require = Module.createRequire(import.meta.url);
const React = require("react");
const renderer = createRenderer();
let currentProps = props ?? {};
let nextRpcRequestId = 0;
let nextHostApiRequestId = 0;
const pendingRpcRequests = new Map();
let storage = createStorage({ callRpc: () => Promise.resolve(null) });
let widgetModule = null;
let WidgetComponent = null;

function send(method, params) {
  parentPort.postMessage({
    jsonrpc: "2.0",
    method,
    params,
  });
}

function sendRequest(method, params) {
  const requestId = String(++nextRpcRequestId);

  parentPort.postMessage({
    jsonrpc: "2.0",
    id: requestId,
    method,
    params,
  });

  return new Promise((resolve, reject) => {
    pendingRpcRequests.set(requestId, { resolve, reject });
  });
}

function createHostApiRequestId() {
  return `${sessionId}:host:${++nextHostApiRequestId}`;
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

function renderCurrentWidget() {
  if (!widgetModule || !WidgetComponent) {
    throw new Error("Widget worker received props before the bundle finished loading.");
  }

  renderer.render(
    React.createElement(WidgetComponent, buildWidgetProps(widgetModule))
  );
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

realProcess.on("uncaughtException", (error) => {
  reportError(error);
  realProcess.exit(1);
});

realProcess.on("unhandledRejection", (error) => {
  reportError(error instanceof Error ? error : new Error(String(error)));
  realProcess.exit(1);
});

function callRpc(method, params = {}) {
  return sendRequest("rpc", { method, params });
}

renderer.onCommit((payload) => {
  send("render", {
    instanceId,
    sessionId,
    ...payload,
  });
});

function handleMessage(message) {
  if (message?.jsonrpc !== "2.0") {
    return;
  }

  const responseId = typeof message.id === "string"
    ? message.id
    : typeof message.id === "number"
      ? String(message.id)
      : "";
  if (responseId && (Object.hasOwn(message, "result") || Object.hasOwn(message, "error"))) {
    const pending = pendingRpcRequests.get(responseId);
    if (!pending) {
      return;
    }

    pendingRpcRequests.delete(responseId);
    if (message.error) {
      const error = new Error(message.error.message ?? "Runtime RPC failed.");
      error.rpcCode = message.error.code;
      error.data = message.error.data;
      pending.reject(error);
      return;
    }

    pending.resolve(message.result ?? null);
    return;
  }

  if (typeof message.method !== "string") {
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
        realProcess.exit(1);
      });
    }
    return;
  }

  if (message.method === "requestFullTree") {
    renderer.emitFullTree();
    return;
  }

  if (message.method === "updateProps") {
    try {
      currentProps = message.params?.props ?? {};
      renderCurrentWidget();
    } catch (error) {
      reportError(error instanceof Error ? error : new Error(String(error)));
      realProcess.exit(1);
    }
    return;
  }

  if (message.method === "shutdown") {
    for (const pending of pendingRpcRequests.values()) {
      pending.reject(new Error("Widget worker shut down before RPC completed."));
    }
    pendingRpcRequests.clear();
    clearCallbacks();
    realProcess.exit(0);
  }
}

parentPort.on("message", handleMessage);

async function bootstrap() {
  const storageSnapshot = await callRpc("localStorage.allItems", {});
  storage = createStorage({
    initialValues: storageSnapshot,
    callRpc,
  });
  Object.defineProperty(globalThis, "fetch", {
    value: createRuntimeFetch({
      callRpc,
      createRequestId: createHostApiRequestId,
    }),
    enumerable: true,
    configurable: true,
    writable: false,
  });

  globalThis.__NOTCH_RUNTIME__ = {
    localStorage: storage,
    getCurrentProps: () => currentProps,
    callRpc,
  };

  widgetModule = loadWidgetBundle(bundlePath);
  WidgetComponent = typeof widgetModule?.default === "function"
    ? widgetModule.default
    : typeof widgetModule === "function"
      ? widgetModule
      : null;

  if (!WidgetComponent) {
    throw new Error(`Widget bundle at ${bundlePath} must export a default component function.`);
  }

  renderCurrentWidget();
}

await bootstrap();
