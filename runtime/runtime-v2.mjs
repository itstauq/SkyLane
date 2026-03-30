import readline from "node:readline";
import { createRequire } from "node:module";
import { Worker } from "node:worker_threads";

const require = createRequire(import.meta.url);
const widgets = new Map();
const widgetStates = new Map();
const workers = new Map();
const pendingWorkerRpcRequests = new Map();
let sessionCounter = 0;
let isShuttingDown = false;
let shutdownExitCode = 0;

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function respond(id, result = null) {
  send({ jsonrpc: "2.0", id, result });
}

function respondError(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) {
    error.data = data;
  }
  send({ jsonrpc: "2.0", id, error });
}

function notify(method, params) {
  send({ jsonrpc: "2.0", method, params });
}

function rpcError(code, message) {
  const error = new Error(message);
  error.rpcCode = code;
  return error;
}

function requireString(value, fieldName) {
  if (typeof value !== "string" || value.trim() === "") {
    throw rpcError(-32602, `Missing or invalid '${fieldName}'.`);
  }
  return value;
}

function sessionIdFor(instanceId) {
  return `${instanceId}:${++sessionCounter}`;
}

function widgetLogger(widgetID) {
  const emit = (level) => (...parts) => {
    notify("log", {
      widgetID,
      level,
      message: parts.map((part) => typeof part === "string" ? part : JSON.stringify(part)).join(" "),
    });
  };

  return {
    log: emit("log"),
    info: emit("info"),
    warn: emit("warn"),
    error: emit("error"),
  };
}

function clearWidget(widgetID, bundlePaths = [], { resetState = true } = {}) {
  if (resetState) {
    widgetStates.delete(widgetID);
  }

  for (const bundlePath of bundlePaths) {
    if (!bundlePath) {
      continue;
    }

    try {
      delete require.cache[require.resolve(bundlePath)];
    } catch {
      // ignore
    }
  }

  widgets.delete(widgetID);
}

function loadWidget(widgetID, bundlePath, { forceReload = false } = {}) {
  const existing = widgets.get(widgetID);
  if (!forceReload && existing?.bundlePath === bundlePath) {
    return existing;
  }

  clearWidget(
    widgetID,
    [existing?.bundlePath, bundlePath],
    { resetState: forceReload || existing?.bundlePath !== undefined }
  );

  const mod = require(bundlePath);
  const widget = { bundlePath, mod };
  widgets.set(widgetID, widget);
  return widget;
}

function ensureWidget(widgetID) {
  const widget = widgets.get(widgetID);
  if (!widget) {
    throw rpcError(-32001, `Widget ${widgetID} is not loaded.`);
  }
  return widget;
}

function stateFor(widgetID, instanceID, mod) {
  let instances = widgetStates.get(widgetID);
  if (!instances) {
    instances = new Map();
    widgetStates.set(widgetID, instances);
  }

  if (!instances.has(instanceID)) {
    instances.set(instanceID, structuredClone(mod.initialState ?? {}));
  }

  return instances.get(instanceID);
}

function render(widgetID, instanceID, environment) {
  const { mod } = ensureWidget(widgetID);
  const state = stateFor(widgetID, instanceID, mod);
  const logger = widgetLogger(widgetID);
  return mod.default({
    environment,
    state,
    logger,
  });
}

function invokeAction(widgetID, instanceID, actionID, environment, payload) {
  const { mod } = ensureWidget(widgetID);
  const logger = widgetLogger(widgetID);
  const state = stateFor(widgetID, instanceID, mod);
  const action = mod.actions?.[actionID];

  if (!action) {
    throw rpcError(-32002, `Unknown action '${actionID}' for widget ${widgetID}.`);
  }

  const nextState = action(state, { environment, logger, payload });
  if (nextState !== undefined) {
    widgetStates.get(widgetID).set(instanceID, nextState);
  }
}

function removeInstanceState(widgetID, instanceID) {
  const instances = widgetStates.get(widgetID);
  if (!instances) {
    return;
  }

  instances.delete(instanceID);
  if (instances.size === 0) {
    widgetStates.delete(widgetID);
  }
}

function errorPayload(error) {
  if (error instanceof Error) {
    return {
      message: error.message,
      stack: error.stack,
    };
  }

  return {
    message: String(error),
  };
}

function reportWorkerError(entry, payload) {
  if (entry.didReportError) {
    return;
  }

  entry.didReportError = true;
  notify("error", {
    instanceId: entry.instanceId,
    sessionId: entry.sessionId,
    error: payload,
  });
}

