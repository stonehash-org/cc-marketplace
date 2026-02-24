#!/usr/bin/env bash
set -euo pipefail

# code-stats.sh — Aggregate code statistics for a directory.
# Uses shared-lib.sh functions and tree-sitter queries from the refactor plugin.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SEARCH_PATH=""
FORMAT="text"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --path DIR [--format text|json]

Aggregate code statistics: language breakdown, line counts, symbol counts,
function length metrics, import counts, and approximate dead code detection.

Options:
  --path DIR       Directory to analyze (required)
  --format FMT     Output format: text or json (default: text)
  -h, --help       Show this help

Examples:
  $(basename "$0") --path ./src
  $(basename "$0") --path ./src --format json
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   SEARCH_PATH="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SEARCH_PATH" ]; then
  echo "Error: --path is required" >&2
  usage
fi

if [ ! -d "$SEARCH_PATH" ]; then
  echo "Error: --path must be a directory: $SEARCH_PATH" >&2
  exit 1
fi

case "$FORMAT" in
  text|json) ;;
  *) echo "Error: --format must be text or json" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Supported extensions
# ---------------------------------------------------------------------------
EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# ---------------------------------------------------------------------------
# Human-readable language label from extension
# ---------------------------------------------------------------------------
lang_label() {
  local file="$1"
  case "$file" in
    *.ts|*.tsx)              echo "TypeScript" ;;
    *.js|*.jsx|*.mjs|*.cjs) echo "JavaScript" ;;
    *.py)                    echo "Python" ;;
    *.java)                  echo "Java" ;;
    *.kt|*.kts)              echo "Kotlin" ;;
    *)                       echo "Other" ;;
  esac
}

