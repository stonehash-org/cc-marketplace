#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

SYMBOL=""
NEW_NAME=""
SEARCH_PATH="."
INCLUDE_LINES=""
EXCLUDE_LINES=""
DRY_RUN=false
FORMAT="text"

usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol NAME --new NEW_NAME --path DIR [options]

Non-interactive selective rename. Find references and rename only specific ones
using --include-lines or --exclude-lines.

Options:
  --symbol NAME            Symbol name to search for (required)
  --new NEW_NAME           New symbol name (required)
  --path DIR               Directory to search in (default: .)
  --include-lines "N,M"    Only rename on these line numbers (comma-separated)
  --exclude-lines "N,M"    Rename all EXCEPT these line numbers (comma-separated)
  --dry-run                Show what would change without modifying files
  --format FMT             Output format: text or json (default: text)
  -h, --help               Show this help

If neither --include-lines nor --exclude-lines is given, shows a preview of all
references for the agent to review (no rename performed).

--include-lines and --exclude-lines are mutually exclusive.

Example:
  $(basename "$0") --symbol userId --new accountId --path ./src
  $(basename "$0") --symbol userId --new accountId --path ./src --include-lines "12,15,20"
  $(basename "$0") --symbol userId --new accountId --path ./src --exclude-lines "5,8"
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol)        SYMBOL="$2"; shift 2 ;;
    --new)           NEW_NAME="$2"; shift 2 ;;
    --path)          SEARCH_PATH="$2"; shift 2 ;;
    --include-lines) INCLUDE_LINES="$2"; shift 2 ;;
    --exclude-lines) EXCLUDE_LINES="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --format)        FORMAT="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *)               echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SYMBOL" ]; then
  echo "Error: --symbol is required" >&2
  exit 1
fi

if [ -n "$INCLUDE_LINES" ] && [ -n "$EXCLUDE_LINES" ]; then
  echo "Error: --include-lines and --exclude-lines are mutually exclusive" >&2
  exit 1
fi

# Determine mode: preview (no include/exclude), or selective rename
PREVIEW_MODE=false
if [ -z "$INCLUDE_LINES" ] && [ -z "$EXCLUDE_LINES" ]; then
  PREVIEW_MODE=true
fi

# In rename mode, --new is required
if [ "$PREVIEW_MODE" = false ] && [ -z "$NEW_NAME" ]; then
  echo "Error: --new is required when using --include-lines or --exclude-lines" >&2
  exit 1
fi

# Parse comma-separated line numbers into an array
parse_lines() {
  local csv="$1"
  local IFS=","
  local nums=()
  for n in $csv; do
    # Trim whitespace
    n="${n## }"
    n="${n%% }"
    [ -n "$n" ] && nums+=("$n")
  done
  printf '%s\n' "${nums[@]}"
}

# Check if a value is in an array (newline-separated list)
line_in_list() {
  local needle="$1"
  local haystack="$2"
  echo "$haystack" | grep -qx "$needle"
}

# --- Find all references ---
EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

CANDIDATES=$(eval rg -l --fixed-strings '"$SYMBOL"' '"$SEARCH_PATH"' \
  $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)

if [ -z "$CANDIDATES" ]; then
  if [ "$FORMAT" = "json" ]; then
    if [ "$PREVIEW_MODE" = true ]; then
      echo '{"symbol":"'"$SYMBOL"'","totalReferences":0,"references":[]}'
    else
      jq -n \
        --arg sym "$SYMBOL" \
        --arg new "${NEW_NAME:-}" \
        '{symbol: $sym, newName: $new, totalReferences: 0, renamed: 0, skipped: 0, renamedLocations: [], skippedLocations: [], dryRun: false}'
    fi
  else
    echo "No references found for '$SYMBOL'"
  fi
  exit 0
fi

# Collect all references as file:line pairs with line content
ALL_REFS=()       # file:line entries
ALL_CONTENTS=()   # corresponding line content