function maybeFinishShutdown() {
  if (isShuttingDown && workers.size === 0) {
    process.exit(shutdownExitCode);
  }
}

function finalizeWorker(instanceId) {
  const entry = workers.get(instanceId);
  if (!entry) {
    return null;
  }

  workers.delete(instanceId);
  if (entry.shutdownTimer) {
    clearTimeout(entry.shutdownTimer);
  }
  for (const requestId of entry.pendingWorkerRpcRequestIds) {
    pendingWorkerRpcRequests.delete(requestId);
  }
  maybeFinishShutdown();
  return entry;
}

function beginWorkerShutdown(entry) {
  if (entry.isTerminating) {
    return;
  }

  entry.isTerminating = true;

  try {
    entry.worker.postMessage({
      jsonrpc: "2.0",
      method: "shutdown",
      params: {},
    });
  } catch {
    // The worker may already be gone.
  }

  entry.shutdownTimer = setTimeout(() => {
    entry.worker.terminate().catch(() => {});
  }, 500);
  entry.shutdownTimer.unref?.();
}

function failPendingMount(entry, error) {
  const payload = errorPayload(error);
  reportWorkerError(entry, payload);

  if (entry.mountRequestId !== undefined) {
    const requestId = entry.mountRequestId;
    entry.mountRequestId = undefined;
    respondError(requestId, -32010, payload.message);
  }

  beginWorkerShutdown(entry);
}

function handleWorkerMessage(instanceId, message) {
  const entry = workers.get(instanceId);
  if (!entry || message?.jsonrpc !== "2.0" || typeof message.method !== "string") {
    return;
  }

  switch (message.method) {
    case "render": {
      entry.didInitialRender = true;
      notify("render", {
        instanceId: entry.instanceId,
        sessionId: entry.sessionId,
        kind: message.params?.kind ?? "full",
        renderRevision: message.params?.renderRevision ?? 1,
        data: message.params?.data ?? null,
      });

      if (entry.mountRequestId !== undefined) {
        const requestId = entry.mountRequestId;
        entry.mountRequestId = undefined;
        respond(requestId, { sessionId: entry.sessionId });
      }
      break;
    }

    case "log":
      notify("log", {
        instanceId: entry.instanceId,
        sessionId: entry.sessionId,
        level: message.params?.level ?? "info",
        message: message.params?.message ?? "",
      });
      break;

    case "error": {
      const payload = {
        message: message.params?.error?.message ?? "Worker error",
        stack: message.params?.error?.stack,
      };
      reportWorkerError(entry, payload);

      if (!entry.didInitialRender && entry.mountRequestId !== undefined) {
        const requestId = entry.mountRequestId;
        entry.mountRequestId = undefined;
        respondError(requestId, -32010, payload.message);
      }

      beginWorkerShutdown(entry);
      break;
    }

    case "rpc": {
      const workerRequestId = typeof message.id === "string"
        ? message.id
        : typeof message.id === "number"
          ? String(message.id)
          : "";
      const method = typeof message.params?.method === "string" ? message.params.method : "";
      if (!workerRequestId || !method) {
        break;
      }

      const requestId = `${entry.sessionId}:${workerRequestId}`;
      entry.pendingWorkerRpcRequestIds.add(requestId);
      pendingWorkerRpcRequests.set(requestId, {
        instanceId: entry.instanceId,
        sessionId: entry.sessionId,
        workerRequestId,
      });

      send({
        jsonrpc: "2.0",
        id: requestId,
        method: "rpc",
        params: {
          instanceId: entry.instanceId,
          sessionId: entry.sessionId,
          method,
          params: message.params?.params ?? null,
        },
      });
      break;
    }

    default:
      notify("log", {
        instanceId: entry.instanceId,
        sessionId: entry.sessionId,
        level: "warn",
        message: `Unsupported worker message '${message.method}'.`,
      });
      break;
  }
}

