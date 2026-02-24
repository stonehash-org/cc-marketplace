#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

OLD_FILE=""
NEW_FILE=""
SEARCH_PATH="."
DRY_RUN=false
FORMAT="text"
GIT_MODE=false
GIT_COMMIT_MSG=""
NO_CONFIG=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --file OLD_PATH --new NEW_PATH [--path DIR] [--dry-run] [--format text|json]

Rename a file and update all import/require references across the project.

Options:
  --file OLD_PATH   Current file path (required)
  --new NEW_PATH    New file path (required)
  --path DIR        Project root to search for references (default: .)
  --dry-run         Show what would change without modifying
  --format FMT      Output format: text or json (default: text)
  --git             Stage changed files with git add (uses git mv for the file rename)
  --git-commit MSG  Auto-commit with the given message (implies --git)
  --no-config       Skip loading .refactorrc config
  -h, --help        Show this help

Example:
  $(basename "$0") --file src/utils/helpers.ts --new src/utils/string-helpers.ts
  $(basename "$0") --file src/old.py --new src/new.py --dry-run
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    OLD_FILE="$2"; shift 2 ;;
    --new)     NEW_FILE="$2"; shift 2 ;;
    --path)    SEARCH_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --format)  FORMAT="$2"; shift 2 ;;
    --git)        GIT_MODE=true; shift ;;
    --git-commit) GIT_COMMIT_MSG="$2"; shift 2 ;;
    --no-config)  NO_CONFIG=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Load config unless --no-config
if [ "$NO_CONFIG" = false ]; then
  load_config "$SEARCH_PATH"
  apply_config_defaults
fi

if [ -z "$OLD_FILE" ] || [ -z "$NEW_FILE" ]; then
  echo "Error: --file and --new are required" >&2
  exit 1
fi

if [ ! -f "$OLD_FILE" ] && [ "$DRY_RUN" = false ]; then
  echo "Error: File '$OLD_FILE' does not exist" >&2
  exit 1
fi

old_basename=$(basename "$OLD_FILE")
new_basename=$(basename "$NEW_FILE")
old_module="${old_basename%.*}"
new_module="${new_basename%.*}"
old_ext="${old_basename##*.}"

old_rel="${OLD_FILE#./}"
new_rel="${NEW_FILE#./}"
old_rel_no_ext="${old_rel%.*}"
new_rel_no_ext="${new_rel%.*}"

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")
UPDATED_REFS=()
TOTAL_REFS=0

SEARCH_PATTERNS=(
  "$old_module"
  "$old_rel"
  "$old_rel_no_ext"
)

for pattern in "${SEARCH_PATTERNS[@]}"; do
  CANDIDATES=$(eval rg -l --fixed-strings '"$pattern"' '"$SEARCH_PATH"' \
    $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ "$file" = "$OLD_FILE" ] && continue

    import_lines=$(rg -n --fixed-strings "$pattern" "$file" 2>/dev/null || true)
    [ -z "$import_lines" ] && continue

    while IFS= read -r match_line; do
      [ -z "$match_line" ] && continue
      line_num="${match_line%%:*}"
      line_content="${match_line#*:}"

      if echo "$line_content" | rg -q '(import|require|from)\s' 2>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
          new_content=$(echo "$line_content" | sed "s|${old_rel_no_ext}|${new_rel_no_ext}|g; s|${old_module}|${new_module}|g")
          UPDATED_REFS+=("$file:$line_num: $line_content -> $new_content")
        else
          sed -i '' "${line_num}s|${old_rel_no_ext}|${new_rel_no_ext}|g" "$file"
          sed -i '' "${line_num}s|${old_module}|${new_module}|g" "$file"
          UPDATED_REFS+=("$file:$line_num")
        fi
        TOTAL_REFS=$((TOTAL_REFS + 1))
      fi
    done <<< "$import_lines"
  done <<< "$CANDIDATES"
done

if [ "$DRY_RUN" = false ]; then
  new_dir=$(dirname "$NEW_FILE")
  mkdir -p "$new_dir"
  if [ "$GIT_MODE" = true ] || [ -n "$GIT_COMMIT_MSG" ]; then
    git mv "$OLD_FILE" "$NEW_FILE"
  else
    mv "$OLD_FILE" "$NEW_FILE"
  fi
fi

if [ "$FORMAT" = "json" ]; then
  refs_json=$(printf '%s\n' "${UPDATED_REFS[@]+"${UPDATED_REFS[@]}"}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
  jq -n \
    --arg old "$OLD_FILE" \
    --arg new "$NEW_FILE" \
    --argjson total "$TOTAL_REFS" \
    --arg dryrun "$DRY_RUN" \
    --argjson refs "$refs_json" \
    '{oldFile: $old, newFile: $new, totalReferences: $total, dryRun: ($dryrun == "true"), updatedReferences: $refs}'
else
  if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN: Rename file '$OLD_FILE' -> '$NEW_FILE' ==="
  else
    echo "=== Renamed file '$OLD_FILE' -> '$NEW_FILE' ==="
  fi
  echo "Updated $TOTAL_REFS import reference(s)"
  echo ""
  for r in "${UPDATED_REFS[@]+"${UPDATED_REFS[@]}"}"; do
    echo "  $r"
  done
fi

# --- Git integration ---
if [ "$GIT_MODE" = true ] || [ -n "$GIT_COMMIT_MSG" ]; then
  if [ "$DRY_RUN" = false ]; then
    # Stage import-updated files
    for entry in "${UPDATED_REFS[@]+"${UPDATED_REFS[@]}"}"; do
      ref_file="${entry%%:*}"
      git add "$ref_file" 2>/dev/null || true
    done
    git diff --cached --stat 2>/dev/null || true
    if [ -n "$GIT_COMMIT_MSG" ]; then
      git commit -m "$GIT_COMMIT_MSG" 2>/dev/null || true
    fi
  fi
fi
