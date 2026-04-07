#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_ROOT="$REPO_ROOT/runtime"
WIDGETS_ROOT="$REPO_ROOT/widgets"
MEDIA_ADAPTER_ROOT="$REPO_ROOT/third_party/mediaremote-adapter"
DEST_ROOT="${1:-}"
NODE_ROOT="$RUNTIME_ROOT/.build/tools/node"
NODE_BIN="$NODE_ROOT/bin/node"

if [ -z "$DEST_ROOT" ]; then
  if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    echo "Usage: prebuild.sh <destination-root>" >&2
    exit 1
  fi
  DEST_ROOT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/WidgetRuntime"
fi

"$RUNTIME_ROOT/runtime-launcher" bootstrap

rm -rf "$DEST_ROOT"
mkdir -p "$DEST_ROOT" "$DEST_ROOT/widgets"

cp "$RUNTIME_ROOT/runtime-v2.mjs" "$DEST_ROOT/runtime-v2.mjs"
cp "$RUNTIME_ROOT/reconciler.mjs" "$DEST_ROOT/reconciler.mjs"
cp "$RUNTIME_ROOT/callback-registry.mjs" "$DEST_ROOT/callback-registry.mjs"
cp "$RUNTIME_ROOT/host-events.mjs" "$DEST_ROOT/host-events.mjs"
cp "$RUNTIME_ROOT/storage.mjs" "$DEST_ROOT/storage.mjs"
cp "$RUNTIME_ROOT/fetch.mjs" "$DEST_ROOT/fetch.mjs"
cp "$RUNTIME_ROOT/security.mjs" "$DEST_ROOT/security.mjs"
cp "$RUNTIME_ROOT/widget-loader.mjs" "$DEST_ROOT/widget-loader.mjs"
cp "$RUNTIME_ROOT/worker.mjs" "$DEST_ROOT/worker.mjs"
cp "$RUNTIME_ROOT/react-shim.cjs" "$DEST_ROOT/react-shim.cjs"
cp -R "$RUNTIME_ROOT/node_modules" "$DEST_ROOT/node_modules"
cp -R "$REPO_ROOT/sdk/packages/api" "$DEST_ROOT/api"
cp -R "$NODE_ROOT" "$DEST_ROOT/node"

if [ -f "$REPO_ROOT/THIRD_PARTY_LICENSES" ]; then
  cp "$REPO_ROOT/THIRD_PARTY_LICENSES" "$DEST_ROOT/THIRD_PARTY_LICENSES"
fi

if [ -d "$MEDIA_ADAPTER_ROOT" ]; then
  MEDIA_ADAPTER_DEST_ROOT="$DEST_ROOT/mediaremote-adapter"
  mkdir -p "$MEDIA_ADAPTER_DEST_ROOT"

  cp "$MEDIA_ADAPTER_ROOT/mediaremote-adapter.pl" "$MEDIA_ADAPTER_DEST_ROOT/mediaremote-adapter.pl"
  chmod +x "$MEDIA_ADAPTER_DEST_ROOT/mediaremote-adapter.pl"
  cp -R "$MEDIA_ADAPTER_ROOT/MediaRemoteAdapter.framework" "$MEDIA_ADAPTER_DEST_ROOT/MediaRemoteAdapter.framework"
  cp "$MEDIA_ADAPTER_ROOT/LICENSE" "$MEDIA_ADAPTER_DEST_ROOT/LICENSE"
  if [ -f "$MEDIA_ADAPTER_ROOT/UPSTREAM_VERSION" ]; then
    cp "$MEDIA_ADAPTER_ROOT/UPSTREAM_VERSION" "$MEDIA_ADAPTER_DEST_ROOT/UPSTREAM_VERSION"
  fi
fi

if [ -d "$WIDGETS_ROOT" ]; then
  WIDGET_BUILD_NODE="$NODE_ROOT/bin/node"

  if [ ! -x "$WIDGET_BUILD_NODE" ]; then
    echo "Bundled widget build skipped: missing Node runtime at $WIDGET_BUILD_NODE" >&2
    exit 1
  fi

  for widget_dir in "$WIDGETS_ROOT"/*; do
    if [ ! -d "$widget_dir" ] || [ ! -f "$widget_dir/package.json" ]; then
      continue
    fi

    (
      cd "$widget_dir"
      "$WIDGET_BUILD_NODE" "$REPO_ROOT/sdk/packages/notchapp/cli.mjs" build
    )

    widget_name="$(basename "$widget_dir")"
    cp -R "$widget_dir" "$DEST_ROOT/widgets/$widget_name"
  done
fi
