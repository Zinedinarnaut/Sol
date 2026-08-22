#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PRODUCT_TERMS='Nintendo|Pokémon|Pokemon|Mario|Zelda|Ryujinx|Ryubing|Amiibo'
PUBLIC_DOCS=(
  CHANGELOG.md
  Docs/Releases
  Docs/DLSM.md
  Docs/DLSM_SOL_MODEL_RESEARCH.md
)
UI_DIRS=(
  Sources/Sol/Views
  Sources/Sol/ViewModels
)
if [[ -d Sources/Sol/Onboarding ]]; then
  UI_DIRS+=(Sources/Sol/Onboarding)
fi

readme_matches="$(
  rg -n "$PRODUCT_TERMS" README.md \
    | /usr/bin/grep -Ev '^[0-9]+:(  An independent Nintendo Switch emulator for Apple Silicon Macs\.|Sol is independent and is not affiliated with or endorsed by Nintendo\.|Nintendo Switch is a trademark of Nintendo\.)$' \
    || true
)"
doc_matches="$(rg -n "$PRODUCT_TERMS" "${PUBLIC_DOCS[@]}" || true)"
ui_matches="$(rg -n '\"[^\"\n]*(Nintendo|Pokémon|Pokemon|Mario|Zelda|Ryujinx|Ryubing|Amiibo)[^\"\n]*\"' "${UI_DIRS[@]}" || true)"

if [[ -n "$readme_matches" || -n "$doc_matches" || -n "$ui_matches" ]]; then
  echo "Product-facing vendor or game branding found:" >&2
  if [[ -n "$readme_matches" ]]; then
    printf '%s\n' "$readme_matches" >&2
  fi
  if [[ -n "$doc_matches" ]]; then
    printf '%s\n' "$doc_matches" >&2
  fi
  if [[ -n "$ui_matches" ]]; then
    printf '%s\n' "$ui_matches" >&2
  fi
  echo "Keep required names in legal, provenance, and engine-internal files instead." >&2
  exit 1
fi

echo "Public branding audit passed."
