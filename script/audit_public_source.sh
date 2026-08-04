#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

FAILED=0

report() {
  echo "public-source audit: $*" >&2
  FAILED=1
}

TRACKED_PATHS="$(git ls-files)"

if /usr/bin/grep -Eq '(^|/)(\.build|\.tools|NativeHost/artifacts|build-native-baseline|build-native-headless|bin|obj|xcuserdata)(/|$)' <<<"$TRACKED_PATHS"; then
  report "generated or personal build paths are tracked"
  /usr/bin/grep -E '(^|/)(\.build|\.tools|NativeHost/artifacts|build-native-baseline|build-native-headless|bin|obj|xcuserdata)(/|$)' <<<"$TRACKED_PATHS" >&2
fi

if [[ -e Vendor/Ryubing/.git ]]; then
  report "bundled Sol Engine source contains nested Git metadata"
fi

ENGINE_FILE_COUNT="$(git ls-files Vendor/Ryubing | wc -l | tr -d '[:space:]')"
if (( ENGINE_FILE_COUNT < 3500 )); then
  report "bundled Sol Engine source is unexpectedly small: $ENGINE_FILE_COUNT tracked files"
fi

if ! "$ROOT_DIR/script/verify_sol_engine_source.sh"; then
  report "bundled Sol Engine source verification failed"
fi

if /usr/bin/grep -Eiq '\.(nca|nro|nsp|nsz|tik|xci|p12|mobileprovision|provisionprofile)$|(^|/)(prod|title)\.keys$' <<<"$TRACKED_PATHS"; then
  report "protected content or signing material is tracked"
fi

while IFS= read -r tracked_file; do
  [[ -f "$tracked_file" ]] || continue
  file_size="$(stat -f '%z' "$tracked_file")"
  if (( file_size > 20 * 1024 * 1024 )); then
    report "tracked file is larger than 20 MiB: $tracked_file"
  fi
done <<<"$TRACKED_PATHS"

if git grep -n -I -E -- \
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[opsu]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}' \
  -- . ':!script/audit_public_source.sh'; then
  report "a credential-shaped value appears in tracked text"
fi

if git grep -n -I -E -- '/Users/[^/[:space:]]+/' -- . ':!script/audit_public_source.sh'; then
  report "an absolute user-home path appears in tracked text"
fi

if git grep -n -I -E -- 'DEVELOPMENT_TEAM[[:space:]]*[:=][[:space:]]*[A-Z0-9]{10}' -- .; then
  report "a personal Apple development team is hard-coded"
fi

for image_path in \
  Docs/Images/sol-library.jpg \
  Docs/Images/sol-settings.jpg \
  Docs/Images/sol-controllers.jpg; do
  if [[ ! -s "$image_path" ]]; then
    report "README image is missing: $image_path"
  fi
done

WHITESPACE_PATHS=(
  -- .
  ':(exclude)script/patches/*.patch'
  ':(exclude)Vendor/Ryubing/**'
)

# Unified diffs require a single leading context marker on otherwise blank
# context lines. Git interprets those required markers as trailing whitespace
# when a patch file itself is added. The vendored engine snapshot also
# preserves upstream formatting, so patch artifacts and that snapshot are
# exempt from Sol-owned whitespace checks.
if ! git diff --check "${WHITESPACE_PATHS[@]}"; then
  report "git diff reports whitespace errors"
fi

if ! git diff --cached --check "${WHITESPACE_PATHS[@]}"; then
  report "the staged diff reports whitespace errors"
fi

if (( FAILED != 0 )); then
  exit 1
fi

echo "public-source audit passed"
