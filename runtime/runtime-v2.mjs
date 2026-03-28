import readline from "node:readline";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const widgets = new Map();
const widgetStates = new Map();
const sessions = new Map();
let sessionCounter = 0;

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

function mountWidget(params = {}) {
  const widgetID = requireString(params.widgetId, "widgetId");
  const instanceID = requireString(params.instanceId, "instanceId");
  const bundlePath = requireString(params.bundlePath, "bundlePath");
  const forceReload = params.forceReload === true;

  loadWidget(widgetID, bundlePath, { forceReload });
  const { mod } = ensureWidget(widgetID);
  if (typeof mod.default !== "function") {
    throw rpcError(-32003, `Widget ${widgetID} must export a default function.`);
  }

  stateFor(widgetID, instanceID, mod);
  const sessionId = `${instanceID}:${++sessionCounter}`;
  sessions.set(instanceID, { widgetID, sessionId });
  return { sessionId };
}

function terminateWidget(params = {}) {
  const instanceID = requireString(params.instanceId, "instanceId");
  const sessionID = requireString(params.sessionId, "sessionId");
  const session = sessions.get(instanceID);
  if (!session) {
    return null;
  }

  if (session.sessionId !== sessionID) {
    throw rpcError(-32004, `Session mismatch for instance ${instanceID}.`);
  }

  removeInstanceState(session.widgetID, instanceID);
  sessions.delete(instanceID);
  return null;
}

function shutdownRuntime() {
  sessions.clear();
  widgetStates.clear();
  setImmediate(() => process.exit(0));
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

for await (const line of rl) {
  if (!line.trim()) continue;

  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    respondError(null, -32700, `Invalid JSON: ${error.message}`);
    continue;
  }

  if (message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    respondError(message.id ?? null, -32600, "Invalid JSON-RPC 2.0 request.");
    continue;
  }

  try {
    switch (message.method) {
      case "mount":
        respond(message.id, mountWidget(message.params));
        break;
      case "terminate":
        respond(message.id, terminateWidget(message.params));
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
