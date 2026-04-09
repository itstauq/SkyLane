repo_root := justfile_directory()

default:
    just --list

bump-version bump_type:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    PROJECT_FILE="$REPO_ROOT/Skylane.xcodeproj/project.pbxproj"
    SETTINGS_FILE="$REPO_ROOT/Skylane/AppSettingsView.swift"
    BUMP_TYPE="{{ bump_type }}"

    case "$BUMP_TYPE" in
      major|minor|patch)
        ;;
      *)
        echo "Unknown bump type: $BUMP_TYPE" >&2
        exit 1
        ;;
    esac

    CURRENT_VERSION="$(perl -ne 'if (/MARKETING_VERSION = ([0-9]+(?:\.[0-9]+){1,2});/) { print $1; exit }' "$PROJECT_FILE")"
    CURRENT_BUILD="$(perl -ne 'if (/CURRENT_PROJECT_VERSION = ([0-9]+);/) { print $1; exit }' "$PROJECT_FILE")"

    if [ -z "$CURRENT_VERSION" ] || [ -z "$CURRENT_BUILD" ]; then
      echo "Could not read current version/build from $PROJECT_FILE" >&2
      exit 1
    fi

    IFS='.' read -r MAJOR MINOR PATCH <<< "$(printf '%s' "$CURRENT_VERSION" | awk -F. '{ if (NF == 2) { printf "%s.%s.0", $1, $2 } else { printf "%s.%s.%s", $1, $2, $3 } }')"

    case "$BUMP_TYPE" in
      major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
      minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
      patch)
        PATCH=$((PATCH + 1))
        ;;
    esac

    NEXT_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    NEXT_BUILD="$((CURRENT_BUILD + 1))"

    perl -0pi -e "s/MARKETING_VERSION = [0-9]+(?:\\.[0-9]+){1,2};/MARKETING_VERSION = ${NEXT_VERSION};/g; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PROJECT_FILE"
    COMMIT_HASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    perl -0pi -e 's/AboutInfoRow\(label: "Commit", value: "[^"]*"\)/AboutInfoRow(label: "Commit", value: "'"$COMMIT_HASH"'")/' "$SETTINGS_FILE"

    echo "version=${NEXT_VERSION}"
    echo "build=${NEXT_BUILD}"
    echo "tag=v${NEXT_VERSION}"

release-version:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    PROJECT_FILE="$REPO_ROOT/Skylane.xcodeproj/project.pbxproj"

    perl -ne 'if (/MARKETING_VERSION = ([0-9]+(?:\.[0-9]+){1,2});/) { print $1; exit }' "$PROJECT_FILE"

release-tag:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="$(just --quiet release-version)"
    echo "v${VERSION}"

release-dmg-name:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="$(just --quiet release-version)"
    echo "Skylane-v${VERSION}.dmg"

sparkle-tool tool:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    TOOL="{{ tool }}"
    BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/.build/release}"
    SOURCE_PACKAGES_DIR="$BUILD_ROOT/SourcePackages"
    SPARKLE_CHECKOUT="$SOURCE_PACKAGES_DIR/checkouts/Sparkle"
    DERIVED_DATA_PATH="$BUILD_ROOT/SparkleTools"

    if [ ! -d "$SPARKLE_CHECKOUT" ]; then
      echo "Sparkle checkout not found at $SPARKLE_CHECKOUT" >&2
      echo "Resolve package dependencies first." >&2
      exit 1
    fi

    xcodebuild \
      -project "$SPARKLE_CHECKOUT/Sparkle.xcodeproj" \
      -scheme "$TOOL" \
      -configuration Release \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      build \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO >/dev/null

    echo "$DERIVED_DATA_PATH/Build/Products/Release/$TOOL"

test:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/.build/ci}"
    DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
    SOURCE_PACKAGES_DIR="$BUILD_ROOT/SourcePackages"

    mkdir -p "$BUILD_ROOT" "$SOURCE_PACKAGES_DIR"

    echo "Bootstrapping bundled widget toolchain..."
    "$REPO_ROOT/runtime/runtime-launcher" bootstrap
    NPM_BIN="$REPO_ROOT/runtime/.build/tools/node/bin/npm"

    echo "Installing runtime dependencies..."
    "$NPM_BIN" ci --prefix "$REPO_ROOT/runtime"

    echo "Installing SDK dependencies..."
    "$NPM_BIN" ci --prefix "$REPO_ROOT/sdk"

    echo "Running runtime tests..."
    "$NPM_BIN" test --prefix "$REPO_ROOT/runtime"

    echo "Running SDK tests..."
    "$NPM_BIN" test --prefix "$REPO_ROOT/sdk"

    echo "Running macOS unit tests..."
    xcodebuild test \
      -project "$REPO_ROOT/Skylane.xcodeproj" \
      -scheme SkylaneTests \
      -configuration Debug \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO

[arg("no_build", long="no-build", value="true", help="Skip the build step and relaunch the app")]
dev no_build='false':
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    DERIVED_DATA_PATH="$REPO_ROOT/.build/DerivedData"
    APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Skylane.app"

    if [ "{{ no_build }}" != "true" ]; then
      xcodebuild \
        -project "$REPO_ROOT/Skylane.xcodeproj" \
        -scheme Skylane \
        -configuration Debug \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -10
    fi

    OLD_PIDS="$(pgrep -x Skylane 2>/dev/null || true)"
    if [ -n "$OLD_PIDS" ]; then
      pkill -x Skylane 2>/dev/null || true

      for pid in $OLD_PIDS; do
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.5
        done
      done
    fi

    open "$APP_PATH"
    echo "Running. Logs: tail -f skylane.log"

[arg("sign", long="sign", value="true", help="Sign the release archive for distribution")]
package sign='false':
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application}"

    if [ "{{ sign }}" = "true" ] && [ -z "${APPLE_TEAM_ID:-}" ]; then
      echo "APPLE_TEAM_ID is required when using --sign" >&2
      exit 1
    fi

    mkdir -p "$REPO_ROOT/.build/release/SourcePackages"
    "$REPO_ROOT/runtime/runtime-launcher" bootstrap

    if [ "{{ sign }}" = "true" ]; then
      xcodebuild archive \
        -project "$REPO_ROOT/Skylane.xcodeproj" \
        -scheme Skylane \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$REPO_ROOT/.build/release/Skylane.xcarchive" \
        -derivedDataPath "$REPO_ROOT/.build/release/DerivedData" \
        -clonedSourcePackagesDirPath "$REPO_ROOT/.build/release/SourcePackages" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        PROVISIONING_PROFILE=""
    else
      xcodebuild archive \
        -project "$REPO_ROOT/Skylane.xcodeproj" \
        -scheme Skylane \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$REPO_ROOT/.build/release/Skylane.xcarchive" \
        -derivedDataPath "$REPO_ROOT/.build/release/DerivedData" \
        -clonedSourcePackagesDirPath "$REPO_ROOT/.build/release/SourcePackages" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO
    fi

    APP_PATH="$REPO_ROOT/.build/release/Skylane.xcarchive/Products/Applications/Skylane.app"
    FRAMEWORK_PATH="$APP_PATH/Contents/Resources/WidgetRuntime/mediaremote-adapter/MediaRemoteAdapter.framework"

    if [ "{{ sign }}" != "true" ]; then
      exit 0
    fi

    if [ ! -d "$APP_PATH" ]; then
      echo "Archived app not found at $APP_PATH" >&2
      exit 1
    fi

    if [ -d "$FRAMEWORK_PATH" ]; then
      codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$FRAMEWORK_PATH"
    fi

    codesign --force \
      --sign "$SIGNING_IDENTITY" \
      --options runtime \
      --timestamp \
      --entitlements "$REPO_ROOT/Skylane/Skylane.entitlements" \
      "$APP_PATH"

    codesign --verify --deep --strict --verbose=2 "$APP_PATH"

