import fs from "node:fs";
import Module from "node:module";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { parse } from "acorn";
import esbuild from "esbuild";
import { ALLOWED_BUILTIN_SPECIFIERS } from "./security-policy.mjs";

const command = process.argv[2];
const packageDir = process.cwd();
const canonicalWidgetsRoot = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "NotchApp",
  "Widgets",
);
const BUILTIN_ROOTS = new Set(
  Module.builtinModules
    .map((specifier) => normalizeBuiltinRoot(specifier))
    .filter(Boolean)
);
const ALLOWED_BUILTIN_SPECIFIER_SET = new Set(ALLOWED_BUILTIN_SPECIFIERS);

function packageRootFromMeta(metaURL) {
  return path.resolve(path.dirname(new URL(metaURL).pathname), "..", "..");
}

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

  if (request.startsWith("node:") || BUILTIN_ROOTS.has(withoutPrefix) || BUILTIN_ROOTS.has(root)) {
    return {
      specifier: withoutPrefix,
      root,
    };
  }

  return null;
}

function developmentWidgetsRoot() {
  const workspaceRoot = packageRootFromMeta(import.meta.url);
  return path.join(workspaceRoot, "widgets");
}

function readManifest(targetPackageDir) {
  const manifestPath = path.join(targetPackageDir, "package.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const notch = manifest.notch ?? {};

  if (!notch.id || !notch.title) {
    throw new Error(`Invalid notch manifest in ${manifestPath}: missing id/title`);
  }

  if (
    !Number.isInteger(notch.minSpan) ||
    !Number.isInteger(notch.maxSpan) ||
    notch.minSpan <= 0 ||
    notch.maxSpan < notch.minSpan
  ) {
    throw new Error(`Invalid span range in ${manifestPath}`);
  }

  const entryFile = path.join(targetPackageDir, notch.entry ?? "src/index.tsx");
  if (!fs.existsSync(entryFile)) {
    throw new Error(`Missing widget entry file at ${entryFile}`);
  }

  return { manifest, manifestPath, entryFile };
}

function ensureCanonicalSymlink(targetPackageDir, manifest) {
  fs.mkdirSync(canonicalWidgetsRoot, { recursive: true });

  const widgetID = manifest.notch.id;
  const linkPath = path.join(canonicalWidgetsRoot, widgetID);
  const sourcePath = fs.realpathSync.native(targetPackageDir);
  const linkStats = safeLstat(linkPath);

  if (linkStats) {
    if (!linkStats.isSymbolicLink()) {
      throw new Error(`Cannot replace non-symlink widget install at ${linkPath}`);
    }

    const existingTarget = safeRealpath(linkPath);
    if (existingTarget == null) {
      fs.rmSync(linkPath, { recursive: true, force: true });
      fs.symlinkSync(sourcePath, linkPath, "dir");
      return linkPath;
    }

    if (existingTarget === sourcePath) {
      return linkPath;
    }

    if (!shouldReplaceSymlink(existingTarget)) {
      throw new Error(`Refusing to replace unmanaged widget install at ${linkPath}`);
    }

    fs.rmSync(linkPath, { recursive: true, force: true });
  }

  fs.symlinkSync(sourcePath, linkPath, "dir");
  return linkPath;
}

function safeLstat(targetPath) {
  try {
    return fs.lstatSync(targetPath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

function safeRealpath(targetPath) {
  try {
    return fs.realpathSync.native(targetPath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

function shouldReplaceSymlink(targetPath) {
  return (
    targetPath.startsWith(developmentWidgetsRoot()) ||
    targetPath.includes("/Contents/Resources/WidgetRuntime/widgets/")
  );
}

function collectWatchedFiles(targetPath) {
  if (!fs.existsSync(targetPath)) {
    return [];
  }

  const stats = fs.statSync(targetPath);
  if (stats.isFile()) {
    return [targetPath];
  }

  if (!stats.isDirectory()) {
    return [];
  }

  const files = [];
  for (const entry of fs.readdirSync(targetPath, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === "node_modules" || entry.name === ".notch") {
      continue;
    }

    const entryPath = path.join(targetPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectWatchedFiles(entryPath));
    } else if (entry.isFile()) {
      files.push(entryPath);
    }
  }

  return files;
}

function snapshotWatchedFiles(watchRoots) {
  const snapshot = new Map();

  for (const watchRoot of watchRoots) {
    for (const filePath of collectWatchedFiles(watchRoot)) {
      const stats = fs.statSync(filePath);
      snapshot.set(filePath, `${stats.size}:${stats.mtimeMs}`);
    }
  }

  return snapshot;
}

function snapshotsDiffer(previousSnapshot, nextSnapshot) {
  if (previousSnapshot.size !== nextSnapshot.size) {
    return true;
  }

  for (const [filePath, signature] of nextSnapshot) {
    if (previousSnapshot.get(filePath) !== signature) {
      return true;
    }
  }

  return false;
}

function notifyApp(event, widgetID, info = "") {
  return new Promise((resolve) => {
    const query = new URLSearchParams({ cwd: process.cwd() });
    if (info) {
      query.set("info", info);
    }

    const url = `notch://cli/${encodeURIComponent(widgetID)}/${event}?${query.toString()}`;
    const child = spawn("open", [url], {
      detached: true,
      stdio: "ignore",
    });
    child.unref();
    resolve();
  });
}

function failOnDynamicImport(outfile) {
  const emitted = fs.readFileSync(outfile, "utf8");
  const sourceMapIndex = emitted.lastIndexOf("\n//# sourceMappingURL=");
  const executableSource = sourceMapIndex >= 0 ? emitted.slice(0, sourceMapIndex) : emitted;
  const program = parse(executableSource, {
    ecmaVersion: "latest",
    sourceType: "script",
  });

  if (containsDynamicImport(program)) {
    throw new Error(
      `Dynamic import is unsupported in the widget runtime. ${outfile} still contains import(...).`
    );
  }
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

function builtinModulePolicyPlugin() {
  return {
    name: "builtin-module-policy",
    setup(build) {
      build.onResolve({ filter: /.*/ }, async (args) => {
        if (args.pluginData?.skipBuiltinPolicy) {
          return null;
        }

        const builtin = normalizeBuiltinRequest(args.path);
        if (!builtin) {
          return null;
        }

        if (!args.path.startsWith("node:")) {
          const resolved = await build.resolve(args.path, {
            kind: args.kind,
            importer: args.importer,
            namespace: args.namespace,
            resolveDir: args.resolveDir,
            pluginData: { skipBuiltinPolicy: true },
          });

          if (!resolved.errors?.length && resolved.path && !resolved.external) {
            return resolved;
          }
        }

        if (!ALLOWED_BUILTIN_SPECIFIER_SET.has(builtin.specifier)) {
          return {
            errors: [
              {
                text: `Built-in module "${args.path}" is not available in the widget runtime.`,
              },
            ],
          };
        }

        return { path: args.path, external: true };
      });
    },
  };
}

function syncWidgetAssets(targetPackageDir, outputDir) {
  const sourceAssetsDir = path.join(targetPackageDir, "assets");
  const destinationAssetsDir = path.join(outputDir, "assets");

  fs.rmSync(destinationAssetsDir, { recursive: true, force: true });

  if (!fs.existsSync(sourceAssetsDir)) {
    return;
  }

  fs.cpSync(sourceAssetsDir, destinationAssetsDir, {
    recursive: true,
    dereference: true,
  });
}

function replaceBuildOutput(outputDir, stagingOutputDir, backupOutputDir) {
  fs.rmSync(backupOutputDir, { recursive: true, force: true });

  let movedExistingBuild = false;
  if (fs.existsSync(outputDir)) {
    fs.renameSync(outputDir, backupOutputDir);
    movedExistingBuild = true;
  }

  try {
    fs.renameSync(stagingOutputDir, outputDir);
    if (movedExistingBuild) {
      fs.rmSync(backupOutputDir, { recursive: true, force: true });
    }
  } catch (error) {
    if (!fs.existsSync(outputDir) && movedExistingBuild && fs.existsSync(backupOutputDir)) {
      fs.renameSync(backupOutputDir, outputDir);
    }
    throw error;
  }
}

async function buildWidget(targetPackageDir, options = {}) {
  const { manifest, entryFile } = readManifest(targetPackageDir);
  const { registerCanonicalInstall = false } = options;
  if (registerCanonicalInstall) {
    ensureCanonicalSymlink(targetPackageDir, manifest);
  }

  const notch = manifest.notch;
  const outputRoot = path.join(targetPackageDir, ".notch");
  const outputDir = path.join(outputRoot, "build");
  const outfile = path.join(outputDir, "index.cjs");
  const stagingOutputDir = path.join(outputRoot, `build.${process.pid}.staging`);
  const backupOutputDir = path.join(outputRoot, `build.${process.pid}.backup`);
  const stagingOutfile = path.join(stagingOutputDir, "index.cjs");
  fs.mkdirSync(outputRoot, { recursive: true });
  fs.rmSync(stagingOutputDir, { recursive: true, force: true });
  fs.mkdirSync(stagingOutputDir, { recursive: true });

  try {
    await esbuild.build({
      entryPoints: [entryFile],
      outfile: stagingOutfile,
      bundle: true,
      platform: "browser",
      format: "cjs",
      target: "es2022",
      jsx: "automatic",
      jsxImportSource: "@notchapp/api",
      alias: {
        react: "react-shim",
        "react/jsx-runtime": "@notchapp/api/jsx-runtime",
      },
      plugins: [builtinModulePolicyPlugin()],
      external: [
        "@notchapp/api",
        "@notchapp/api/jsx-runtime",
        "react-shim",
      ],
      sourcemap: "inline",
      logLevel: "silent",
    });

    failOnDynamicImport(stagingOutfile);
    syncWidgetAssets(targetPackageDir, stagingOutputDir);
    replaceBuildOutput(outputDir, stagingOutputDir, backupOutputDir);
  } finally {
    fs.rmSync(stagingOutputDir, { recursive: true, force: true });
    fs.rmSync(backupOutputDir, { recursive: true, force: true });
  }

  console.log(`Built ${notch.id} -> ${outfile}`);
  return manifest;
}

async function lintWidget(targetPackageDir) {
  readManifest(targetPackageDir);
  console.log(`Validated ${targetPackageDir}`);
}

async function developWidget(targetPackageDir) {
  const initial = readManifest(targetPackageDir);
  ensureCanonicalSymlink(targetPackageDir, initial.manifest);
  await notifyApp("start", initial.manifest.notch.id);
  const watchRoots = ["package.json", "src", "assets"]
    .map((relativePath) => path.join(targetPackageDir, relativePath));

  let buildInFlight = false;
  let buildQueued = false;
  let debounceTimer;
  let pollTimer;
  let lastSnapshot = snapshotWatchedFiles(watchRoots);

  const scheduleBuild = () => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      void runBuild();
    }, 150);
  };

  const runBuild = async () => {
    if (buildInFlight) {
      buildQueued = true;
      return;
    }

    buildInFlight = true;
    try {
      const manifest = await buildWidget(targetPackageDir, {
        registerCanonicalInstall: true,
      });
      await notifyApp("build-success", manifest.notch.id);
    } catch (error) {
      const manifest = safeReadManifest(targetPackageDir);
      const widgetID = manifest?.notch.id ?? path.basename(targetPackageDir);
      const message = error instanceof Error ? error.message : String(error);
      await notifyApp("build-failure", widgetID, message);
      console.error(message);
    } finally {
      buildInFlight = false;
      if (buildQueued) {
        buildQueued = false;
        scheduleBuild();
      }
    }
  };

  const stop = () => {
    void (async () => {
      clearTimeout(debounceTimer);
      if (pollTimer) {
        clearInterval(pollTimer);
      }
      await notifyApp("stop", initial.manifest.notch.id);
      process.exit(0);
    })();
  };

  for (const signal of ["SIGINT", "SIGTERM", "SIGQUIT", "SIGHUP"]) {
    process.once(signal, stop);
  }

  await runBuild();

  pollTimer = setInterval(() => {
    const nextSnapshot = snapshotWatchedFiles(watchRoots);
    if (!snapshotsDiffer(lastSnapshot, nextSnapshot)) {
      return;
    }

    lastSnapshot = nextSnapshot;
    scheduleBuild();
  }, 250);
}

function safeReadManifest(targetPackageDir) {
  try {
    return readManifest(targetPackageDir).manifest;
  } catch {
    return null;
  }
}

switch (command) {
  case "build":
    await buildWidget(packageDir);
    break;
  case "lint":
    await lintWidget(packageDir);
    break;
  case "develop":
  case "dev":
    await developWidget(packageDir);
    break;
  default:
    console.error("Usage: notch <build|develop|dev|lint>");
    process.exit(1);
}
