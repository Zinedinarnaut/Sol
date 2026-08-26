#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ -n "${1:-}" ]]; then
  APP_BUNDLE="$1"
else
  : "${TARGET_BUILD_DIR:?Xcode did not provide TARGET_BUILD_DIR}"
  : "${WRAPPER_NAME:?Xcode did not provide WRAPPER_NAME}"
  APP_BUNDLE="$TARGET_BUILD_DIR/$WRAPPER_NAME"
fi

case "$APP_BUNDLE" in
  *.app)
    ;;
  *)
    echo "Refusing to embed Sol Engine into a non-app path: $APP_BUNDLE" >&2
    exit 1
    ;;
esac

if [[ ! -d "$APP_BUNDLE/Contents" ]]; then
  echo "Sol app bundle has not been created at $APP_BUNDLE" >&2
  exit 1
fi

run_project_build() {
  # Xcode exports hundreds of build settings. MSBuild and a nested xcodebuild
  # can interpret those values as global settings, renaming the engine output
  # and making SDL link with the outer app target's executable settings.
  local sol_build_temp="${TMPDIR:-/tmp}"
  local -a clean_environment=(
    /usr/bin/env
    -i
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=$sol_build_temp"
  )

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    clean_environment+=("DEVELOPER_DIR=$DEVELOPER_DIR")
  fi

  "${clean_environment[@]}" "$@"
}

capture_build_path() {
  local build_script="$1"
  local build_output

  if ! build_output="$(run_project_build "$build_script" 2>&1)"; then
    echo "Sol Engine runtime build failed in $(basename "$build_script"):" >&2
    printf '%s\n' "$build_output" >&2
    return 1
  fi

  printf '%s\n' "$build_output" | tail -n 1
}

NATIVE_HOST_DYLIB="$(capture_build_path "$ROOT_DIR/script/build_sol_engine_native_host.sh")"
NATIVE_HEADLESS_DIR="$(capture_build_path "$ROOT_DIR/script/build_sol_engine.sh")"
MANAGED_CORE_DIR="$(capture_build_path "$ROOT_DIR/script/build_sol_engine_managed.sh")"
SOL_METAL_DIR="$(capture_build_path "$ROOT_DIR/script/build_sol_metal.sh")"
SOL_METAL_DYLIB="$SOL_METAL_DIR/SolMetal.dylib"

APP_FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
APP_LEGAL="$APP_BUNDLE/Contents/Resources/Legal"
APP_NATIVE_CORE="$APP_BUNDLE/Contents/Resources/SolEngine"
APP_MANAGED_CORE="$APP_BUNDLE/Contents/Resources/SolEngineManaged"
APP_DOTNET="$APP_BUNDLE/Contents/Resources/Dotnet"

