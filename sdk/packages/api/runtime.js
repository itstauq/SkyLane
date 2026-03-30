function runtime() {
  if (!globalThis.__NOTCH_RUNTIME__) {
    throw new Error("@notchapp/api must run inside the Notch widget runtime");
  }

  return globalThis.__NOTCH_RUNTIME__;
}

module.exports = {
  LocalStorage: {
    getItem(key) {
      return runtime().localStorage.getItem(key);
    },
    setItem(key, value) {
      return runtime().localStorage.setItem(key, value);
    },
    removeItem(key) {
      return runtime().localStorage.removeItem(key);
    },
    allItems() {
      return runtime().localStorage.allItems();
    },
  },
  getCurrentProps: () => runtime().getCurrentProps(),
  callRpc: (method, params) => runtime().callRpc(method, params),
};
