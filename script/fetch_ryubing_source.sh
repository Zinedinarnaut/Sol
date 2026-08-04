#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

echo "Sol Engine source is bundled with this repository; no engine download is required."
exec "$ROOT_DIR/script/verify_sol_engine_source.sh"
