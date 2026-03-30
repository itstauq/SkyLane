function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

export function createStorage({ initialValues = {}, callRpc = () => Promise.resolve(null) } = {}) {
  const values = new Map();

  if (initialValues && typeof initialValues === "object" && !Array.isArray(initialValues)) {
    for (const [key, value] of Object.entries(initialValues)) {
      values.set(key, clone(value));
    }
  }

  function fireAndForget(method, params) {
    const pending = callRpc(method, params);
    if (pending && typeof pending.catch === "function") {
      pending.catch(() => {
        // Storage writes are intentionally best-effort from the widget's perspective.
      });
    }
  }

  return {
    getItem(key) {
      if (!values.has(key)) {
        return undefined;
      }

      return clone(values.get(key));
    },

    setItem(key, value) {
      const nextValue = clone(value);
      values.set(key, nextValue);
      fireAndForget("localStorage.setItem", {
        key,
        value: nextValue,
      });
      return clone(nextValue);
    },

    removeItem(key) {
      values.delete(key);
      fireAndForget("localStorage.removeItem", { key });
    },

    allItems() {
      return Object.fromEntries(
        Array.from(values.entries(), ([key, value]) => [key, clone(value)])
      );
    },
  };
}
