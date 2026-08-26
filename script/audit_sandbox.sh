#!/usr/bin/env bash
# Build Sol with the opt-in App Sandbox entitlement set and verify the signed
# result. The public release remains unsandboxed until engine-data migration
# and real-game testing have completed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DERIVED_DATA="${SOL_SANDBOX_DERIVED_DATA:-/tmp/sol-sandbox-audit-derived-data}"
TEAM_ID="${SOL_DEVELOPMENT_TEAM:-}"

if [[ -z "$TEAM_ID" ]] && command -v openssl >/dev/null 2>&1; then
  TEAM_ID="$(
    {
      security find-certificate -c "Apple Development" -p 2>/dev/null |
        openssl x509 -noout -subject 2>/dev/null |
        sed -nE 's#.*[/,]OU=([^/,]+).*#\1#p' |
        head -n 1
    } || true
  )"
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "A provisioned Apple Development identity is required for the sandbox audit." >&2
  exit 2
fi

"$ROOT_DIR/script/install_dotnet_sdk.sh" >/dev/null
xcodebuild \
  -allowProvisioningUpdates \
  -project "$ROOT_DIR/Sol.xcodeproj" \
  -scheme Sol \
  -configuration SandboxAudit \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  build

APP="$DERIVED_DATA/Build/Products/SandboxAudit/Sol.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/sol-sandbox-entitlements.XXXXXX")"
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT
/usr/bin/codesign -d --entitlements :- "$APP" >"$ENTITLEMENTS_FILE" 2>/dev/null

required_entitlements=(
  com.apple.security.app-sandbox
  com.apple.security.cs.allow-jit
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.disable-library-validation
  com.apple.security.files.user-selected.read-only
  com.apple.security.network.client
  com.apple.security.network.server
  com.apple.developer.usernotifications.time-sensitive
)

for entitlement in "${required_entitlements[@]}"; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "The audit app is missing required entitlement: $entitlement" >&2
    exit 1
  fi
done

apple_sign_in="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.applesignin:0' \
    "$ENTITLEMENTS_FILE" 2>/dev/null || true
)"
if [[ "$apple_sign_in" != "Default" ]]; then
  echo "The audit app is missing Sign in with Apple." >&2
  exit 1
fi

kv_store="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.ubiquity-kvstore-identifier' \
    "$ENTITLEMENTS_FILE" 2>/dev/null || true
)"
if [[ "$kv_store" != *"com.solemu.app" ]]; then
  echo "The audit app is missing Sol's iCloud key-value store." >&2
  exit 1
fi

icloud_container="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.ubiquity-container-identifiers:0' \
    "$ENTITLEMENTS_FILE" 2>/dev/null || true
)"
icloud_container="${icloud_container# }"
if [[ "$icloud_container" != "iCloud.com.solemu.app" ]]; then
  echo "The audit app is missing Sol's private iCloud Documents container." >&2
  exit 1
fi

icloud_service="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-services:0' \
    "$ENTITLEMENTS_FILE" 2>/dev/null || true
)"
icloud_service="${icloud_service# }"
if [[ "$icloud_service" != "CloudDocuments" ]]; then
  echo "The audit app is missing the iCloud Documents service." >&2
  exit 1
fi

app_group="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:0' \
    "$ENTITLEMENTS_FILE" 2>/dev/null || true
)"
if [[ "$app_group" != "group.com.solemu.app" ]]; then
  echo "The audit app is missing Sol's App Group." >&2
  exit 1
fi

echo "$APP"
