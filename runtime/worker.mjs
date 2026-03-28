import { parentPort, workerData } from "node:worker_threads";

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

function send(method, params) {
  parentPort.postMessage({
    jsonrpc: "2.0",
    method,
    params,
  });
}

function buildStubTree() {
  const subtitle = instanceId
    ? `instance ${instanceId}`
    : bundlePath.split("/").filter(Boolean).pop() ?? "bundle ready";

  return {
    type: "Stack",
    key: null,
    props: {
      spacing: 6,
    },
    children: [
      {
        type: "Text",
        key: null,
        props: {
          text: `${widgetId} mounted`,
        },
        children: [],
      },
      {
        type: "Text",
        key: null,
        props: {
          text: subtitle,
        },
        children: [],
      },
    ],
  };
}

send("render", {
  instanceId,
  sessionId,
  kind: "full",
  renderRevision: 1,
  data: buildStubTree(),
});

parentPort.on("message", (message) => {
  if (message?.jsonrpc !== "2.0" || typeof message.method !== "string") {
    return;
  }

  if (message.method === "shutdown") {
    process.exit(0);
  }
});
