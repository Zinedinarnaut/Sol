#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Sol"
BUNDLE_ID="com.solemu.app"
CONFIGURATION="${SOL_BUILD_CONFIGURATION:-Debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DERIVED_DATA="/tmp/sol-derived-data"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
APP_LEGAL="$APP_BUNDLE/Contents/Resources/Legal"
APP_NATIVE_CORE="$APP_BUNDLE/Contents/Resources/SolEngine"
APP_MANAGED_CORE="$APP_BUNDLE/Contents/Resources/SolEngineManaged"
APP_DOTNET="$APP_BUNDLE/Contents/Resources/Dotnet"
DEVELOPMENT_TEAM="${SOL_DEVELOPMENT_TEAM:-}"
APPLE_SIGNING_MODE="${SOL_APPLE_SIGNING:-auto}"

if [[ -z "$DEVELOPMENT_TEAM" ]] && command -v openssl >/dev/null 2>&1; then
  DEVELOPMENT_TEAM="$(
    {
      security find-certificate -c "Apple Development" -p 2>/dev/null |
        openssl x509 -noout -subject 2>/dev/null |
        sed -nE 's#.*[/,]OU=([^/,]+).*#\1#p' |
        head -n 1
    } || true
  )"
fi

if [[ "$MODE" != "build" && "$MODE" != "--build" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

case "$APPLE_SIGNING_MODE" in
  auto|required|off)
    ;;
  *)
    echo "SOL_APPLE_SIGNING must be auto, required, or off." >&2
    exit 2
    ;;
esac

SIGNED_BUILD=0
XCODE_LOG="$(mktemp -t sol-xcodebuild.XXXXXX)"
trap 'rm -f "$XCODE_LOG"' EXIT

if [[ "$APPLE_SIGNING_MODE" == "required" && -z "$DEVELOPMENT_TEAM" ]]; then
  echo "SOL_APPLE_SIGNING=required needs SOL_DEVELOPMENT_TEAM or a local Apple Development certificate." >&2
  exit 2
fi

if [[ "$APPLE_SIGNING_MODE" != "off" && -n "$DEVELOPMENT_TEAM" ]]; then
  set +e
  xcodebuild \
    -allowProvisioningUpdates \
    -project "$ROOT_DIR/Sol.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    build 2>&1 | tee "$XCODE_LOG"
  XCODE_STATUS="${PIPESTATUS[0]}"
  set -e

  if [[ "$XCODE_STATUS" -eq 0 ]]; then
    SIGNED_BUILD=1
  elif [[ "$APPLE_SIGNING_MODE" == "required" ]]; then
    echo "A provisioned Apple build was required but Xcode signing failed." >&2
    exit "$XCODE_STATUS"
  elif ! grep -Eq \
    'No Account for Team|No profiles for|requires a provisioning profile' \
    "$XCODE_LOG"; then
    exit "$XCODE_STATUS"
  else
    echo "Apple capabilities are not provisioned in Xcode; building the local fallback." >&2
  fi
fi

if [[ "$SIGNED_BUILD" -eq 0 ]]; then
  xcodebuild \
    -project "$ROOT_DIR/Sol.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

if [[ "$SIGNED_BUILD" -eq 1 ]]; then
  SIGNING_IDENTITY="$(
    /usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1 |
      sed -nE 's/^Authority=(Apple Development: .*)$/\1/p' |
      head -n 1
  )"
  SIGNED_TEAM="$(
    /usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1 |
      sed -nE 's/^TeamIdentifier=(.*)$/\1/p' |
      head -n 1
  )"
  if [[ -z "$SIGNING_IDENTITY" || "$SIGNED_TEAM" != "$DEVELOPMENT_TEAM" ]]; then
    echo "The provisioned app was built without the expected Sol development identity." >&2
    exit 1
  fi

  while IFS= read -r candidate; do
    if /usr/bin/file -b "$candidate" | grep -q 'Mach-O'; then
      /usr/bin/codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        --timestamp=none \
        "$candidate"
    fi
  done < <(
    find \
      "$APP_FRAMEWORKS" \
      "$APP_NATIVE_CORE" \
      "$APP_MANAGED_CORE" \
      "$APP_DOTNET" \
      -type f -print
  )

  /usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp=none \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
    "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

open_model_capture_app() {
  local capture_directory="${SOL_DLSM_CAPTURE_DIR:-${TMPDIR:-/tmp}/sol-dlsm-captures}"
  local capture_interval="${SOL_DLSM_CAPTURE_INTERVAL:-1}"
  local capture_max_frames="${SOL_DLSM_CAPTURE_MAX_FRAMES:-360}"
  mkdir -p "$capture_directory"
  /usr/bin/open \
    -n \
    "$APP_BUNDLE" \
    --env "SOL_DLSM_CAPTURE_DIR=$capture_directory" \
    --env "SOL_DLSM_CAPTURE_INTERVAL=$capture_interval" \
    --env "SOL_DLSM_CAPTURE_MAX_FRAMES=$capture_max_frames"
  echo "Sol-model captures: $capture_directory"
}

open_sol_model_app() {
  local model_path="${2:-${SOL_DLSM_MODEL_PATH:-}}"
  if [[ -z "$model_path" || ! -f "$model_path" ]]; then
    echo "Pass a valid Sol Temporal model path after --model." >&2
    exit 2
  fi
  model_path="$(cd "$(dirname "$model_path")" && pwd)/$(basename "$model_path")"
  if [[ "${SOL_DLSM_PROFILE_MODEL:-0}" == "1" ]]; then
    /usr/bin/open \
      -n \
      "$APP_BUNDLE" \
      --env "SOL_DLSM_MODEL_PATH=$model_path" \
      --env "SOL_DLSM_PROFILE_MODEL=1"
  else
    /usr/bin/open \
      -n \
      "$APP_BUNDLE" \
      --env "SOL_DLSM_MODEL_PATH=$model_path"
  fi
  echo "Sol Temporal candidate: $model_path"
}

case "$MODE" in
  --build|build)
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --capture-model|capture-model)
    open_model_capture_app
    ;;
  --model|model)
    open_sol_model_app "$@"
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--capture-model|--model <path>|--verify]" >&2
    exit 2
    ;;
esac
