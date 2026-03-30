let nextCallbackId = 0;
const callbacks = new Map();

export function register(callback) {
  const callbackId = `cb_${++nextCallbackId}`;
  callbacks.set(callbackId, callback);
  return callbackId;
}

export function invoke(callbackId, payload) {
  const callback = callbacks.get(callbackId);
  if (!callback) {
    return undefined;
  }

  return callback(payload);
}

export function clear() {
  callbacks.clear();
}

export function beginEpoch() {
  // Full-tree mode does not need callback epochs yet.
}

export function pruneStaleCallbacks() {
  // Full-tree mode keeps callback IDs for the lifetime of the worker.
}