while IFS= read -r file; do
  [ -z "$file" ] && continue
  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  query_file="$QUERIES_DIR/$lang/symbols.scm"
  [ ! -f "$query_file" ] && continue

  ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    if [[ "$line" =~ $re_v026 ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      capture="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
      capture="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
      row="${BASH_REMATCH[3]}"
    else
      continue
    fi

    [ "$text" != "$SYMBOL" ] && continue
    is_excludable "$capture" && continue

    sed_line=$((row + 1))
    content=$(get_line "$file" "$sed_line")
    ALL_REFS+=("$file:$sed_line")
    ALL_CONTENTS+=("$content")
  done <<< "$ts_output"
done <<< "$CANDIDATES"

TOTAL=${#ALL_REFS[@]}

if [ "$TOTAL" -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    if [ "$PREVIEW_MODE" = true ]; then
      echo '{"symbol":"'"$SYMBOL"'","totalReferences":0,"references":[]}'
    else
      jq -n \
        --arg sym "$SYMBOL" \
        --arg new "${NEW_NAME:-}" \
        '{symbol: $sym, newName: $new, totalReferences: 0, renamed: 0, skipped: 0, renamedLocations: [], skippedLocations: [], dryRun: false}'
    fi
  else
    echo "No references found for '$SYMBOL'"
  fi
  exit 0
fi

# --- Preview mode ---
if [ "$PREVIEW_MODE" = true ]; then
  if [ "$FORMAT" = "json" ]; then
    refs_json="["
    for i in "${!ALL_REFS[@]}"; do
      [ "$i" -gt 0 ] && refs_json+=","
      ref="${ALL_REFS[$i]}"
      content="${ALL_CONTENTS[$i]}"
      # Escape for JSON
      content_escaped=$(printf '%s' "$content" | jq -R . 2>/dev/null || echo '""')
      refs_json+="{\"location\":\"$ref\",\"content\":${content_escaped}}"
    done
    refs_json+="]"

    jq -n \
      --arg sym "$SYMBOL" \
      --argjson total "$TOTAL" \
      --argjson refs "$refs_json" \
      '{symbol: $sym, totalReferences: $total, references: $refs}'
  else
    echo "=== References for '$SYMBOL' ($TOTAL found) ==="
    echo ""
    for i in "${!ALL_REFS[@]}"; do
      ref="${ALL_REFS[$i]}"
      content="${ALL_CONTENTS[$i]}"
      # Trim leading whitespace from content for display
      content_trimmed="${content#"${content%%[![:space:]]*}"}"
      idx=$((i + 1))
      printf "[%d] %-30s %s\n" "$idx" "$ref" "$content_trimmed"
    done
    echo ""
    echo "Use --include-lines \"12,15\" or --exclude-lines \"5\" to select which to rename."
  fi
  exit 0
fi

# --- Selective rename mode ---
INCLUDE_SET=""
EXCLUDE_SET=""
if [ -n "$INCLUDE_LINES" ]; then
  INCLUDE_SET=$(parse_lines "$INCLUDE_LINES")
fi
if [ -n "$EXCLUDE_LINES" ]; then
  EXCLUDE_SET=$(parse_lines "$EXCLUDE_LINES")
fi

RENAMED_LOCS=()
SKIPPED_LOCS=()

# Group references by file for efficient sed (parallel arrays, bash 3.2 compatible)
_FRL_KEYS=()
_FRL_VALS=()

for i in "${!ALL_REFS[@]}"; do
  ref="${ALL_REFS[$i]}"
  file="${ref%%:*}"
  line_num="${ref##*:}"

  selected=false
  if [ -n "$INCLUDE_SET" ]; then
    if line_in_list "$line_num" "$INCLUDE_SET"; then
      selected=true
    fi
  elif [ -n "$EXCLUDE_SET" ]; then
    if ! line_in_list "$line_num" "$EXCLUDE_SET"; then
      selected=true
    fi
  fi

  if [ "$selected" = true ]; then
    RENAMED_LOCS+=("$ref")
    _frl_found=false
    for _frl_i in "${!_FRL_KEYS[@]}"; do
      if [ "${_FRL_KEYS[$_frl_i]}" = "$file" ]; then
        _FRL_VALS[$_frl_i]="${_FRL_VALS[$_frl_i]} $line_num"
        _frl_found=true
        break
      fi
    done
    if [ "$_frl_found" = false ]; then
      _FRL_KEYS+=("$file")
      _FRL_VALS+=("$line_num")
    fi
  else
    SKIPPED_LOCS+=("$ref")
  fi
done

RENAMED_COUNT=${#RENAMED_LOCS[@]}
SKIPPED_COUNT=${#SKIPPED_LOCS[@]}

# Perform the rename unless dry-run
if [ "$DRY_RUN" = false ] && [ "$RENAMED_COUNT" -gt 0 ]; then
  for _frl_i in "${!_FRL_KEYS[@]}"; do
    file="${_FRL_KEYS[$_frl_i]}"
    lines="${_FRL_VALS[$_frl_i]}"
    # Deduplicate lines
    unique_lines=$(echo "$lines" | tr ' ' '\n' | sort -un)

    SED_CMD=""
    while IFS= read -r ln; do
      [ -z "$ln" ] && continue
      SED_CMD+="${ln}s/\b${SYMBOL}\b/${NEW_NAME}/g;"
    done <<< "$unique_lines"

    [ -n "$SED_CMD" ] && sed -i '' "$SED_CMD" "$file"
  done
fi

# --- Output ---
if [ "$FORMAT" = "json" ]; then
  renamed_json=$(printf '%s\n' "${RENAMED_LOCS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
  skipped_json=$(printf '%s\n' "${SKIPPED_LOCS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg sym "$SYMBOL" \
    --arg new "$NEW_NAME" \
    --argjson total "$TOTAL" \
    --argjson renamed "$RENAMED_COUNT" \
    --argjson skipped "$SKIPPED_COUNT" \
    --argjson renamedLocs "$renamed_json" \
    --argjson skippedLocs "$skipped_json" \
    --arg dryrun "$DRY_RUN" \
    '{symbol: $sym, newName: $new, totalReferences: $total, renamed: $renamed, skipped: $skipped, renamedLocations: $renamedLocs, skippedLocations: $skippedLocs, dryRun: ($dryrun == "true")}'
else
  if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN: Selective Rename '$SYMBOL' -> '$NEW_NAME' ==="
  else
    echo "=== Selective Rename '$SYMBOL' -> '$NEW_NAME' ==="
  fi
  echo ""
  echo "Renamed $RENAMED_COUNT of $TOTAL references:"
  for loc in "${RENAMED_LOCS[@]}"; do
    echo "  $loc"
  done
  echo ""
  if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo "Skipped $SKIPPED_COUNT references:"
    for loc in "${SKIPPED_LOCS[@]}"; do
      echo "  $loc"
    done
  fi
fi
