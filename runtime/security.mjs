import fs from "node:fs";
import Module from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ALLOWED_BUILTIN_MODULES = Object.freeze([
  "buffer",
  "crypto",
  "events",
  "path",
  "querystring",
  "string_decoder",
  "url",
  "util",
]);

export const ALLOWED_BUILTIN_SPECIFIERS = Object.freeze(
  Module.builtinModules.filter((specifier) => {
    const root = normalizeBuiltinRoot(specifier);
    return root ? ALLOWED_BUILTIN_MODULES.includes(root) : false;
  })
);

const ALLOWED_BUILTIN_SET = new Set(ALLOWED_BUILTIN_SPECIFIERS);
const BUILTIN_ROOTS = new Set(
  Module.builtinModules
    .map((specifier) => normalizeBuiltinRoot(specifier))
    .filter(Boolean)
);

export const ALLOWED_BUILTIN_EXTERNALS = Object.freeze(
  ALLOWED_BUILTIN_SPECIFIERS.flatMap((specifier) => [
    specifier,
    `node:${specifier}`,
  ])
);

function normalizeBuiltinRoot(request) {
  if (typeof request !== "string" || request.length === 0) {
    return null;
  }

  const withoutPrefix = request.startsWith("node:") ? request.slice(5) : request;
  return withoutPrefix.split("/")[0] || null;
}

function normalizeBuiltinRequest(request) {
  if (typeof request !== "string" || request.length === 0) {
    return null;
  }

  const withoutPrefix = request.startsWith("node:") ? request.slice(5) : request;
  const root = normalizeBuiltinRoot(request);
  if (!root) {
    return null;
  }

  if (request.startsWith("node:") || BUILTIN_ROOTS.has(root)) {
    return {
      specifier: withoutPrefix,
      root,
    };
  }

  return null;
}

function isBareSpecifier(request) {
  return typeof request === "string"
    && request.length > 0
    && !request.startsWith(".")
    && !request.startsWith("/")
    && !request.startsWith("file:");
}

function isPathSpecifier(request) {
  return typeof request === "string"
    && request.length > 0
    && (request.startsWith(".") || request.startsWith("/") || request.startsWith("file:"));
}

function createUnavailableModuleError(request) {
  return new Error(`Module "${request}" is not available in the widget runtime.`);
}

function createInvalidPackageSpecifierError(request) {
  return new Error(
    `Package specifier "${request}" is not available in the widget runtime.`
  );
}

function createInvalidPathSpecifierError(request) {
  return new Error(
    `Path specifier "${request}" is not available in the widget runtime.`
  );
}

function createInvalidCompileError() {
  return new Error("module._compile is not available in the widget runtime.");
}

function defineLockedGlobal(name, value) {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);

  if (descriptor?.configurable) {
    Reflect.deleteProperty(globalThis, name);
  }

  Object.defineProperty(globalThis, name, {
    value,
    enumerable: descriptor?.enumerable ?? false,
    configurable: false,
    writable: false,
  });
}

function createBlockedCallable(name) {
  return function blockedWidgetRuntimeCallable() {
    throw new TypeError(`${name} is not available in the widget runtime.`);
  };
}

function createBlockedConstructor(target, name) {
  return new Proxy(target, {
    apply() {
      throw new TypeError(`${name} is not available in the widget runtime.`);
    },
    construct() {
      throw new TypeError(`${name} is not available in the widget runtime.`);
    },
  });
}

function definePrototypeConstructor(prototype, value) {
  if (!prototype) {
    return;
  }

  Object.defineProperty(prototype, "constructor", {
    value,
    enumerable: false,
    configurable: false,
    writable: false,
  });
}

function createStringTimerGuard(originalTimer, name) {
  return function guardedTimer(handler, ...args) {
    if (typeof handler === "string") {
      throw new TypeError(`${name} does not allow string callbacks in the widget runtime.`);
    }

    return originalTimer(handler, ...args);
  };
}

