#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$ROOT_DIR/.tools/dotnet"
SDK_VERSION="10.0.301"

if [[ -x "$INSTALL_DIR/dotnet" ]] &&
   "$INSTALL_DIR/dotnet" --list-sdks | grep -q "^$SDK_VERSION "; then
  echo "Project-local .NET SDK $SDK_VERSION is already installed."
  exit 0
fi

DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

curl --fail --silent --show-error --location \
  https://dot.net/v1/dotnet-install.sh \
  --output "$DOWNLOAD_DIR/dotnet-install.sh"

bash "$DOWNLOAD_DIR/dotnet-install.sh" \
  --version "$SDK_VERSION" \
  --install-dir "$INSTALL_DIR" \
  --no-path

"$INSTALL_DIR/dotnet" --version
