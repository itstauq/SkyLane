import { Buffer } from "node:buffer";
import { parse } from "acorn";
import fs from "node:fs";
import Module from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const moduleConstructor = Module.Module ?? Module;
const originalModuleCompile = moduleConstructor.prototype._compile;
const widgetLoaderFilename = fileURLToPath(import.meta.url);
const widgetLoaderDir = path.dirname(widgetLoaderFilename);

const hiddenGlobalNames = Object.freeze([
  "WebAssembly",
  "WebSocket",
  "SharedArrayBuffer",
  "Atomics",
]);
const wrapperLocalNames = Object.freeze([
  "exports",
  "require",
  "module",
  "__filename",
  "__dirname",
]);
const widgetPreludeLines = Object.freeze([
  "with ((() => {",
  "  const scope = module.__notchWidgetScope;",
  "  delete module.__notchWidgetScope;",
  "  return scope;",
  "})()) {",
  "(function(exports, require, module, __filename, __dirname) {",
  "\"use strict\";",
]);
const widgetPrelude = `${widgetPreludeLines.join("\n")}\n`;
const widgetSuffix = "\n}).call(module.exports, exports, require, module, __filename, __dirname);\n}";
const inlineSourceMapPattern = /(?:\r?\n)?(\/\/[#@]\s*sourceMappingURL=(data:application\/json[^\s]*))\s*$/i;

export const WIDGET_PRELUDE_LINE_COUNT = widgetPreludeLines.length;

function adjustInlineSourceMapComment(comment, dataUrl, lineOffset) {
  const commaIndex = dataUrl.indexOf(",");
  if (commaIndex === -1) return comment;

  const metadata = dataUrl.slice(0, commaIndex);
  const payload = dataUrl.slice(commaIndex + 1);
  const isBase64 = /;base64$/i.test(metadata);

  try {
    const sourceMapJson = isBase64
      ? Buffer.from(payload, "base64").toString("utf8")
      : decodeURIComponent(payload);
    const sourceMap = JSON.parse(sourceMapJson);
    sourceMap.mappings = `${";".repeat(lineOffset)}${sourceMap.mappings ?? ""}`;
    const encodedSourceMap = isBase64
      ? Buffer.from(JSON.stringify(sourceMap), "utf8").toString("base64")
      : encodeURIComponent(JSON.stringify(sourceMap));
    return `//# sourceMappingURL=${metadata},${encodedSourceMap}`;
  } catch {
    return comment;
  }
}

export function prepareWidgetBundleSource(bundleSource) {
  const inlineSourceMapMatch = bundleSource.match(inlineSourceMapPattern);
  let bundleBody = bundleSource;
  let trailingSourceMapComment = "";

  if (inlineSourceMapMatch) {
    bundleBody = bundleSource.slice(0, inlineSourceMapMatch.index);
    trailingSourceMapComment = `\n${adjustInlineSourceMapComment(
      inlineSourceMapMatch[1],
      inlineSourceMapMatch[2],
      WIDGET_PRELUDE_LINE_COUNT
    )}`;
  }

  return `${widgetPrelude}${bundleBody}${widgetSuffix}${trailingSourceMapComment}`;
}

function containsDynamicImport(node) {
  if (!node || typeof node !== "object") {
    return false;
  }

  if (node.type === "ImportExpression") {
    return true;
  }

  for (const value of Object.values(node)) {
    if (Array.isArray(value)) {
      for (const child of value) {
        if (containsDynamicImport(child)) {
          return true;
        }
      }
      continue;
    }

    if (containsDynamicImport(value)) {
      return true;
    }
  }

  return false;
}

function assertNoDynamicImport(bundleSource, bundlePath) {
  const sourceMapIndex = bundleSource.lastIndexOf("\n//# sourceMappingURL=");
  const executableSource = sourceMapIndex >= 0
    ? bundleSource.slice(0, sourceMapIndex)
    : bundleSource;
  const program = parse(executableSource, {
    ecmaVersion: "latest",
    sourceType: "script",
  });

  if (containsDynamicImport(program)) {
    throw new Error(
      `Dynamic import is unsupported in the widget runtime. ${bundlePath} still contains import(...).`
    );
  }
}

function sanitizeDescriptor(descriptor, receiver) {
  if (!descriptor) return descriptor;
  if (!("get" in descriptor) && !("set" in descriptor)) return descriptor;

  return {
    configurable: descriptor.configurable ?? false,
    enumerable: descriptor.enumerable ?? false,
    get: typeof descriptor.get === "function"
      ? function sanitizedGetter() {
        return Reflect.apply(descriptor.get, receiver, []);
      }
      : undefined,
    set: typeof descriptor.set === "function"
      ? function sanitizedSetter(value) {
        return Reflect.apply(descriptor.set, receiver, [value]);
      }
      : undefined,
  };
}

function createProxySafeDescriptor(descriptor) {
  if (!descriptor) {
    return descriptor;
  }

  const safeDescriptor = {
    enumerable: descriptor.enumerable ?? false,
    configurable: true,
  };

  if ("get" in descriptor || "set" in descriptor) {
    safeDescriptor.get = descriptor.get;
    safeDescriptor.set = descriptor.set;
    return safeDescriptor;
  }

  safeDescriptor.value = descriptor.value;
  safeDescriptor.writable = descriptor.writable ?? false;
  return safeDescriptor;
}

function createWidgetGlobalScope(realGlobalThis) {
  const hiddenGlobals = new Set(hiddenGlobalNames);
  const wrapperLocals = new Set(wrapperLocalNames);
  const widgetGlobalOverlay = Object.create(null);
  const deletedGlobals = new Set();
  let publicGlobalThis;
  let lookupGlobalThis;

  function hasOverlayProperty(prop) {
    return Object.prototype.hasOwnProperty.call(widgetGlobalOverlay, prop);
  }

  function getOverlayDescriptor(prop) {
    if (!hasOverlayProperty(prop)) {
      return undefined;
    }

    return sanitizeDescriptor(
      Reflect.getOwnPropertyDescriptor(widgetGlobalOverlay, prop),
      publicGlobalThis
    );
  }

  function isDeletedGlobal(prop) {
    return deletedGlobals.has(prop);
  }

  function deleteFromOverlayOrMask(target, prop) {
    if (hasOverlayProperty(prop)) {
      return Reflect.deleteProperty(widgetGlobalOverlay, prop);
    }

    const descriptor = Reflect.getOwnPropertyDescriptor(target, prop);
    if (!descriptor) {
      return true;
    }

    if (!descriptor.configurable) {
      return false;
    }

    deletedGlobals.add(prop);
    return true;
  }

  function setOverlayValue(prop, value) {
    deletedGlobals.delete(prop);

    if (hasOverlayProperty(prop)) {
      return Reflect.set(widgetGlobalOverlay, prop, value, publicGlobalThis);
    }

    return Reflect.defineProperty(widgetGlobalOverlay, prop, {
      value,
      enumerable: true,
      configurable: true,
      writable: true,
    });
  }

  function ownKeys(target) {
    const keys = new Set();
    for (const key of Reflect.ownKeys(target)) {
      if (!hiddenGlobals.has(key) && !wrapperLocals.has(key) && !isDeletedGlobal(key)) {
        keys.add(key);
      }
    }
    for (const key of Reflect.ownKeys(widgetGlobalOverlay)) {
      if (!hiddenGlobals.has(key) && !wrapperLocals.has(key)) {
        keys.add(key);
      }
    }
    return [...keys];
  }

  lookupGlobalThis = new Proxy(widgetGlobalOverlay, {
    get(_target, prop, receiver) {
      if (wrapperLocals.has(prop)) return undefined;
      if (hiddenGlobals.has(prop)) return undefined;
      if (prop === "globalThis" || prop === "global" || prop === "self") return publicGlobalThis;
      if (isDeletedGlobal(prop)) return undefined;
      if (hasOverlayProperty(prop)) {
        return Reflect.get(widgetGlobalOverlay, prop, publicGlobalThis);
      }
      return Reflect.get(realGlobalThis, prop, realGlobalThis);
    },
    has(_target, prop) {
      if (wrapperLocals.has(prop)) return false;
      if (hiddenGlobals.has(prop)) return true;
      if (prop === "globalThis" || prop === "global" || prop === "self") return true;
      if (isDeletedGlobal(prop)) return true;
      return hasOverlayProperty(prop) || Reflect.has(realGlobalThis, prop);
    },
    getOwnPropertyDescriptor(_target, prop) {
      if (wrapperLocals.has(prop)) return undefined;
      if (hiddenGlobals.has(prop)) {
        return {
          value: undefined,
          enumerable: false,
          configurable: true,
          writable: false,
        };
      }
      if (isDeletedGlobal(prop)) {
        return undefined;
      }
      const overlayDescriptor = getOverlayDescriptor(prop);
      if (overlayDescriptor) {
        return overlayDescriptor;
      }
      if (prop === "globalThis" || prop === "global" || prop === "self") {
        return {
          value: publicGlobalThis,
          enumerable: false,
          configurable: true,
          writable: false,
        };
      }
      return createProxySafeDescriptor(
        Reflect.getOwnPropertyDescriptor(realGlobalThis, prop)
      );
    },
    ownKeys() {
      return ownKeys(realGlobalThis);
    },
    set(_target, prop, value) {
      if (hiddenGlobals.has(prop)) return false;
      if (wrapperLocals.has(prop)) return false;
      return setOverlayValue(prop, value);
    },
    defineProperty(_target, prop, descriptor) {
      if (hiddenGlobals.has(prop)) return false;
      if (wrapperLocals.has(prop)) return false;
      deletedGlobals.delete(prop);
      return Reflect.defineProperty(widgetGlobalOverlay, prop, descriptor);
    },
    deleteProperty(_target, prop) {
      if (hiddenGlobals.has(prop)) return false;
      if (wrapperLocals.has(prop)) return false;
      return deleteFromOverlayOrMask(realGlobalThis, prop);
    },
  });

  publicGlobalThis = new Proxy(widgetGlobalOverlay, {
    get(_target, prop, receiver) {
      if (wrapperLocals.has(prop)) return undefined;
      if (hiddenGlobals.has(prop)) return undefined;
      if (prop === "globalThis" || prop === "global" || prop === "self") return receiver;
      if (isDeletedGlobal(prop)) return undefined;
      if (hasOverlayProperty(prop)) {
        return Reflect.get(widgetGlobalOverlay, prop, publicGlobalThis);
      }
      return Reflect.get(realGlobalThis, prop, realGlobalThis);
    },
    has(_target, prop) {
      if (wrapperLocals.has(prop)) return false;
      if (hiddenGlobals.has(prop)) return false;
      if (isDeletedGlobal(prop)) return false;
      return hasOverlayProperty(prop) || Reflect.has(realGlobalThis, prop);
    },
    getOwnPropertyDescriptor(_target, prop) {
      if (wrapperLocals.has(prop)) return undefined;
      if (hiddenGlobals.has(prop)) return undefined;
      if (isDeletedGlobal(prop)) return undefined;
      const overlayDescriptor = getOverlayDescriptor(prop);
      if (overlayDescriptor) {
        return overlayDescriptor;
      }
      if (prop === "globalThis" || prop === "global" || prop === "self") {
        return {
          value: publicGlobalThis,
          enumerable: false,
          configurable: true,
          writable: false,
        };
      }
      return createProxySafeDescriptor(
        Reflect.getOwnPropertyDescriptor(realGlobalThis, prop)
      );
    },
    ownKeys() {
      return ownKeys(realGlobalThis);
    },
    set(_target, prop, value) {
      if (wrapperLocals.has(prop)) return false;
      if (hiddenGlobals.has(prop)) return false;
      return setOverlayValue(prop, value);
    },
    defineProperty(_target, prop, descriptor) {
      if (wrapperLocals.has(prop)) return false;
      if (hiddenGlobals.has(prop)) return false;
      deletedGlobals.delete(prop);
      return Reflect.defineProperty(widgetGlobalOverlay, prop, descriptor);
    },
    deleteProperty(_target, prop) {
      if (wrapperLocals.has(prop)) return false;
      if (hiddenGlobals.has(prop)) return false;
      return deleteFromOverlayOrMask(realGlobalThis, prop);
    },
  });

  return lookupGlobalThis;
}

export function loadWidgetBundle(bundlePath) {
  const resolvedBundlePath = path.resolve(bundlePath);
  const widgetParentModule = new moduleConstructor(widgetLoaderFilename, null);
  widgetParentModule.id = widgetLoaderFilename;
  widgetParentModule.filename = widgetLoaderFilename;
  widgetParentModule.path = widgetLoaderDir;
  widgetParentModule.paths = moduleConstructor._nodeModulePaths(widgetLoaderDir);
  widgetParentModule.loaded = true;

  const widgetModule = new moduleConstructor(resolvedBundlePath, widgetParentModule);
  widgetModule.id = resolvedBundlePath;
  widgetModule.filename = resolvedBundlePath;
  widgetModule.path = path.dirname(resolvedBundlePath);
  widgetModule.paths = moduleConstructor._nodeModulePaths(widgetModule.path);
  widgetModule.__notchWidgetScope = createWidgetGlobalScope(globalThis);

  Module._cache[resolvedBundlePath] = widgetModule;

  try {
    const bundleSource = fs.readFileSync(resolvedBundlePath, "utf8");
    assertNoDynamicImport(bundleSource, resolvedBundlePath);
    originalModuleCompile.call(
      widgetModule,
      prepareWidgetBundleSource(bundleSource),
      resolvedBundlePath
    );
    widgetModule.loaded = true;
    return widgetModule.exports;
  } catch (error) {
    delete Module._cache[resolvedBundlePath];
    throw error;
  }
}
