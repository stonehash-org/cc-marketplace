#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

OLD_SYMBOL=""
NEW_SYMBOL=""
SCOPE="project"
SEARCH_PATH="."
TARGET_FILE=""
DRY_RUN=false
FORMAT="text"
START_LINE=""
END_LINE=""
GIT_MODE=false
GIT_COMMIT_MSG=""
NO_CONFIG=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol OLD --new NEW [--scope file|project] [--path DIR] [--file FILE] [--start-line N] [--end-line M] [--dry-run] [--format text|json]

Rename a symbol using tree-sitter AST analysis.
Only renames actual code references — skips strings and comments.

Options:
  --symbol OLD    Current symbol name (required)
  --new NEW       New symbol name (required)
  --scope SCOPE   file (single file) or project (all files) (default: project)
  --path DIR      Project root directory (default: .)
  --file FILE     Target file (required when scope=file)
  --start-line N  Only rename within this line range (requires --end-line and --file)
  --end-line M    End of line range (requires --start-line and --file)
  --dry-run       Show what would change without modifying files
  --format FMT    Output format: text or json (default: text)
  --git             Stage changed files with git add
  --git-commit MSG  Auto-commit with the given message (implies --git)
  --no-config       Skip loading .refactorrc config
  -h, --help      Show this help

Example:
  $(basename "$0") --symbol userId --new accountId --path ./src
  $(basename "$0") --symbol oldFunc --new newFunc --scope file --file ./src/utils.ts
  $(basename "$0") --symbol MyClass --new BetterClass --dry-run
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol)  OLD_SYMBOL="$2"; shift 2 ;;
    --new)     NEW_SYMBOL="$2"; shift 2 ;;
    --scope)   SCOPE="$2"; shift 2 ;;
    --path)    SEARCH_PATH="$2"; shift 2 ;;
    --file)    TARGET_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --format)  FORMAT="$2"; shift 2 ;;
    --start-line) START_LINE="$2"; shift 2 ;;
    --end-line)   END_LINE="$2"; shift 2 ;;
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

if [ -z "$OLD_SYMBOL" ] || [ -z "$NEW_SYMBOL" ]; then
  echo "Error: --symbol and --new are required" >&2
  exit 1
fi

if [ "$SCOPE" = "file" ] && [ -z "$TARGET_FILE" ]; then
  echo "Error: --file is required when scope=file" >&2
  exit 1
fi

if [ -n "$START_LINE" ] || [ -n "$END_LINE" ]; then
  if [ -z "$START_LINE" ] || [ -z "$END_LINE" ]; then
    echo "Error: both --start-line and --end-line must be provided together" >&2
    exit 1
  fi
  if [ -z "$TARGET_FILE" ]; then
    echo "Error: --file is required when using --start-line/--end-line" >&2
    exit 1
  fi
fi

detect_language() {
  local file="$1"
  case "$file" in
    *.ts|*.tsx)   echo "typescript" ;;
    *.js|*.jsx|*.mjs|*.cjs) echo "typescript" ;;
    *.py)         echo "python" ;;
    *.java)       echo "java" ;;
    *.kt|*.kts)       echo "kotlin" ;;
    *)            echo "" ;;
  esac
}

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")
CHANGES=()
CHANGED_FILES=()
TOTAL_CHANGES=0

if [ "$SCOPE" = "file" ]; then
  FILES="$TARGET_FILE"
else
  FILES=$(eval rg -l --fixed-strings '"$OLD_SYMBOL"' '"$SEARCH_PATH"' \
    $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)
fi

[ -z "$FILES" ] && {
  if [ "$FORMAT" = "json" ]; then
    echo '{"symbol":"'"$OLD_SYMBOL"'","newName":"'"$NEW_SYMBOL"'","totalChanges":0,"files":[]}'
  else
    echo "No occurrences of '$OLD_SYMBOL' found"
  fi
  exit 0
}