replace_directory() {
  local source="$1"
  local destination="$2"

  case "$destination" in
    "$APP_BUNDLE"/Contents/*)
      ;;
    *)
      echo "Refusing to replace a path outside the Sol app bundle: $destination" >&2
      exit 1
      ;;
  esac

  /bin/rm -rf "$destination"
  /usr/bin/ditto "$source" "$destination"
}

mkdir -p "$APP_FRAMEWORKS"
/bin/rm -f \
  "$APP_FRAMEWORKS/Sol.Engine.NativeHost.dylib" \
  "$APP_FRAMEWORKS/libSol.Engine.NativeHost.dylib" \
  "$APP_FRAMEWORKS/SolMetal.dylib"
/bin/cp "$NATIVE_HOST_DYLIB" "$APP_FRAMEWORKS/Sol.Engine.NativeHost.dylib"
/bin/cp "$SOL_METAL_DYLIB" "$APP_FRAMEWORKS/SolMetal.dylib"

mkdir -p "$APP_LEGAL"
/bin/rm -f "$APP_LEGAL/Ryujinx-LICENSE.txt"
/bin/cp "$ROOT_DIR/LICENSE" "$APP_LEGAL/Sol-LICENSE.txt"
/bin/cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_LEGAL/THIRD-PARTY-NOTICES.md"
/bin/cp \
  "$ROOT_DIR/ThirdParty/Ryujinx/LICENSE.txt" \
  "$APP_LEGAL/UPSTREAM-MIT-LICENSE.txt"
/bin/cp \
  "$ROOT_DIR/Vendor/Ryubing/distribution/legal/THIRDPARTY.md" \
  "$APP_LEGAL/UPSTREAM-THIRD-PARTY-NOTICES.md"
/bin/cp \
  "$ROOT_DIR/ThirdParty/SPIRV-Cross/LICENSE" \
  "$APP_LEGAL/SPIRV-CROSS-LICENSE.txt"
/bin/cp "$ROOT_DIR/.tools/dotnet/LICENSE.txt" "$APP_LEGAL/DOTNET-LICENSE.txt"
/bin/cp \
  "$ROOT_DIR/.tools/dotnet/ThirdPartyNotices.txt" \
  "$APP_LEGAL/DOTNET-THIRD-PARTY-NOTICES.txt"

PACKAGE_CHECKOUT_ROOTS=("$ROOT_DIR/.build/checkouts")
if [[ -n "${BUILD_DIR:-}" ]]; then
  PACKAGE_CHECKOUT_ROOTS+=("$(cd "$BUILD_DIR/../.." && pwd -P)/SourcePackages/checkouts")
fi

copy_package_license() {
  local package_name="$1"
  local license_name="$2"
  local destination_name="$3"
  local checkout_root

  for checkout_root in "${PACKAGE_CHECKOUT_ROOTS[@]}"; do
    if [[ -f "$checkout_root/$package_name/$license_name" ]]; then
      # Some package repositories mark their license read-only. Remove the
      # previously embedded copy so incremental signed builds remain
      # repeatable instead of failing while trying to truncate that file.
      /bin/rm -f "$APP_LEGAL/$destination_name"
      /bin/cp \
        "$checkout_root/$package_name/$license_name" \
        "$APP_LEGAL/$destination_name"
      return 0
    fi
  done

  echo "Missing license for Swift package $package_name" >&2
  return 1
}

copy_package_license "DockProgress" "license" "DockProgress-LICENSE.txt"
copy_package_license "swift-argument-parser" "LICENSE.txt" "Swift-Argument-Parser-LICENSE.txt"
copy_package_license "SemanticVersion" "LICENSE" "SemanticVersion-LICENSE.txt"
copy_package_license "WhatsNewKit" "LICENSE" "WhatsNewKit-LICENSE.txt"
copy_package_license "SwiftUI-Shimmer" "LICENSE" "SwiftUI-Shimmer-LICENSE.txt"
copy_package_license "Glur" "LICENSE" "Glur-LICENSE.txt"
copy_package_license "ColorfulX" "LICENSE" "ColorfulX-LICENSE.txt"
copy_package_license "SpringInterpolation" "LICENSE" "SpringInterpolation-LICENSE.txt"
copy_package_license "MSDisplayLink" "LICENSE" "MSDisplayLink-LICENSE.txt"
copy_package_license "ColorVector" "LICENSE" "ColorVector-LICENSE.txt"

replace_directory "$NATIVE_HEADLESS_DIR" "$APP_NATIVE_CORE"
replace_directory "$MANAGED_CORE_DIR" "$APP_MANAGED_CORE"

/bin/rm -rf "$APP_DOTNET"
mkdir -p \
  "$APP_DOTNET/host/fxr/10.0.9" \
  "$APP_DOTNET/shared/Microsoft.NETCore.App/10.0.9"
/usr/bin/ditto \
  "$ROOT_DIR/.tools/dotnet/host/fxr/10.0.9" \
  "$APP_DOTNET/host/fxr/10.0.9"
/usr/bin/ditto \
  "$ROOT_DIR/.tools/dotnet/shared/Microsoft.NETCore.App/10.0.9" \
  "$APP_DOTNET/shared/Microsoft.NETCore.App/10.0.9"

REQUIRED_PATHS=(
  "$APP_FRAMEWORKS/Sol.Engine.NativeHost.dylib"
  "$APP_FRAMEWORKS/SolMetal.dylib"
  "$APP_NATIVE_CORE/Sol.Engine"
  "$APP_MANAGED_CORE/Sol.Engine.dll"
  "$APP_MANAGED_CORE/Sol.Engine.deps.json"
  "$APP_MANAGED_CORE/Sol.Engine.runtimeconfig.json"
  "$APP_DOTNET/host/fxr/10.0.9/libhostfxr.dylib"
  "$APP_DOTNET/shared/Microsoft.NETCore.App/10.0.9/libcoreclr.dylib"
  "$APP_LEGAL/SPIRV-CROSS-LICENSE.txt"
)

for required_path in "${REQUIRED_PATHS[@]}"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Sol Engine runtime embedding missed $required_path" >&2
    exit 1
  fi
done

SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" &&
      -n "$SIGNING_IDENTITY" &&
      "$SIGNING_IDENTITY" != "-" ]]; then
  while IFS= read -r candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q "Mach-O"; then
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
fi

echo "Embedded Sol Engine runtime into $APP_BUNDLE"