function forwardRpcResponse(message) {
  const requestId = typeof message.id === "string"
    ? message.id
    : typeof message.id === "number"
      ? String(message.id)
      : "";
  if (!requestId) {
    return false;
  }

  const pending = pendingWorkerRpcRequests.get(requestId);
  if (!pending) {
    return false;
  }

  pendingWorkerRpcRequests.delete(requestId);
  const entry = workers.get(pending.instanceId);
  if (entry) {
    entry.pendingWorkerRpcRequestIds.delete(requestId);
  }

  if (!entry || entry.sessionId !== pending.sessionId || entry.isTerminating) {
    return true;
  }

  if (message.error) {
    try {
      entry.worker.postMessage({
        jsonrpc: "2.0",
        id: pending.workerRequestId,
        error: message.error,
      });
    } catch {
      // The worker may already be gone.
    }
    return true;
  }

  const result = message.result;
  const resultSessionId = typeof result?.sessionId === "string" ? result.sessionId : pending.sessionId;
  if (resultSessionId !== pending.sessionId) {
    return true;
  }

  try {
    entry.worker.postMessage({
      jsonrpc: "2.0",
      id: pending.workerRequestId,
      result: Object.hasOwn(result ?? {}, "value") ? result.value : null,
    });
  } catch {
    // The worker may already be gone.
  }

  return true;
}

function handleWorkerError(instanceId, error) {
  const entry = workers.get(instanceId);
  if (!entry) {
    return;
  }

  if (!entry.didInitialRender) {
    failPendingMount(entry, error);
    return;
  }

  reportWorkerError(entry, errorPayload(error));
  beginWorkerShutdown(entry);
}

function handleWorkerExit(instanceId, code) {
  const entry = finalizeWorker(instanceId);
  if (!entry) {
    return;
  }

  if (entry.terminateRequestId !== undefined) {
    respond(entry.terminateRequestId, null);
    entry.terminateRequestId = undefined;
  }

  if (!entry.didInitialRender && entry.mountRequestId !== undefined) {
    const payload = {
      message: `Worker exited before the first render (code ${code}).`,
    };
    reportWorkerError(entry, payload);
    respondError(entry.mountRequestId, -32011, payload.message);
    return;
  }

  if (!entry.isTerminating && code !== 0) {
    reportWorkerError(entry, {
      message: `Worker exited unexpectedly (code ${code}).`,
    });
  }
}

function beginShutdown(exitCode = 0) {
  if (isShuttingDown) {
    return;
  }

  isShuttingDown = true;
  shutdownExitCode = exitCode;

  if (workers.size === 0) {
    process.exit(exitCode);
    return;
  }

  for (const entry of workers.values()) {
    beginWorkerShutdown(entry);
  }

  const hardStopTimer = setTimeout(() => {
    for (const entry of workers.values()) {
      entry.worker.terminate().catch(() => {});
    }
  }, 550);
  hardStopTimer.unref?.();
}

function mountWidget(params = {}, requestId) {
  const widgetID = requireString(params.widgetId, "widgetId");
  const instanceID = requireString(params.instanceId, "instanceId");
  const bundlePath = requireString(params.bundlePath, "bundlePath");
  if (workers.has(instanceID)) {
    throw rpcError(-32005, `Instance ${instanceID} is already mounted.`);
  }

  const sessionId = sessionIdFor(instanceID);
  const entry = {
    worker: new Worker(new URL("./worker.mjs", import.meta.url), {
      workerData: {
        widgetId: widgetID,
        instanceId: instanceID,
        bundlePath,
        props: params.props ?? {},
        sessionId,
      },
      resourceLimits: {
        maxOldGenerationSizeMb: 64,
      },
    }),
    widgetId: widgetID,
    instanceId: instanceID,
    sessionId,
    mountRequestId: requestId,
    didInitialRender: false,
    didReportError: false,
    isTerminating: false,
    pendingWorkerRpcRequestIds: new Set(),
    terminateRequestId: undefined,
    shutdownTimer: null,
  };

  workers.set(instanceID, entry);

  entry.worker.on("message", (message) => {
    handleWorkerMessage(instanceID, message);
  });
  entry.worker.on("error", (error) => {
    handleWorkerError(instanceID, error);
  });
  entry.worker.on("exit", (code) => {
    handleWorkerExit(instanceID, code);
  });

  return entry;
}

function terminateWidget(params = {}, requestId) {
  const instanceID = requireString(params.instanceId, "instanceId");
  const sessionID = requireString(params.sessionId, "sessionId");
  const entry = workers.get(instanceID);
  if (!entry) {
    return true;
  }

  if (entry.sessionId !== sessionID) {
    throw rpcError(-32004, `Session mismatch for instance ${instanceID}.`);
  }

  entry.terminateRequestId = requestId;
  beginWorkerShutdown(entry);
  return false;
}