while IFS= read -r file; do
  [ -z "$file" ] && continue
  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  query_file="$QUERIES_DIR/$lang/symbols.scm"
  [ ! -f "$query_file" ] && continue

  ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  RENAME_LINES=()

  while IFS= read -r line; do
    re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
    if [[ "$line" =~ $re_v026 ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      text="${BASH_REMATCH[4]}"
    else
      continue
    fi

    [ "$text" != "$OLD_SYMBOL" ] && continue
    [[ "$capture" == string.* ]] && continue
    [[ "$capture" == comment.* ]] && continue

    sed_line=$((row + 1))
    if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
      if [ "$sed_line" -lt "$START_LINE" ] || [ "$sed_line" -gt "$END_LINE" ]; then
        continue
      fi
    fi
    RENAME_LINES+=("$sed_line")
  done <<< "$ts_output"

  [ ${#RENAME_LINES[@]} -eq 0 ] && continue

  UNIQUE_LINES=($(printf "%s\n" "${RENAME_LINES[@]}" | sort -un))
  file_changes=${#UNIQUE_LINES[@]}
  TOTAL_CHANGES=$((TOTAL_CHANGES + file_changes))
  CHANGED_FILES+=("$file:$file_changes")

  if [ "$DRY_RUN" = true ]; then
    for ln in "${UNIQUE_LINES[@]}"; do
      original=$(sed -n "${ln}p" "$file")
      modified=$(echo "$original" | sed "s/\b${OLD_SYMBOL}\b/${NEW_SYMBOL}/g")
      CHANGES+=("$file:$ln: $original -> $modified")
    done
  else
    SED_CMD=""
    for ln in "${UNIQUE_LINES[@]}"; do
      SED_CMD+="${ln}s/\b${OLD_SYMBOL}\b/${NEW_SYMBOL}/g;"
    done
    sed -i '' "$SED_CMD" "$file"

    for ln in "${UNIQUE_LINES[@]}"; do
      CHANGES+=("$file:$ln")
    done
  fi
done <<< "$FILES"

if [ "$FORMAT" = "json" ]; then
  files_json=$(printf '%s\n' "${CHANGED_FILES[@]+"${CHANGED_FILES[@]}"}" 2>/dev/null | jq -R 'split(":") | {file: .[0], changes: (.[1] | tonumber)}' | jq -s . 2>/dev/null || echo "[]")
  details_json=$(printf '%s\n' "${CHANGES[@]+"${CHANGES[@]}"}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg old "$OLD_SYMBOL" \
    --arg new "$NEW_SYMBOL" \
    --argjson total "$TOTAL_CHANGES" \
    --arg dryrun "$DRY_RUN" \
    --argjson files "$files_json" \
    --argjson details "$details_json" \
    '{symbol: $old, newName: $new, totalChanges: $total, dryRun: ($dryrun == "true"), files: $files, details: $details}'
else
  if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN: Rename '$OLD_SYMBOL' -> '$NEW_SYMBOL' ==="
  else
    echo "=== Renamed '$OLD_SYMBOL' -> '$NEW_SYMBOL' ==="
  fi
  echo "Total changes: $TOTAL_CHANGES across ${#CHANGED_FILES[@]} file(s)"
  echo ""
  for c in "${CHANGES[@]+"${CHANGES[@]}"}"; do
    echo "  $c"
  done
fi

# --- Git integration ---
if [ "$GIT_MODE" = true ] || [ -n "$GIT_COMMIT_MSG" ]; then
  if [ "$DRY_RUN" = false ] && [ "$TOTAL_CHANGES" -gt 0 ]; then
    # Check for dirty state
    if ! git diff --quiet 2>/dev/null; then
      echo "Warning: Working directory has uncommitted changes" >&2
    fi
    # Stage changed files
    for entry in "${CHANGED_FILES[@]}"; do
      changed_file="${entry%%:*}"
      git add "$changed_file" 2>/dev/null || true
    done
    # Show diff stat
    git diff --cached --stat 2>/dev/null || true
    # Auto-commit if message provided
    if [ -n "$GIT_COMMIT_MSG" ]; then
      git commit -m "$GIT_COMMIT_MSG" 2>/dev/null || true
    fi
  fi
fi
