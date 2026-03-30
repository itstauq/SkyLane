import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const testDir = path.dirname(fileURLToPath(import.meta.url));
const runtimeRoot = path.resolve(testDir, "..");
const runtimeEntryPath = path.join(runtimeRoot, "runtime-v2.mjs");

function createTempDir(t, prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

function createRuntimeHarness(t) {
  const child = spawn(process.execPath, [runtimeEntryPath], {
    cwd: runtimeRoot,
    stdio: ["pipe", "pipe", "pipe"],
  });

  const messages = [];
  const waiters = [];
  let closed = false;

  const settleWaiters = (message) => {
    for (let index = waiters.length - 1; index >= 0; index -= 1) {
      const waiter = waiters[index];
      if (!waiter.predicate(message)) {
        continue;
      }

      waiters.splice(index, 1);
      clearTimeout(waiter.timeout);
      waiter.resolve(message);
    }
  };

  const failWaiters = (error) => {
    while (waiters.length > 0) {
      const waiter = waiters.pop();
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
  };

  readline.createInterface({
    input: child.stdout,
    crlfDelay: Infinity,
  }).on("line", (line) => {
    const message = JSON.parse(line);
    messages.push(message);
    if (message.method === "rpc" && message.params?.method === "localStorage.allItems") {
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        id: message.id,
        result: { value: {} },
      })}\n`);
    }
    settleWaiters(message);
  });

  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  child.on("error", (error) => {
    failWaiters(error);
  });

  child.on("close", (code, signal) => {
    closed = true;
    if (code === 0 || signal === "SIGTERM") {
      failWaiters(new Error("runtime-v2 exited before the expected message arrived."));
      return;
    }

    failWaiters(new Error(stderr || `runtime-v2 exited with code ${code} and signal ${signal}.`));
  });

  t.after(async () => {
    if (closed) {
      return;
    }

    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "shutdown" })}\n`);
    child.stdin.end();
    await new Promise((resolve) => {
      child.once("close", () => resolve());
    });
  });

  return {
    send(message) {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    },
    waitFor(predicate, description, timeoutMs = 5000) {
      const existing = messages.find(predicate);
      if (existing) {
        return Promise.resolve(existing);
      }

      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const index = waiters.findIndex((waiter) => waiter.resolve === resolve);
          if (index >= 0) {
            waiters.splice(index, 1);
          }
          reject(new Error(`Timed out waiting for ${description}.`));
        }, timeoutMs);

        waiters.push({
          predicate,
          resolve,
          reject,
          timeout,
        });
      });
    },
  };
}

test("runtime-v2 forwards updateProps to mounted workers and rerenders with the new environment", async (t) => {
  const dir = createTempDir(t, "notch-runtime-v2-update-props-");
  const bundlePath = path.join(dir, "bundle.cjs");

  fs.writeFileSync(
    bundlePath,
    [
      'const React = require("react");',
      "module.exports.default = function Widget(props) {",
      '  return React.createElement("Text", null, String(props.environment.span));',
      "};",
      "",
    ].join("\n")
  );

  const runtime = createRuntimeHarness(t);
  const instanceId = "instance-1";
  const baseEnvironment = {
    widgetId: "test.widget",
    instanceId,
    viewId: "view-1",
    hostColumnCount: 4,
    isEditing: false,
    isDevelopment: false,
  };

  runtime.send({
    jsonrpc: "2.0",
    id: "mount-1",
    method: "mount",
    params: {
      widgetId: "test.widget",
      instanceId,
      bundlePath,
      props: {
        environment: {
          ...baseEnvironment,
          span: 1,
        },
      },
    },
  });

  const mountResponse = await runtime.waitFor(
    (message) => message.id === "mount-1",
    "the mount response"
  );
  const sessionId = mountResponse.result?.sessionId;
  assert.equal(typeof sessionId, "string");

  const initialRender = await runtime.waitFor(
    (message) => message.method === "render"
      && message.params?.sessionId === sessionId
      && message.params?.kind === "full",
    "the initial full render"
  );
  assert.equal(initialRender.params.data?.props?.text, "1");

  runtime.send({
    jsonrpc: "2.0",
    method: "updateProps",
    params: {
      instanceId,
      sessionId,
      props: {
        environment: {
          ...baseEnvironment,
          span: 3,
        },
      },
    },
  });

  runtime.send({
    jsonrpc: "2.0",
    method: "requestFullTree",
    params: {
      instanceId,
      sessionId,
    },
  });

  const updatedRender = await runtime.waitFor(
    (message) => message.method === "render"
      && message.params?.sessionId === sessionId
      && message.params?.kind === "full"
      && message.params?.data?.props?.text === "3",
    "the updated full render"
  );
  assert.equal(updatedRender.params.data.props.text, "3");
});
