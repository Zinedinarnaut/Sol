#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Kept as a compatibility entry point for older build instructions. The Sol
# patches are committed directly into the bundled engine source.
exec "$ROOT_DIR/script/verify_sol_engine_source.sh"
