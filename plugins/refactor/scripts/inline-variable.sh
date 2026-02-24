#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

# shellcheck source=./shared-lib.sh
source "$SCRIPT_DIR/shared-lib.sh"

SYMBOL=""
TARGET_FILE=""
DRY_RUN=false
FORMAT="text"

usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol VAR_NAME --file FILE [--dry-run] [--format text|json]

Inline a variable: replace all references with its assigned value and remove the declaration.
Only operates within a single file. Aborts if the variable is reassigned.

Options:
  --symbol VAR_NAME   Variable name to inline (required)
  --file FILE         Source file to operate on (required)
  --dry-run           Show what would change without modifying the file
  --format FMT        Output format: text or json (default: text)
  -h, --help          Show this help

Example:
  $(basename "$0") --symbol baseUrl --file src/api.ts
  $(basename "$0") --symbol MAX_RETRIES --file src/config.py --dry-run
  $(basename "$0") --symbol timeout --file Main.java --format json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol)  SYMBOL="$2"; shift 2 ;;
    --file)    TARGET_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --format)  FORMAT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---

if [ -z "$SYMBOL" ]; then
  echo "Error: --symbol is required" >&2
  exit 1
fi

if [ -z "$TARGET_FILE" ]; then
  echo "Error: --file is required" >&2
  exit 1
fi

if [ ! -f "$TARGET_FILE" ]; then
  echo "Error: File not found: $TARGET_FILE" >&2
  exit 1
fi

LANG=$(detect_language "$TARGET_FILE")
if [ -z "$LANG" ]; then
  echo "Error: Unsupported file type: $TARGET_FILE" >&2
  exit 1
fi

ASSIGN_QUERY="$QUERIES_DIR/$LANG/assignment-value.scm"
SYMBOLS_QUERY="$QUERIES_DIR/$LANG/symbols.scm"

if [ ! -f "$ASSIGN_QUERY" ]; then
  echo "Error: Missing query file: $ASSIGN_QUERY" >&2
  exit 1
fi

if [ ! -f "$SYMBOLS_QUERY" ]; then
  echo "Error: Missing query file: $SYMBOLS_QUERY" >&2
  exit 1
fi

# --- Step 1: Find all assignments for the symbol ---

ASSIGN_OUTPUT=$(tree-sitter query "$ASSIGN_QUERY" "$TARGET_FILE" 2>/dev/null || true)

if [ -z "$ASSIGN_OUTPUT" ]; then
  echo "Error: tree-sitter query returned no results for $TARGET_FILE" >&2
  exit 1
fi

# Collect variable.name and variable.value captures paired by proximity.
# We walk through pairs: name capture followed by value capture on same declaration.
# Store as: row_of_name TAB value_text TAB value_row_start TAB value_row_end

DEF_COUNT=0
DEF_NAME_ROW=""
DEF_VALUE_TEXT=""
DEF_VALUE_ROW_START=""
DEF_VALUE_ROW_END=""