# ---------------------------------------------------------------------------
# Comment detection helpers
# ---------------------------------------------------------------------------
is_comment_line() {
  local lang="$1"
  local line="$2"
  case "$lang" in
    typescript)
      [[ "$line" =~ ^[[:space:]]*(//|/\*|\*) ]]
      ;;
    python)
      [[ "$line" =~ ^[[:space:]]*(#|\"\"\"|\'\'\') ]]
      ;;
    java)
      [[ "$line" =~ ^[[:space:]]*(//|/\*|\*) ]]
      ;;
    *)
      return 1
      ;;
  esac
}

is_blank_line() {
  [[ "$1" =~ ^[[:space:]]*$ ]]
}

# ---------------------------------------------------------------------------
# Import line detection
# ---------------------------------------------------------------------------
is_import_line() {
  local lang="$1"
  local line="$2"
  case "$lang" in
    typescript)
      [[ "$line" =~ ^[[:space:]]*(import|require)[[:space:]\(] ]]
      ;;
    python)
      [[ "$line" =~ ^[[:space:]]*(import |from [[:space:]]*[^ ]+[[:space:]]+import) ]]
      ;;
    java)
      [[ "$line" =~ ^[[:space:]]*import[[:space:]] ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# Extract external package name from an import line
extract_package() {
  local lang="$1"
  local line="$2"
  local pkg=""

  case "$lang" in
    typescript)
      # import ... from 'pkg' / require('pkg')
      if [[ "$line" =~ from[[:space:]]+[\'\"]([^\'\"]+)[\'\"] ]]; then
        pkg="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ require\([[:space:]]*[\'\"]([^\'\"]+)[\'\"] ]]; then
        pkg="${BASH_REMATCH[1]}"
      fi
      ;;
    python)
      # import pkg / from pkg import ...
      if [[ "$line" =~ ^[[:space:]]*from[[:space:]]+([^[:space:]]+)[[:space:]]+import ]]; then
        pkg="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]*import[[:space:]]+([^[:space:],]+) ]]; then
        pkg="${BASH_REMATCH[1]}"
      fi
      ;;
    java)
      # import com.example.Foo;
      if [[ "$line" =~ ^[[:space:]]*import[[:space:]]+(static[[:space:]]+)?([^[:space:];]+) ]]; then
        pkg="${BASH_REMATCH[2]}"
      fi
      ;;
  esac

  # Skip relative imports
  if [ -n "$pkg" ]; then
    case "$lang" in
      typescript)
        # relative paths start with . or /
        [[ "$pkg" =~ ^[./] ]] && return
        # Get top-level package (handle scoped @org/pkg)
        if [[ "$pkg" =~ ^@ ]]; then
          # @scope/name -> @scope/name
          pkg=$(echo "$pkg" | cut -d'/' -f1-2)
        else
          pkg=$(echo "$pkg" | cut -d'/' -f1)
        fi
        ;;
      python)
        # relative imports start with .
        [[ "$pkg" =~ ^\. ]] && return
        # Get top-level module
        pkg=$(echo "$pkg" | cut -d'.' -f1)
        ;;
      java)
        # Get top two segments as package identifier
        pkg=$(echo "$pkg" | cut -d'.' -f1-2)
        ;;
    esac
    echo "$pkg"
  fi
}

# ---------------------------------------------------------------------------
# Discover source files via find_source_files (shared-lib)
# ---------------------------------------------------------------------------
FILES=()
while IFS= read -r _f; do
  [ -n "$_f" ] && FILES+=("$_f")
done < <(find_source_files "$SEARCH_PATH")

if [ ${#FILES[@]} -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    cat <<'EOF'
{"path":"","languages":{},"lines":{"total":0,"code":0,"comments":0,"blank":0},"symbols":{"functions":0,"classes":0,"variables":0},"functionStats":{"average":0,"longest":{"name":"","file":"","lines":0}},"imports":{"total":0,"uniquePackages":0},"deadCode":{"count":0,"percentage":0}}
EOF
  else
    echo "No supported source files found in: $SEARCH_PATH"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Accumulators
# ---------------------------------------------------------------------------
# Parallel arrays for language counts (bash 3.2 compatible)
LANG_COUNT_KEYS=()
LANG_COUNT_VALS=()

TOTAL_LINES=0
CODE_LINES=0
COMMENT_LINES=0
BLANK_LINES=0

FUNC_COUNT=0
CLASS_COUNT=0
VAR_COUNT=0

IMPORT_TOTAL=0
# Newline-separated list for unique package deduplication (bash 3.2 compatible)
UNIQUE_PKG_LIST=""
UNIQUE_PKG_COUNT_VAL=0

# Function length tracking
FUNC_LENGTH_SUM=0
FUNC_LENGTH_COUNT=0
LONGEST_FUNC_NAME=""
LONGEST_FUNC_FILE=""
LONGEST_FUNC_LINES=0

# Definition names for dead code analysis
# Store as: "name\tfile\tline" entries
ALL_DEFS=()
# Parallel arrays for definition name counting (bash 3.2 compatible)
DEF_NAME_KEYS=()
DEF_NAME_VALS=()

# ---------------------------------------------------------------------------
# Two regex patterns for tree-sitter output (from shared-lib / existing scripts)
# ---------------------------------------------------------------------------
# Pattern A: @capture (row, col) ... `text`
# Pattern B: capture: name, text: "value", row: N, col: N

# ---------------------------------------------------------------------------
# Process each file
# ---------------------------------------------------------------------------
for file in "${FILES[@]}"; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue

  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  label=$(lang_label "$file")

  # --- Language counts (parallel arrays, bash 3.2 compatible) ---
  _lc_found=false
  for _lc_i in "${!LANG_COUNT_KEYS[@]}"; do
    if [ "${LANG_COUNT_KEYS[$_lc_i]}" = "$label" ]; then
      LANG_COUNT_VALS[$_lc_i]=$(( ${LANG_COUNT_VALS[$_lc_i]} + 1 ))
      _lc_found=true
      break
    fi
  done
  if [ "$_lc_found" = false ]; then
    LANG_COUNT_KEYS+=("$label")
    LANG_COUNT_VALS+=("1")
  fi

  # --- Line counts ---
  while IFS= read -r line || [ -n "$line" ]; do
    TOTAL_LINES=$(( TOTAL_LINES + 1 ))
    if is_blank_line "$line"; then
      BLANK_LINES=$(( BLANK_LINES + 1 ))
    elif is_comment_line "$lang" "$line"; then
      COMMENT_LINES=$(( COMMENT_LINES + 1 ))
    else
      CODE_LINES=$(( CODE_LINES + 1 ))
    fi

    # --- Import extraction ---
    if is_import_line "$lang" "$line"; then
      IMPORT_TOTAL=$(( IMPORT_TOTAL + 1 ))
      pkg=$(extract_package "$lang" "$line")
      if [ -n "$pkg" ]; then
        if ! echo "$UNIQUE_PKG_LIST" | grep -qxF "$pkg"; then
          UNIQUE_PKG_LIST="${UNIQUE_PKG_LIST}${pkg}"$'\n'
          UNIQUE_PKG_COUNT_VAL=$(( UNIQUE_PKG_COUNT_VAL + 1 ))
        fi
      fi
    fi
  done < "$file"

  # --- Symbol counts (via symbols.scm query) ---
  query_file=$(get_query_file "$lang" "symbols")
  if [ -f "$query_file" ]; then
    ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
    if [ -n "$ts_output" ]; then
      re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
      while IFS= read -r ts_line; do
        capture="" row="" col="" text=""

        if [[ "$ts_line" =~ $re_v026 ]]; then
          capture="${BASH_REMATCH[1]}"
          row="${BASH_REMATCH[2]}"
          col="${BASH_REMATCH[3]}"
          text="${BASH_REMATCH[4]}"
        elif [[ "$ts_line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
          capture="${BASH_REMATCH[1]}"
          row="${BASH_REMATCH[2]}"
          col="${BASH_REMATCH[3]}"
          text="${BASH_REMATCH[4]}"
        elif [[ "$ts_line" =~ capture:[[:space:]]*([a-z_.]+),[[:space:]]*text:[[:space:]]*\"([^\"]*)\",\ row:[[:space:]]*([0-9]+),\ col:[[:space:]]*([0-9]+) ]]; then
          capture="${BASH_REMATCH[1]}"
          text="${BASH_REMATCH[2]}"
          row="${BASH_REMATCH[3]}"
          col="${BASH_REMATCH[4]}"
        else
          continue
        fi

        [ "$capture" != "symbol.definition" ] && continue
        [ -z "$text" ] && continue

        line_num=$(( row + 1 ))
        src_line=$(get_line "$file" "$line_num")
        sym_type=$(classify_symbol "$lang" "$src_line")

        case "$sym_type" in
          function)  FUNC_COUNT=$(( FUNC_COUNT + 1 )) ;;
          class)     CLASS_COUNT=$(( CLASS_COUNT + 1 )) ;;
          interface) CLASS_COUNT=$(( CLASS_COUNT + 1 )) ;;
          variable)  VAR_COUNT=$(( VAR_COUNT + 1 )) ;;
        esac

        # Track for dead code analysis
        ALL_DEFS+=("${text}	${file}	${line_num}")
        _dn_found=false
        for _dn_i in "${!DEF_NAME_KEYS[@]}"; do
          if [ "${DEF_NAME_KEYS[$_dn_i]}" = "$text" ]; then
            DEF_NAME_VALS[$_dn_i]=$(( ${DEF_NAME_VALS[$_dn_i]} + 1 ))
            _dn_found=true
            break
          fi
        done
        if [ "$_dn_found" = false ]; then
          DEF_NAME_KEYS+=("$text")
          DEF_NAME_VALS+=("1")
        fi
      done <<< "$ts_output"
    fi
  fi

  # --- Function length stats (via block-range.scm query) ---
  block_query=$(get_query_file "$lang" "block-range")
  if [ -f "$block_query" ]; then
    block_output=$(tree-sitter query "$block_query" "$file" 2>/dev/null || true)
    if [ -n "$block_output" ]; then
      current_name=""
      body_start=""
      body_end=""

      re_v026_bl='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
      while IFS= read -r bl_line; do
        bl_capture="" bl_row="" bl_text=""

        if [[ "$bl_line" =~ $re_v026_bl ]]; then
          bl_capture="${BASH_REMATCH[1]}"
          bl_row="${BASH_REMATCH[2]}"
          bl_text="${BASH_REMATCH[4]}"
          bl_end_row=""
        elif [[ "$bl_line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*-.*\(([0-9]+),\ ([0-9]+)\).*\`([^\`]*)\` ]]; then
          # Range capture with start and end: @capture (r1, c1) - (r2, c2) `text`
          bl_capture="${BASH_REMATCH[1]}"
          bl_row="${BASH_REMATCH[2]}"
          bl_text="${BASH_REMATCH[6]}"
          bl_end_row="${BASH_REMATCH[4]}"
        elif [[ "$bl_line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
          bl_capture="${BASH_REMATCH[1]}"
          bl_row="${BASH_REMATCH[2]}"
          bl_text="${BASH_REMATCH[4]}"
          bl_end_row=""
        elif [[ "$bl_line" =~ capture:[[:space:]]*([a-z_.]+),[[:space:]]*text:[[:space:]]*\"([^\"]*)\",\ row:[[:space:]]*([0-9]+),\ col:[[:space:]]*([0-9]+) ]]; then
          bl_capture="${BASH_REMATCH[1]}"
          bl_text="${BASH_REMATCH[2]}"
          bl_row="${BASH_REMATCH[3]}"
          bl_end_row=""
        else
          continue
        fi

        if [ "$bl_capture" = "block.name" ]; then
          current_name="$bl_text"
        elif [ "$bl_capture" = "block.body" ]; then
          # For block.body we need the range — start and end row
          # tree-sitter outputs ranges like: @block.body (10, 0) - (25, 1)
          if [ -n "$bl_end_row" ]; then
            body_start="$bl_row"
            body_end="$bl_end_row"
          else
            # Fallback: try to parse the range from the line differently
            # Some tree-sitter versions output row range in a single capture
            body_start="$bl_row"
            body_end="$bl_row"
          fi

          if [ -n "$body_start" ] && [ -n "$body_end" ]; then
            func_len=$(( body_end - body_start + 1 ))
            if [ "$func_len" -gt 0 ]; then
              FUNC_LENGTH_SUM=$(( FUNC_LENGTH_SUM + func_len ))
              FUNC_LENGTH_COUNT=$(( FUNC_LENGTH_COUNT + 1 ))

              if [ "$func_len" -gt "$LONGEST_FUNC_LINES" ]; then
                LONGEST_FUNC_LINES="$func_len"
                LONGEST_FUNC_NAME="${current_name:-<anonymous>}"
                LONGEST_FUNC_FILE="$file"
              fi
            fi
          fi

          current_name=""
          body_start=""
          body_end=""
        fi
      done <<< "$block_output"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Compute averages
# ---------------------------------------------------------------------------
if [ "$FUNC_LENGTH_COUNT" -gt 0 ]; then
  AVG_FUNC_LEN=$(( FUNC_LENGTH_SUM / FUNC_LENGTH_COUNT ))
else
  AVG_FUNC_LEN=0
fi

UNIQUE_PKG_COUNT=$UNIQUE_PKG_COUNT_VAL

# ---------------------------------------------------------------------------
# Dead code analysis (simplified)
# For each definition, check if any other file references the symbol name.
# If not found elsewhere (outside its own file), count as dead.
# ---------------------------------------------------------------------------
DEAD_COUNT=0
TOTAL_DEFS=${#ALL_DEFS[@]}

# Build rg glob args
RG_GLOBS=()
for ext in "${EXTENSIONS[@]}"; do
  RG_GLOBS+=("--glob" "*.$ext")
done

for def_entry in "${ALL_DEFS[@]}"; do
  IFS=$'\t' read -r def_name def_file def_line_num <<< "$def_entry"
  [ -z "$def_name" ] && continue

  # Skip very short names (likely false positives like 'i', 'x')
  if [ ${#def_name} -le 1 ]; then
    continue
  fi

  # Search for the symbol name in all source files, excluding the defining file
  _rg_out=$(rg --count-matches --fixed-strings --word-regexp \
    "${RG_GLOBS[@]}" \
    "$def_name" "$SEARCH_PATH" 2>/dev/null || true)
  ref_count=$(echo "$_rg_out" | { grep -v "^${def_file}:" || true; } | awk -F: '{s+=$NF} END {print s+0}')
  ref_count="${ref_count:-0}"

  if [ "$ref_count" -eq 0 ]; then
    # Also check in the defining file itself for references beyond the definition line
    _rg_out2=$(rg --count-matches --fixed-strings --word-regexp \
      "${RG_GLOBS[@]}" \
      "$def_name" "$def_file" 2>/dev/null || true)
    self_count=$(echo "$_rg_out2" | awk -F: '{s+=$NF} END {print s+0}')
    self_count="${self_count:-0}"
    # If the name appears only once (the definition itself), it is dead
    if [ "$self_count" -le 1 ]; then
      DEAD_COUNT=$(( DEAD_COUNT + 1 ))
    fi
  fi
done

if [ "$TOTAL_DEFS" -gt 0 ]; then
  # Compute percentage with one decimal: (DEAD_COUNT * 1000 / TOTAL_DEFS + 5) / 10
  DEAD_PCT_X10=$(( DEAD_COUNT * 1000 / TOTAL_DEFS ))
  DEAD_PCT_INT=$(( DEAD_PCT_X10 / 10 ))
  DEAD_PCT_FRAC=$(( DEAD_PCT_X10 % 10 ))
else
  DEAD_PCT_INT=0
  DEAD_PCT_FRAC=0
fi

# ---------------------------------------------------------------------------
# Format numbers with commas (macOS compatible)
# ---------------------------------------------------------------------------
fmt_num() {
  # Use printf + sed for bash 3.2 compatibility
  printf '%d' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  # Build languages object
  lang_json="{"
  first=true
  for _lc_i in "${!LANG_COUNT_KEYS[@]}"; do
    if $first; then first=false; else lang_json+=","; fi
    lang_json+="\"${LANG_COUNT_KEYS[$_lc_i]}\":${LANG_COUNT_VALS[$_lc_i]}"
  done
  lang_json+="}"

  # Escape file path for JSON
  longest_file_json=$(printf '%s' "$LONGEST_FUNC_FILE" | sed 's/"/\\"/g')
  longest_name_json=$(printf '%s' "$LONGEST_FUNC_NAME" | sed 's/"/\\"/g')

  cat <<EOF
{
  "path": "$(printf '%s' "$SEARCH_PATH" | sed 's/"/\\"/g')",
  "languages": $lang_json,
  "lines": {"total": $TOTAL_LINES, "code": $CODE_LINES, "comments": $COMMENT_LINES, "blank": $BLANK_LINES},
  "symbols": {"functions": $FUNC_COUNT, "classes": $CLASS_COUNT, "variables": $VAR_COUNT},
  "functionStats": {"average": $AVG_FUNC_LEN, "longest": {"name": "$longest_name_json", "file": "$longest_file_json", "lines": $LONGEST_FUNC_LINES}},
  "imports": {"total": $IMPORT_TOTAL, "uniquePackages": $UNIQUE_PKG_COUNT},
  "deadCode": {"count": $DEAD_COUNT, "percentage": ${DEAD_PCT_INT}.${DEAD_PCT_FRAC}}
}
EOF
  exit 0
fi

# --- Text output ---

echo "=== Code Stats for $SEARCH_PATH ==="
echo ""

# Languages line
lang_parts=()
for _lc_i in "${!LANG_COUNT_KEYS[@]}"; do
  lang_parts+=("${LANG_COUNT_KEYS[$_lc_i]} (${LANG_COUNT_VALS[$_lc_i]} files)")
done
# Join with ", "
lang_str=""
for i in "${!lang_parts[@]}"; do
  if [ "$i" -gt 0 ]; then
    lang_str+=", "
  fi
  lang_str+="${lang_parts[$i]}"
done
printf "%-12s%s\n" "Languages:" "$lang_str"

# Lines
printf "%-12s%s total (%s code, %s comments, %s blank)\n" \
  "Lines:" "$(fmt_num $TOTAL_LINES)" "$(fmt_num $CODE_LINES)" "$(fmt_num $COMMENT_LINES)" "$(fmt_num $BLANK_LINES)"

# Symbols
printf "%-12s%s functions, %s classes, %s variables\n" \
  "Symbols:" "$(fmt_num $FUNC_COUNT)" "$(fmt_num $CLASS_COUNT)" "$(fmt_num $VAR_COUNT)"

# Function stats
if [ "$FUNC_LENGTH_COUNT" -gt 0 ]; then
  printf "%-12s%s lines (longest: %s at %s lines)\n" \
    "Avg func:" "$AVG_FUNC_LEN" "$LONGEST_FUNC_NAME" "$LONGEST_FUNC_LINES"
else
  printf "%-12s%s\n" "Avg func:" "N/A (no function bodies detected)"
fi

# Imports
printf "%-12s%s total, %s unique packages\n" \
  "Imports:" "$(fmt_num $IMPORT_TOTAL)" "$(fmt_num $UNIQUE_PKG_COUNT)"

# Dead code
printf "%-12s%s symbols (%s.%s%% of definitions)\n" \
  "Dead code:" "$(fmt_num $DEAD_COUNT)" "$DEAD_PCT_INT" "$DEAD_PCT_FRAC"