export function installRuntimeSecurity({
  realProcess,
  runtimeModuleMap,
  allowedPathSpecifiers = new Set(),
}) {
  const moduleConstructor = Module.Module ?? Module;
  const normalizedAllowedPathSpecifiers = new Set(
    [...allowedPathSpecifiers]
      .map((specifier) => normalizeResolvedPath(specifier))
      .filter(Boolean)
  );
  const activeTrustedLoadCounts = new Map();
  const originalResolveFilename = Module._resolveFilename;
  const originalLoad = Module._load;
  const originalCreateRequire = Module.createRequire.bind(Module);
  const originalModuleInstanceLoad = moduleConstructor.prototype.load;
  const originalModuleCompile = moduleConstructor.prototype._compile;
  const originalExtensions = new Map(Object.entries(moduleConstructor._extensions ?? {}));
  const originalSetTimeout = globalThis.setTimeout;
  const originalSetInterval = globalThis.setInterval;
  const originalFunction = globalThis.Function;
  const asyncFunction = async function runtimeAsyncFunctionMarker() {};
  const generatorFunction = function* runtimeGeneratorFunctionMarker() {};
  const asyncGeneratorFunction = async function* runtimeAsyncGeneratorFunctionMarker() {};

  const blockedEval = createBlockedCallable("eval");
  const blockedFunction = createBlockedConstructor(originalFunction, "Function");
  const blockedAsyncFunction = createBlockedConstructor(
    asyncFunction.constructor,
    "Function"
  );
  const blockedGeneratorFunction = createBlockedConstructor(
    generatorFunction.constructor,
    "Function"
  );
  const blockedAsyncGeneratorFunction = createBlockedConstructor(
    asyncGeneratorFunction.constructor,
    "Function"
  );

  function normalizeFilename(value) {
    if (typeof value !== "string" || value.length === 0) {
      return null;
    }

    try {
      return value.startsWith("file:") ? fileURLToPath(value) : value;
    } catch {
      return value;
    }
  }

  function normalizeResolvedPath(value) {
    const normalized = normalizeFilename(value);
    if (!normalized) {
      return null;
    }

    const resolved = path.resolve(normalized);
    try {
      return fs.realpathSync.native?.(resolved) ?? fs.realpathSync(resolved);
    } catch {
      return resolved;
    }
  }

  function hasCachedModule(filename) {
    const resolved = normalizeResolvedPath(filename);
    return !!resolved && Object.hasOwn(Module._cache, resolved);
  }

  function beginTrustedRuntimeLoad(filename) {
    const resolved = normalizeResolvedPath(filename);
    if (!resolved) {
      return null;
    }

    activeTrustedLoadCounts.set(resolved, (activeTrustedLoadCounts.get(resolved) ?? 0) + 1);
    return resolved;
  }

  function endTrustedRuntimeLoad(filename) {
    if (!filename) {
      return;
    }

    const count = activeTrustedLoadCounts.get(filename);
    if (!count || count <= 1) {
      activeTrustedLoadCounts.delete(filename);
      return;
    }

    activeTrustedLoadCounts.set(filename, count - 1);
  }

  function withTrustedRuntimeLoad(filename, loader) {
    const resolved = beginTrustedRuntimeLoad(filename);
    try {
      return loader();
    } finally {
      endTrustedRuntimeLoad(resolved);
    }
  }

  function isActiveTrustedRuntimeParent(parentOrFilename) {
    if (!parentOrFilename || typeof parentOrFilename !== "object") {
      return false;
    }

    const resolved = normalizeResolvedPath(parentOrFilename.filename);
    return !!resolved && activeTrustedLoadCounts.has(resolved);
  }

  function resolveTrustedModulePath(request, parent, isMain) {
    if (runtimeModuleMap.has(request)) {
      return runtimeModuleMap.get(request);
    }

    if (isPathSpecifier(request) && isActiveTrustedRuntimeParent(parent)) {
      return originalResolveFilename.call(Module, request, parent, isMain);
    }

    return null;
  }

  function isExplicitlyAllowedPath(request) {
    if (allowedPathSpecifiers.has(request)) {
      return true;
    }

    const normalized = normalizeResolvedPath(request);
    return !!normalized && normalizedAllowedPathSpecifiers.has(normalized);
  }

  function canLoadPath(filename, moduleInstance) {
    const normalizedFilename = normalizeResolvedPath(filename);
    const isActiveTrustedPath = !!normalizedFilename && activeTrustedLoadCounts.has(normalizedFilename);
    return isExplicitlyAllowedPath(filename)
      || isActiveTrustedPath
      || isActiveTrustedRuntimeParent(moduleInstance?.parent);
  }

  function validateRequest(request, parentOrFilename = null) {
    if (runtimeModuleMap.has(request)) {
      return;
    }

    if (allowedPathSpecifiers.has(request)) {
      return;
    }

    if (isExplicitlyAllowedPath(request)) {
      return;
    }

    const builtin = normalizeBuiltinRequest(request);
    if (builtin) {
      if (!ALLOWED_BUILTIN_SET.has(builtin.specifier)) {
        throw createUnavailableModuleError(request);
      }
      return;
    }

    if (isPathSpecifier(request)) {
      if (isActiveTrustedRuntimeParent(parentOrFilename)) {
        return;
      }
      throw createInvalidPathSpecifierError(request);
    }

    if (isBareSpecifier(request)) {
      throw createInvalidPackageSpecifierError(request);
    }
  }

  Module._resolveFilename = function resolveWidgetRuntimeModule(request, parent, isMain, options) {
    if (runtimeModuleMap.has(request)) {
      return runtimeModuleMap.get(request);
    }

    validateRequest(request, parent);
    return originalResolveFilename.call(Module, request, parent, isMain, options);
  };

  Module._load = function loadWidgetRuntimeModule(request, parent, isMain) {
    validateRequest(request, parent);
    const trustedModulePath = resolveTrustedModulePath(request, parent, isMain);
    if (trustedModulePath) {
      if (hasCachedModule(trustedModulePath)) {
        return originalLoad.call(Module, request, parent, isMain);
      }

      return withTrustedRuntimeLoad(trustedModulePath, () => (
        originalLoad.call(Module, request, parent, isMain)
      ));
    }

    return originalLoad.call(Module, request, parent, isMain);
  };

  Module.createRequire = function createWidgetRuntimeRequire(filename) {
    const createdRequire = originalCreateRequire(filename);

    function wrappedRequire(request) {
      validateRequest(request);
      return createdRequire(request);
    }

    Object.defineProperty(wrappedRequire, "resolve", {
      value(request, options) {
        validateRequest(request);
        return createdRequire.resolve(request, options);
      },
      enumerable: false,
      configurable: false,
      writable: false,
    });

    if (typeof createdRequire.resolve?.paths === "function") {
      Object.defineProperty(wrappedRequire.resolve, "paths", {
        value: createdRequire.resolve.paths.bind(createdRequire.resolve),
        enumerable: false,
        configurable: false,
        writable: false,
      });
    }

    for (const propertyName of ["cache", "extensions", "main"]) {
      if (propertyName in createdRequire) {
        Object.defineProperty(wrappedRequire, propertyName, {
          value: createdRequire[propertyName],
          enumerable: false,
          configurable: false,
          writable: false,
        });
      }
    }

    return wrappedRequire;
  };

  moduleConstructor.prototype.load = function loadWidgetRuntimeModuleFile(filename) {
    if (!canLoadPath(filename, this)) {
      throw createInvalidPathSpecifierError(String(filename));
    }

    return originalModuleInstanceLoad.call(this, filename);
  };

  moduleConstructor.prototype._compile = function compileWidgetRuntimeModule(content, filename) {
    throw createInvalidCompileError();
  };

  for (const [extension, loader] of originalExtensions) {
    Object.defineProperty(moduleConstructor._extensions, extension, {
      value(moduleInstance, filename) {
        if (!canLoadPath(filename, moduleInstance)) {
          throw createInvalidPathSpecifierError(String(filename));
        }

        if (extension === ".js") {
          const blockedModuleCompile = moduleConstructor.prototype._compile;
          let compileConsumed = false;
          Object.defineProperty(moduleInstance, "_compile", {
            value(content, compileFilename) {
              if (compileConsumed) {
                throw createInvalidCompileError();
              }

              compileConsumed = true;
              Object.defineProperty(moduleInstance, "_compile", {
                value: blockedModuleCompile,
                enumerable: false,
                configurable: true,
                writable: false,
              });
              return originalModuleCompile.call(moduleInstance, content, compileFilename);
            },
            enumerable: false,
            configurable: true,
            writable: false,
          });

          try {
            return loader.call(this, moduleInstance, filename);
          } finally {
            Reflect.deleteProperty(moduleInstance, "_compile");
          }
        }

        return loader.call(this, moduleInstance, filename);
      },
      enumerable: true,
      configurable: false,
      writable: false,
    });
  }

  const processEnv = {};
  if (typeof realProcess?.env?.NODE_ENV === "string") {
    processEnv.NODE_ENV = realProcess.env.NODE_ENV;
  }

  const processHrtime = (...args) => realProcess.hrtime(...args);
  if (typeof realProcess.hrtime?.bigint === "function") {
    Object.defineProperty(processHrtime, "bigint", {
      value: realProcess.hrtime.bigint.bind(realProcess.hrtime),
      enumerable: false,
      configurable: false,
      writable: false,
    });
  }

  const processStub = Object.freeze({
    env: Object.freeze(processEnv),
    nextTick: realProcess.nextTick.bind(realProcess),
    hrtime: processHrtime,
  });
  defineLockedGlobal("process", processStub);

  defineLockedGlobal("eval", blockedEval);
  defineLockedGlobal("Function", blockedFunction);
  defineLockedGlobal("WebSocket", undefined);
  defineLockedGlobal("setTimeout", createStringTimerGuard(originalSetTimeout, "setTimeout"));
  defineLockedGlobal("setInterval", createStringTimerGuard(originalSetInterval, "setInterval"));
  defineLockedGlobal("SharedArrayBuffer", undefined);
  defineLockedGlobal("Atomics", undefined);

  definePrototypeConstructor(originalFunction?.prototype, blockedFunction);
  definePrototypeConstructor(asyncFunction.constructor?.prototype, blockedAsyncFunction);
  definePrototypeConstructor(generatorFunction.constructor?.prototype, blockedGeneratorFunction);
  definePrototypeConstructor(
    asyncGeneratorFunction.constructor?.prototype,
    blockedAsyncGeneratorFunction
  );
}
