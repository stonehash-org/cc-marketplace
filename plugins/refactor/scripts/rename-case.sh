#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYMBOL=""
TARGET_CASE=""
SCOPE="project"
SEARCH_PATH="."
TARGET_FILE=""
DRY_RUN=false
FORMAT="text"

usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol NAME --to camel|snake|pascal|kebab [--scope file|project] [--path DIR] [--file FILE] [--dry-run] [--format text|json]

Naming convention converter. Detects the current case of NAME, converts it to
the target convention, then delegates to rename-symbol.sh.

Options:
  --symbol NAME   Symbol to rename (required)
  --to CASE       Target case: camel, snake, pascal, kebab (required)
  --scope SCOPE   file (single file) or project (all files) (default: project)
  --path DIR      Project root directory (default: .)
  --file FILE     Target file (required when scope=file)
  --dry-run       Show what would change without modifying files
  --format FMT    Output format: text or json (default: text)
  -h, --help      Show this help

Case detection:
  Contains '_'           -> snake_case
  Contains '-'           -> kebab-case
  First char uppercase   -> PascalCase
  Otherwise              -> camelCase

Example:
  $(basename "$0") --symbol getUserData --to snake --path ./src --dry-run
  -> calls: rename-symbol.sh --symbol getUserData --new get_user_data --path ./src --dry-run
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# split_words NAME
#
# Splits any naming convention into lowercase words, one per line.
# Uses only sed/tr/grep — works on bash 3 / macOS out of the box.
#
# Algorithm:
#   1. Replace every '_' or '-' delimiter with a space.
#   2. Insert a space before every uppercase letter (explicit A-Z list to
#      avoid locale-dependent character class expansion in bash 3).
#   3. Lowercase the entire string.
#   4. Normalise multiple spaces to newlines and drop blank lines.
# ---------------------------------------------------------------------------
split_words() {
  printf '%s' "$1" \
    | sed 's/[_-]/ /g' \
    | sed 's/\([ABCDEFGHIJKLMNOPQRSTUVWXYZ]\)/ \1/g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s ' ' '\n' \
    | grep -v '^[[:space:]]*$'
}

# ---------------------------------------------------------------------------
# Portable case helpers (bash 3 / macOS compatible)
#
# We rely on tr rather than ${var^} / ${var,} which are bash 4+ only.
# ---------------------------------------------------------------------------

# Capitalise the first letter of a word, leave the rest lowercase.
_cap() {
  local w="$1"
  [ -z "$w" ] && return
  local first rest
  first="$(printf '%s' "${w:0:1}" | tr '[:lower:]' '[:upper:]')"
  rest="$(printf '%s' "${w:1}"   | tr '[:upper:]' '[:lower:]')"
  printf '%s%s' "$first" "$rest"
}

# ---------------------------------------------------------------------------
# Case detection
# ---------------------------------------------------------------------------
detect_case() {
  local name="$1"
  case "$name" in
    *_*) echo "snake" ;;
    *-*) echo "kebab" ;;
    # Explicit uppercase first-char check (avoids locale [A-Z] issue in bash 3)
    *)
      local first_up
      first_up="$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')"
      if [ "${name:0:1}" = "$first_up" ] && printf '%s' "${name:0:1}" | grep -q '[ABCDEFGHIJKLMNOPQRSTUVWXYZ]'; then
        echo "pascal"
      else
        echo "camel"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Conversion functions
# ---------------------------------------------------------------------------
to_camel() {
  local name="$1"
  local result=""
  local i=0
  local w

  while IFS= read -r w; do
    if [ $i -eq 0 ]; then
      result="${result}$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')"
    else
      result="${result}$(_cap "$w")"
    fi
    i=$((i+1))
  done < <(split_words "$name")

  printf '%s' "$result"
}

to_pascal() {
  local name="$1"
  local result=""
  local w

  while IFS= read -r w; do
    result="${result}$(_cap "$w")"
  done < <(split_words "$name")

  printf '%s' "$result"
}

to_snake() {
  local name="$1"
  local result=""
  local first=true
  local w

  while IFS= read -r w; do
    if $first; then
      result="$w"
      first=false
    else
      result="${result}_${w}"
    fi
  done < <(split_words "$name")

  printf '%s' "$result"
}

to_kebab() {
  local name="$1"
  local result=""
  local first=true
  local w

  while IFS= read -r w; do
    if $first; then
      result="$w"
      first=false
    else
      result="${result}-${w}"
    fi
  done < <(split_words "$name")

  printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --symbol)  SYMBOL="$2";       shift 2 ;;
    --to)      TARGET_CASE="$2";  shift 2 ;;
    --scope)   SCOPE="$2";        shift 2 ;;
    --path)    SEARCH_PATH="$2";  shift 2 ;;
    --file)    TARGET_FILE="$2";  shift 2 ;;
    --dry-run) DRY_RUN=true;      shift   ;;
    --format)  FORMAT="$2";       shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -z "$SYMBOL" ]; then
  echo "Error: --symbol is required" >&2
  exit 1
fi

if [ -z "$TARGET_CASE" ]; then
  echo "Error: --to is required" >&2
  exit 1
fi

case "$TARGET_CASE" in
  camel|snake|pascal|kebab) ;;
  *)
    echo "Error: --to must be one of: camel, snake, pascal, kebab" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Compute new name
# ---------------------------------------------------------------------------
case "$TARGET_CASE" in
  camel)  NEW_SYMBOL="$(to_camel  "$SYMBOL")" ;;
  snake)  NEW_SYMBOL="$(to_snake  "$SYMBOL")" ;;
  pascal) NEW_SYMBOL="$(to_pascal "$SYMBOL")" ;;
  kebab)  NEW_SYMBOL="$(to_kebab  "$SYMBOL")" ;;
esac

if [ "$SYMBOL" = "$NEW_SYMBOL" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"symbol":"%s","newName":"%s","note":"already in target case","totalChanges":0,"files":[]}\n' \
      "$SYMBOL" "$NEW_SYMBOL"
  else
    echo "'$SYMBOL' is already in $TARGET_CASE case -- nothing to do."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Build rename-symbol.sh argument list
# ---------------------------------------------------------------------------
RENAME_ARGS=(
  --symbol "$SYMBOL"
  --new    "$NEW_SYMBOL"
  --scope  "$SCOPE"
  --path   "$SEARCH_PATH"
  --format "$FORMAT"
)

if [ -n "$TARGET_FILE" ]; then
  RENAME_ARGS+=(--file "$TARGET_FILE")
fi

if [ "$DRY_RUN" = true ]; then
  RENAME_ARGS+=(--dry-run)
fi

# ---------------------------------------------------------------------------
# Delegate to rename-symbol.sh
# ---------------------------------------------------------------------------
if [ "$FORMAT" != "json" ]; then
  detected="$(detect_case "$SYMBOL")"
  echo "Detected case : $detected"
  echo "Converting    : $SYMBOL  ->  $NEW_SYMBOL"
  echo ""
fi

exec "$SCRIPT_DIR/rename-symbol.sh" "${RENAME_ARGS[@]}"