function forwardCallback(params = {}) {
  const instanceID = typeof params.instanceId === "string" ? params.instanceId : "";
  const sessionID = typeof params.sessionId === "string" ? params.sessionId : "";
  const callbackID = typeof params.callbackId === "string" ? params.callbackId : "";
  if (!instanceID || !sessionID || !callbackID) {
    return;
  }

  const entry = workers.get(instanceID);
  if (!entry || entry.sessionId !== sessionID || entry.isTerminating) {
    return;
  }

  try {
    entry.worker.postMessage({
      jsonrpc: "2.0",
      method: "callback",
      params: {
        callbackId: callbackID,
        payload: params.payload ?? {},
      },
    });
  } catch {
    // The worker may already be gone.
  }
}

function forwardRequestFullTree(params = {}) {
  const instanceID = typeof params.instanceId === "string" ? params.instanceId : "";
  const sessionID = typeof params.sessionId === "string" ? params.sessionId : "";
  if (!instanceID || !sessionID) {
    return;
  }

  const entry = workers.get(instanceID);
  if (!entry || entry.sessionId !== sessionID || entry.isTerminating) {
    return;
  }

  try {
    entry.worker.postMessage({
      jsonrpc: "2.0",
      method: "requestFullTree",
      params: {},
    });
  } catch {
    // The worker may already be gone.
  }
}

function forwardUpdateProps(params = {}) {
  const instanceID = typeof params.instanceId === "string" ? params.instanceId : "";
  const sessionID = typeof params.sessionId === "string" ? params.sessionId : "";
  if (!instanceID || !sessionID) {
    return;
  }

  const entry = workers.get(instanceID);
  if (!entry || entry.sessionId !== sessionID || entry.isTerminating) {
    return;
  }

  try {
    entry.worker.postMessage({
      jsonrpc: "2.0",
      method: "updateProps",
      params: {
        props: params.props ?? {},
      },
    });
  } catch {
    // The worker may already be gone.
  }
}

function shutdownRuntime() {
  beginShutdown(0);
}

function handleLegacyLoad(params = {}) {
  const widgetID = requireString(params.widgetID, "widgetID");
  const bundlePath = requireString(params.bundlePath, "bundlePath");
  loadWidget(widgetID, bundlePath, { forceReload: params.forceReload === true });
  return { widgetID };
}

function handleLegacyRender(params = {}) {
  const widgetID = requireString(params.widgetID, "widgetID");
  const instanceID = requireString(params.instanceID, "instanceID");
  return {
    tree: render(widgetID, instanceID, params.environment),
  };
}

function handleLegacyAction(params = {}) {
  const widgetID = requireString(params.widgetID, "widgetID");
  const instanceID = requireString(params.instanceID, "instanceID");
  const actionID = requireString(params.actionID, "actionID");
  invokeAction(widgetID, instanceID, actionID, params.environment, params.payload ?? null);
  return null;
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

process.stdin.on("end", () => {
  beginShutdown(0);
});

for await (const line of rl) {
  if (!line.trim()) continue;

  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    respondError(null, -32700, `Invalid JSON: ${error.message}`);
    continue;
  }

  if (message?.jsonrpc === "2.0"
    && message.id !== undefined
    && (Object.hasOwn(message, "result") || Object.hasOwn(message, "error"))) {
    forwardRpcResponse(message);
    continue;
  }

  if (message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    respondError(message.id ?? null, -32600, "Invalid JSON-RPC 2.0 request.");
    continue;
  }

  try {
    switch (message.method) {
      case "mount": {
        mountWidget(message.params, message.id);
        break;
      }
      case "terminate":
        if (terminateWidget(message.params, message.id)) {
          respond(message.id, null);
        }
        break;
      case "callback":
        forwardCallback(message.params);
        break;
      case "requestFullTree":
        forwardRequestFullTree(message.params);
        break;
      case "updateProps":
        forwardUpdateProps(message.params);
        break;
      case "shutdown":
        shutdownRuntime();
        break;
      case "load":
        respond(message.id, handleLegacyLoad(message.params));
        break;
      case "render":
        respond(message.id, handleLegacyRender(message.params));
        break;
      case "action":
        respond(message.id, handleLegacyAction(message.params));
        break;
      default:
        respondError(message.id ?? null, -32601, `Unsupported method '${message.method}'.`);
        break;
    }
  } catch (error) {
    const code = typeof error?.rpcCode === "number" ? error.rpcCode : -32000;
    const messageText = error instanceof Error ? error.message : String(error);
    respondError(message.id ?? null, code, messageText);
  }
}

if (!isShuttingDown) {
  beginShutdown(0);
}