build-dmg:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    APP_PATH="$REPO_ROOT/.build/release/Skylane.xcarchive/Products/Applications/Skylane.app"
    SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application}"
    VERSION="$(just --quiet release-version)"
    DMG_NAME="$(just --quiet release-dmg-name)"
    RAW_DMG_DIR="$REPO_ROOT/.build/release/create-dmg/$VERSION"
    ARTIFACTS_DIR="$REPO_ROOT/.build/release/artifacts"

    mkdir -p "$ARTIFACTS_DIR" "$RAW_DMG_DIR"
    "$REPO_ROOT/.build/release/node-global/node_modules/.bin/create-dmg" \
      --overwrite \
      --identity="$SIGNING_IDENTITY" \
      "$APP_PATH" \
      "$RAW_DMG_DIR"

    RAW_DMG_PATH="$(find "$RAW_DMG_DIR" -maxdepth 1 -name '*.dmg' -print -quit)"
    if [ -z "$RAW_DMG_PATH" ]; then
      echo "DMG was not created in $RAW_DMG_DIR" >&2
      exit 1
    fi

    FINAL_DMG_PATH="$ARTIFACTS_DIR/$DMG_NAME"
    mv -f "$RAW_DMG_PATH" "$FINAL_DMG_PATH"
    echo "$FINAL_DMG_PATH"

notarize-dmg:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    KEYCHAIN_PROFILE="${APPLE_KEYCHAIN_PROFILE:-}"

    if [ -z "$KEYCHAIN_PROFILE" ] && { [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; }; then
      echo "Set APPLE_KEYCHAIN_PROFILE or provide APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID" >&2
      exit 1
    fi

    DMG_PATH="$REPO_ROOT/.build/release/artifacts/$(just --quiet release-dmg-name)"
    if [ ! -f "$DMG_PATH" ]; then
      echo "DMG not found" >&2
      exit 1
    fi

    if [ -n "$KEYCHAIN_PROFILE" ]; then
      xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait
    else
      xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
    fi

    xcrun stapler staple "$DMG_PATH"
    echo "$DMG_PATH"

generate-appcast:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/.build/release}"
    ARTIFACTS_DIR="$BUILD_ROOT/artifacts"
    VERSION="$(just --quiet release-version)"
    TAG="$(just --quiet release-tag)"
    APPCAST_INPUT_DIR="$BUILD_ROOT/appcast-input/$VERSION"
    APPCAST_PATH="$BUILD_ROOT/appcast.xml"
    DMG_NAME="$(just --quiet release-dmg-name)"
    DMG_PATH="$ARTIFACTS_DIR/$DMG_NAME"
    TOOL_PATH="$(just --quiet sparkle-tool generate_appcast)"
    DOWNLOAD_URL_PREFIX="https://github.com/itstauq/Skylane/releases/download/${TAG}/"

    if [ ! -f "$DMG_PATH" ]; then
      echo "DMG not found at $DMG_PATH" >&2
      exit 1
    fi

    mkdir -p "$APPCAST_INPUT_DIR"
    cp "$DMG_PATH" "$APPCAST_INPUT_DIR/$DMG_NAME"

    if [ -n "${SPARKLE_PRIVATE_KEY_BASE64:-}" ]; then
      printf '%s\n' "$SPARKLE_PRIVATE_KEY_BASE64" | \
        "$TOOL_PATH" \
          --ed-key-file - \
          --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
          -o "$APPCAST_PATH" \
          "$APPCAST_INPUT_DIR" >/dev/null
    else
      "$TOOL_PATH" \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        -o "$APPCAST_PATH" \
        "$APPCAST_INPUT_DIR" >/dev/null
    fi

    echo "$APPCAST_PATH"

stage-appcast-pages:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_ROOT="{{ repo_root }}"
    BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/.build/release}"
    APPCAST_PATH="$BUILD_ROOT/appcast.xml"
    PAGES_DIR="$BUILD_ROOT/pages"

    if [ ! -f "$APPCAST_PATH" ]; then
      echo "Appcast not found at $APPCAST_PATH" >&2
      exit 1
    fi

    mkdir -p "$PAGES_DIR"
    cp "$APPCAST_PATH" "$PAGES_DIR/appcast.xml"
    printf '%s\n' 'updates.skylaneapp.com' > "$PAGES_DIR/CNAME"
    touch "$PAGES_DIR/.nojekyll"

    echo "$PAGES_DIR"

release-local:
    just package --sign
    just build-dmg
    # just notarize-dmg
    # just generate-appcast
    # just stage-appcast-pages
