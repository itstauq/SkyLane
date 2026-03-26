import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import esbuild from "esbuild";

const command = process.argv[2];
const packageDir = process.cwd();
const canonicalWidgetsRoot = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "NotchApp",
  "Widgets",
);

function packageRootFromMeta(metaURL) {
  return path.resolve(path.dirname(new URL(metaURL).pathname), "..", "..");
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

async function buildWidget(targetPackageDir, options = {}) {
  const { manifest, entryFile } = readManifest(targetPackageDir);
  const { registerCanonicalInstall = false } = options;
  if (registerCanonicalInstall) {
    ensureCanonicalSymlink(targetPackageDir, manifest);
  }

  const notch = manifest.notch;
  const outputDir = path.join(targetPackageDir, ".notch", "build");
  const outfile = path.join(outputDir, "index.cjs");
  fs.mkdirSync(outputDir, { recursive: true });

  await esbuild.build({
    entryPoints: [entryFile],
    outfile,
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node22",
    jsx: "automatic",
    jsxImportSource: "@notchapp/api",
    sourcemap: "inline",
    logLevel: "silent",
  });

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
    .map((relativePath) => path.join(targetPackageDir, relativePath))
    .filter((targetPath) => fs.existsSync(targetPath));

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
