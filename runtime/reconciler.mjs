import { createRequire } from "node:module";

import { beginEpoch, pruneStaleCallbacks, register } from "./callback-registry.mjs";

const require = createRequire(import.meta.url);
const { compare } = require("fast-json-patch");
const React = require("react");
const ReactReconciler = require("react-reconciler");
const { DefaultEventPriority } = require("react-reconciler/constants");

const OVERLAY_SLOT_TYPE = "__notch_overlay";
const LEADING_ACCESSORY_SLOT_TYPE = "__notch_leadingAccessory";
const TRAILING_ACCESSORY_SLOT_TYPE = "__notch_trailingAccessory";
let nextHostNodeId = 0;

function appendChild(parent, child) {
  removeChild(parent, child);
  parent.children.push(child);
}

function removeChild(parent, child) {
  const index = parent.children.indexOf(child);
  if (index >= 0) {
    parent.children.splice(index, 1);
  }
}

function insertChild(parent, child, beforeChild) {
  removeChild(parent, child);
  const index = parent.children.indexOf(beforeChild);
  if (index === -1) {
    parent.children.push(child);
    return;
  }

  parent.children.splice(index, 0, child);
}

function flattenText(input) {
  if (input == null || input === false) {
    return "";
  }

  if (Array.isArray(input)) {
    return input.map(flattenText).join("");
  }

  if (typeof input === "string" || typeof input === "number") {
    return String(input);
  }

  return "";
}

function isSlotType(type) {
  return (
    type === OVERLAY_SLOT_TYPE ||
    type === LEADING_ACCESSORY_SLOT_TYPE ||
    type === TRAILING_ACCESSORY_SLOT_TYPE
  );
}

function hasNestedHostChildren(children) {
  const items = React.Children.toArray(children);
  return items.some((item) => React.isValidElement(item));
}

function serializeNumber(value, parentKey) {
  if (Number.isFinite(value)) {
    return value;
  }

  if (value === Infinity && (parentKey === "maxWidth" || parentKey === "maxHeight")) {
    return "infinity";
  }

  return undefined;
}

function serializePropValue(value, parentKey = null) {
  if (value === undefined) {
    return undefined;
  }

  if (typeof value === "number") {
    return serializeNumber(value, parentKey);
  }

  if (typeof value === "function") {
    return register(value);
  }

  if (Array.isArray(value)) {
    return value
      .map((item) => serializePropValue(item, parentKey))
      .filter((item) => item !== undefined);
  }

  if (value && typeof value === "object") {
    const result = {};
    for (const [key, nestedValue] of Object.entries(value)) {
      const serializedValue = serializePropValue(nestedValue, key);
      if (serializedValue !== undefined) {
        result[key] = serializedValue;
      }
    }
    return result;
  }

  return value;
}

function sanitizeProps(type, rawProps = {}) {
  const props = {};

  for (const [key, value] of Object.entries(rawProps)) {
    if (key === "children" || value === undefined) {
      continue;
    }

    if (key === "overlay" || key === "leadingAccessory" || key === "trailingAccessory") {
      continue;
    }

    const serializedValue = key === "background" && typeof value !== "string"
      ? undefined
      : serializePropValue(value, key);

    if (serializedValue !== undefined) {
      props[key] = serializedValue;
    }
  }

  if (type === "Text" && props.text == null) {
    props.text = flattenText(rawProps.children);
  }

  if (type === "Button" && props.title == null) {
    props.title = flattenText(rawProps.children);
  }

  return props;
}

function snapshotAccessory(children) {
  const nodes = snapshotChildren(children);
  if (nodes.length === 0) {
    return undefined;
  }

  return nodes.length === 1 ? nodes[0] : snapshotRootFromNodes(nodes);
}

function snapshotRootFromNodes(nodes) {
  if (nodes.length === 0) {
    return {
      type: "Stack",
      key: null,
      props: {
        spacing: 0,
      },
      children: [],
    };
  }

  if (nodes.length === 1) {
    return nodes[0];
  }

  return {
    type: "Stack",
    key: null,
    props: {
      spacing: 0,
    },
    children: nodes,
  };
}

function snapshotChildren(children) {
  const nodes = [];

  for (const child of children) {
    const snapshot = snapshotNode(child);
    if (snapshot != null) {
      nodes.push(snapshot);
    }
  }

  return nodes;
}