# Parse tree-sitter output into tab-separated: capture row col text
parse_ts_output() {
  local output="$1"
  local re_v026='capture: [0-9]+ - ([a-zA-Z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    local capture="" row="" col="" text=""
    if [[ "$line" =~ $re_v026 ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ @([a-zA-Z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\)[[:space:]]+-[[:space:]]+\(([0-9]+),\ ([0-9]+)\)[[:space:]]+\`([^\`]*)\` ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      # end_row="${BASH_REMATCH[4]}"
      # end_col="${BASH_REMATCH[5]}"
      text="${BASH_REMATCH[6]}"
    elif [[ "$line" =~ @([a-zA-Z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      text="${BASH_REMATCH[4]}"
    else
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$capture" "$row" "$col" "$text"
  done <<< "$output"
}

# Collect all parsed captures from assignment query
PARSED_ASSIGNS=$(parse_ts_output "$ASSIGN_OUTPUT")

# Walk captures in order; match name/value pairs where name matches SYMBOL
PENDING_NAME_ROW=""

while IFS=$'\t' read -r capture row col text; do
  if [ "$capture" = "variable.name" ] && [ "$text" = "$SYMBOL" ]; then
    PENDING_NAME_ROW="$row"
  elif [ "$capture" = "variable.name" ] && [ "$text" != "$SYMBOL" ]; then
    PENDING_NAME_ROW=""
  elif [ "$capture" = "variable.value" ] && [ -n "$PENDING_NAME_ROW" ]; then
    DEF_COUNT=$((DEF_COUNT + 1))
    if [ "$DEF_COUNT" -eq 1 ]; then
      DEF_NAME_ROW="$PENDING_NAME_ROW"
      DEF_VALUE_TEXT="$text"
      DEF_VALUE_ROW_START="$row"
    fi
    PENDING_NAME_ROW=""
  fi
done <<< "$PARSED_ASSIGNS"

# --- Step 2: Verify exactly one definition ---

if [ "$DEF_COUNT" -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    jq -n --arg sym "$SYMBOL" --arg file "$TARGET_FILE" \
      '{success: false, error: "No declaration found", symbol: $sym, file: $file}'
  else
    echo "Error: No declaration of '$SYMBOL' found in $TARGET_FILE" >&2
  fi
  exit 1
fi

if [ "$DEF_COUNT" -gt 1 ]; then
  if [ "$FORMAT" = "json" ]; then
    jq -n --arg sym "$SYMBOL" --arg file "$TARGET_FILE" --argjson count "$DEF_COUNT" \
      '{success: false, error: "Variable is assigned multiple times; cannot safely inline", symbol: $sym, file: $file, definitionCount: $count}'
  else
    echo "Error: '$SYMBOL' is assigned $DEF_COUNT times in $TARGET_FILE — cannot safely inline a reassigned variable" >&2
  fi
  exit 1
fi

# --- Step 3: Find all references using symbols.scm ---

SYMBOLS_OUTPUT=$(tree-sitter query "$SYMBOLS_QUERY" "$TARGET_FILE" 2>/dev/null || true)
PARSED_SYMBOLS=$(parse_ts_output "$SYMBOLS_OUTPUT")

# Collect reference lines (1-indexed), excluding strings, comments, and the declaration line itself
DECL_LINE=$((DEF_NAME_ROW + 1))  # tree-sitter rows are 0-indexed

REF_LINES=()

while IFS=$'\t' read -r capture row col text; do
  [ "$text" != "$SYMBOL" ] && continue
  is_excludable "$capture" && continue

  sed_line=$((row + 1))
  [ "$sed_line" -eq "$DECL_LINE" ] && continue

  REF_LINES+=("$sed_line")
done <<< "$PARSED_SYMBOLS"

UNIQUE_REF_LINES=($(printf "%s\n" "${REF_LINES[@]+"${REF_LINES[@]}"}" | sort -un))
REF_COUNT=${#UNIQUE_REF_LINES[@]}

# --- Step 4: Warn if value is a function call (potential side effects) ---

SIDE_EFFECT_WARN=false
# Heuristic: value contains '(' and ')' — looks like a call expression
if echo "$DEF_VALUE_TEXT" | grep -qE '\(.*\)'; then
  SIDE_EFFECT_WARN=true
fi

# --- Step 5: Report or apply changes ---

DECL_CONTENT=$(sed -n "${DECL_LINE}p" "$TARGET_FILE")

if [ "$FORMAT" = "json" ]; then
  # Build ref lines JSON array
  refs_json=$(printf '%s\n' "${UNIQUE_REF_LINES[@]+"${UNIQUE_REF_LINES[@]}"}" | jq -R 'tonumber' | jq -s . 2>/dev/null || echo "[]")

  if [ "$DRY_RUN" = true ]; then
    jq -n \
      --arg sym "$SYMBOL" \
      --arg file "$TARGET_FILE" \
      --arg value "$DEF_VALUE_TEXT" \
      --argjson decl_line "$DECL_LINE" \
      --arg decl_content "$DECL_CONTENT" \
      --argjson ref_count "$REF_COUNT" \
      --argjson refs "$refs_json" \
      --argjson side_effect "$SIDE_EFFECT_WARN" \
      --argjson dry_run true \
      '{
        success: true,
        dryRun: $dry_run,
        symbol: $sym,
        file: $file,
        value: $value,
        declaration: {line: $decl_line, content: $decl_content},
        referenceCount: $ref_count,
        referenceLines: $refs,
        sideEffectWarning: $side_effect
      }'
  else
    # Apply: replace references then delete declaration
    if [ "$REF_COUNT" -gt 0 ]; then
      SED_CMD=""
      for ln in "${UNIQUE_REF_LINES[@]}"; do
        SED_CMD+="${ln}s/\b${SYMBOL}\b/${DEF_VALUE_TEXT}/g;"
      done
      sed -i '' "$SED_CMD" "$TARGET_FILE"
    fi
    # Delete declaration line (line number may have shifted if refs were on earlier lines)
    # Recompute: count refs that were before the declaration
    REFS_BEFORE=0
    for ln in "${UNIQUE_REF_LINES[@]+"${UNIQUE_REF_LINES[@]}"}"; do
      [ "$ln" -lt "$DECL_LINE" ] && REFS_BEFORE=$((REFS_BEFORE + 1))
    done
    ACTUAL_DECL_LINE=$((DECL_LINE - REFS_BEFORE))
    # Refs on earlier lines don't shift line count; only deleted lines shift it.
    # Refs replace text on same line count, so declaration line stays at DECL_LINE.
    sed -i '' "${DECL_LINE}d" "$TARGET_FILE"

    jq -n \
      --arg sym "$SYMBOL" \
      --arg file "$TARGET_FILE" \
      --arg value "$DEF_VALUE_TEXT" \
      --argjson decl_line "$DECL_LINE" \
      --argjson ref_count "$REF_COUNT" \
      --argjson refs "$refs_json" \
      --argjson side_effect "$SIDE_EFFECT_WARN" \
      --argjson dry_run false \
      '{
        success: true,
        dryRun: $dry_run,
        symbol: $sym,
        file: $file,
        value: $value,
        declarationRemoved: $decl_line,
        referenceCount: $ref_count,
        referenceLines: $refs,
        sideEffectWarning: $side_effect
      }'
  fi

else
  # Text output
  if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN: Inline '$SYMBOL' in $TARGET_FILE ==="
  else
    echo "=== Inline '$SYMBOL' in $TARGET_FILE ==="
  fi

  echo ""
  echo "Value:       $DEF_VALUE_TEXT"
  echo "Declaration: line $DECL_LINE  ->  $DECL_CONTENT"
  echo "References:  $REF_COUNT occurrence(s)"

  if [ "$SIDE_EFFECT_WARN" = true ]; then
    echo ""
    echo "WARNING: The assigned value appears to be a function call."
    echo "         Inlining may cause repeated side effects if the variable"
    echo "         was referenced multiple times."
  fi

  if [ "$REF_COUNT" -eq 0 ]; then
    echo ""
    if [ "$DRY_RUN" = true ]; then
      echo "No references found. Declaration would be removed (dead variable)."
    else
      echo "No references found. Removing declaration (dead variable)."
      sed -i '' "${DECL_LINE}d" "$TARGET_FILE"
    fi
    exit 0
  fi

  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "Would replace references on lines:"
    for ln in "${UNIQUE_REF_LINES[@]}"; do
      original=$(sed -n "${ln}p" "$TARGET_FILE")
      modified=$(echo "$original" | sed "s/\b${SYMBOL}\b/${DEF_VALUE_TEXT}/g")
      echo "  line $ln:"
      echo "    - $original"
      echo "    + $modified"
    done
    echo ""
    echo "Would remove declaration on line $DECL_LINE."
  else
    # Apply replacements
    SED_CMD=""
    for ln in "${UNIQUE_REF_LINES[@]}"; do
      SED_CMD+="${ln}s/\b${SYMBOL}\b/${DEF_VALUE_TEXT}/g;"
    done
    sed -i '' "$SED_CMD" "$TARGET_FILE"

    # Remove declaration line
    sed -i '' "${DECL_LINE}d" "$TARGET_FILE"

    echo "Replaced references on lines:"
    for ln in "${UNIQUE_REF_LINES[@]}"; do
      echo "  line $ln"
    done
    echo ""
    echo "Removed declaration on line $DECL_LINE."
    echo ""
    echo "Done."
  fi
fi
