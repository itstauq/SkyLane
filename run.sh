#!/bin/bash
set -e
DERIVED_DATA_PATH="$PWD/.build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/NotchApp.app"

xcodebuild \
  -project NotchApp.xcodeproj \
  -scheme NotchApp \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -10

pkill -x NotchApp 2>/dev/null || true

for _ in {1..100}; do
    pgrep -x NotchApp >/dev/null || break
    sleep 0.1
done

open "$APP_PATH"
echo "Running. Logs: tail -f notchapp.log"