function snapshotNode(node) {
  if (node == null || isSlotType(node.type)) {
    return null;
  }

  const props = structuredClone(node.props ?? {});
  const children = [];
  const overlays = [];
  let leadingAccessory;
  let trailingAccessory;

  for (const child of node.children) {
    if (child.type === OVERLAY_SLOT_TYPE) {
      const alignment = typeof child.props?.alignment === "string" ? child.props.alignment : "center";
      for (const overlayChild of snapshotChildren(child.children)) {
        overlays.push({
          alignment,
          node: overlayChild,
        });
      }
      continue;
    }

    if (child.type === LEADING_ACCESSORY_SLOT_TYPE) {
      leadingAccessory = snapshotAccessory(child.children);
      continue;
    }

    if (child.type === TRAILING_ACCESSORY_SLOT_TYPE) {
      trailingAccessory = snapshotAccessory(child.children);
      continue;
    }

    if (node.type === "Text" && child.type === "__text") {
      continue;
    }

    const snapshot = snapshotNode(child);
    if (snapshot != null) {
      children.push(snapshot);
    }
  }

  if (overlays.length > 0) {
    props.overlay = overlays;
  }

  if (leadingAccessory !== undefined) {
    props.leadingAccessory = leadingAccessory;
  }

  if (trailingAccessory !== undefined) {
    props.trailingAccessory = trailingAccessory;
  }

  return {
    id: node.id,
    type: node.type,
    key: node.key ?? null,
    props,
    children,
  };
}

function snapshotRoot(children) {
  return snapshotRootFromNodes(snapshotChildren(children));
}

function emitCurrentTree(container, kind, data) {
  container.onCommit?.({
    kind,
    renderRevision: container.renderRevision,
    data: structuredClone(data),
  });
}

const hostConfig = {
  now: Date.now,
  getRootHostContext() {
    return null;
  },
  getChildHostContext() {
    return null;
  },
  getPublicInstance(instance) {
    return instance;
  },
  prepareForCommit() {
    return null;
  },
  resetAfterCommit(container) {
    beginEpoch();
    pruneStaleCallbacks();

    const nextTree = snapshotRoot(container.children);
    container.renderRevision += 1;

    if (container.previousTree == null) {
      container.previousTree = nextTree;
      emitCurrentTree(container, "full", nextTree);
      return;
    }

    const patch = compare(container.previousTree, nextTree);
    container.previousTree = nextTree;
    emitCurrentTree(container, "patch", patch);
  },
  createInstance(type, rawProps) {
    return createHostInstance(type, rawProps);
  },
  appendInitialChild(parent, child) {
    appendChild(parent, child);
  },
  finalizeInitialChildren() {
    return false;
  },
  prepareUpdate() {
    return true;
  },
  shouldSetTextContent(type, props) {
    return type === "Text" && !hasNestedHostChildren(props?.children);
  },
  createTextInstance(text) {
    return {
      id: `node_${++nextHostNodeId}`,
      type: "__text",
      key: null,
      props: { text },
      children: [],
    };
  },
  scheduleTimeout: setTimeout,
  cancelTimeout: clearTimeout,
  noTimeout: -1,
  supportsMicrotasks: true,
  scheduleMicrotask: queueMicrotask,
  getCurrentEventPriority() {
    return DefaultEventPriority;
  },
  supportsMutation: true,
  appendChild,
  appendChildToContainer(container, child) {
    container.children.push(child);
  },
  removeChild,
  removeChildFromContainer(container, child) {
    removeChild(container, child);
  },
  insertBefore(parent, child, beforeChild) {
    insertChild(parent, child, beforeChild);
  },
  insertInContainerBefore(container, child, beforeChild) {
    insertChild(container, child, beforeChild);
  },
  commitUpdate(instance, _updatePayload, type, _oldProps, newProps) {
    instance.props = sanitizeProps(type, newProps);
  },
  commitTextUpdate(textInstance, _oldText, newText) {
    textInstance.props.text = newText;
  },
  resetTextContent(instance) {
    instance.props.text = "";
  },
  clearContainer(container) {
    container.children = [];
    return false;
  },
  detachDeletedInstance() {},
};

function createHostInstance(type, rawProps) {
  return {
    id: `node_${++nextHostNodeId}`,
    type,
    key: null,
    props: sanitizeProps(type, rawProps),
    children: [],
  };
}
const reconciler = ReactReconciler(hostConfig);

export function createRenderer() {
  const container = {
    children: [],
    previousTree: null,
    renderRevision: 0,
    onCommit: null,
  };

  const root = reconciler.createContainer(
    container,
    0,
    null,
    false,
    null,
    "",
    () => {},
    null
  );

  return {
    render(element) {
      reconciler.flushSync(() => {
        reconciler.updateContainer(element, root, null, null);
      });
    },
    unmount() {
      reconciler.flushSync(() => {
        reconciler.updateContainer(null, root, null, null);
      });
    },
    onCommit(callback) {
      container.onCommit = callback;
    },
    emitFullTree() {
      if (container.previousTree == null || container.renderRevision === 0) {
        return;
      }

      emitCurrentTree(container, "full", container.previousTree);
    },
  };
}
