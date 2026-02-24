#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

SEARCH_PATH=""
FORMAT="text"
FIX=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --path DIR [--format text|json] [--fix]

Detect imports that are not used in the file where they are imported.

Options:
  --path DIR      Directory to scan (required)
  --format FMT    Output format: text or json (default: text)
  --fix           Remove unused import lines in place using sed
  -h, --help      Show this help

Examples:
  $(basename "$0") --path ./src
  $(basename "$0") --path ./src --format json
  $(basename "$0") --path ./src --fix
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   SEARCH_PATH="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --fix)    FIX=true; shift ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SEARCH_PATH" ]; then
  echo "Error: --path is required" >&2
  usage
fi

if [ ! -d "$SEARCH_PATH" ]; then
  echo "Error: '$SEARCH_PATH' is not a directory" >&2
  exit 1
fi

detect_language() {
  local file="$1"
  case "$file" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) echo "typescript" ;;
    *.py)  echo "python" ;;
    *.java) echo "java" ;;
    *.kt|*.kts)       echo "kotlin" ;;
    *) echo "" ;;
  esac
}

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# Build the list of source files to examine
glob_args=()
for ext in "${EXTENSIONS[@]}"; do
  glob_args+=(--glob "*.${ext}")
done

# Find all source files (use rg --files for speed; fall back to find)
ALL_FILES=$(rg --files "${glob_args[@]}" "$SEARCH_PATH" 2>/dev/null || true)

if [ -z "$ALL_FILES" ]; then
  if [ "$FORMAT" = "json" ]; then
    echo "[]"
  else
    echo "=== Unused Imports ==="
    echo ""
    echo "No source files found in '$SEARCH_PATH'."
  fi
  exit 0
fi

# ── Per-file analysis ────────────────────────────────────────────────────────

# Accumulators for text / json output
declare -a RESULT_ENTRIES=()   # "file|line|symbol|importStatement"
TOTAL_UNUSED=0
TOTAL_FILES=0

# Parallel arrays for file path -> hit text grouping (bash 3.2 compatible)
_FH_KEYS=()
_FH_VALS=()

parse_ts_output() {
  # Emit: capture row text
  # tree-sitter query output comes in three known formats; handle all.
  local ts_output="$1"
  local re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    if [[ "$line" =~ $re_v026 ]]; then
      printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
    elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
      printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}"
    fi
  done <<< "$ts_output"
}

while IFS= read -r file; do
  [ -z "$file" ] && continue

  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  query_file="$QUERIES_DIR/$lang/symbols.scm"
  [ ! -f "$query_file" ] && continue

  ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  # Collect imports using parallel arrays (bash 3.2 compatible)
  # import_rows: symbol -> space-separated list of 0-based row numbers
  _ir_keys=()
  _ir_vals=()
  # import_row_to_line: row -> the full source line text (for reporting)
  _irl_keys=()
  _irl_vals=()

  # Read each capture triple: capture row text
  while IFS=' ' read -r capture row text; do
    [ -z "$capture" ] && continue
    [[ "$capture" == string.* ]]  && continue
    [[ "$capture" == comment.* ]] && continue

    case "$capture" in
      symbol.import)
        _ir_found=false
        for _ir_i in "${!_ir_keys[@]}"; do
          if [ "${_ir_keys[$_ir_i]}" = "$text" ]; then
            _ir_vals[$_ir_i]="${_ir_vals[$_ir_i]} $row"
            _ir_found=true
            break
          fi
        done
        if [ "$_ir_found" = false ]; then
          _ir_keys+=("$text")
          _ir_vals+=("$row")
        fi
        # Cache the source line (1-based for sed / display)
        local_line=$((row + 1))
        _irl_found=false
        for _irl_i in "${!_irl_keys[@]}"; do
          if [ "${_irl_keys[$_irl_i]}" = "$row" ]; then
            _irl_found=true
            break
          fi
        done
        if [ "$_irl_found" = false ]; then
          _irl_keys+=("$row")
          _irl_vals+=("$(sed -n "${local_line}p" "$file" 2>/dev/null || true)")
        fi
        ;;
      symbol.reference|symbol.type_reference)
        # reference_set: just need to know if symbol was seen — tracked implicitly
        ;;
    esac
  done < <(parse_ts_output "$ts_output")

  # For each imported symbol, check whether it appears as a reference
  # (the import row itself will produce a symbol.reference capture for the
  #  identifier node; we need to see if it appears on a DIFFERENT row)
  file_has_unused=false
  declare -a unused_lines_for_fix=()

  for _ir_i in "${!_ir_keys[@]}"; do
    sym="${_ir_keys[$_ir_i]}"

    # Collect reference rows for this symbol
    ref_rows_raw=$(parse_ts_output "$ts_output" \
      | awk -v sym="$sym" '$1 ~ /^symbol\.(reference|type_reference)$/ && $3 == sym {print $2}' \
      || true)

    # Gather the import rows for this symbol
    IFS=' ' read -ra imp_rows_arr <<< "${_ir_vals[$_ir_i]}"

    # Build a delimited string of import rows for lookup (bash 3.2 compatible)
    _imp_row_lookup=""
    for ir in "${imp_rows_arr[@]}"; do
      _imp_row_lookup="${_imp_row_lookup}|${ir}|"
    done

    # Check whether any reference row is NOT one of the import rows
    referenced=false
    if [ -n "$ref_rows_raw" ]; then
      while IFS= read -r rrow; do
        [ -z "$rrow" ] && continue
        if ! echo "$_imp_row_lookup" | grep -qF "|${rrow}|"; then
          referenced=true
          break
        fi
      done <<< "$ref_rows_raw"
    fi

    if ! $referenced; then
      # For each import row of this symbol, report it
      for ir in "${imp_rows_arr[@]}"; do
        local_line=$((ir + 1))
        # Look up the cached source line
        stmt=""
        for _irl_i in "${!_irl_keys[@]}"; do
          if [ "${_irl_keys[$_irl_i]}" = "$ir" ]; then
            stmt="${_irl_vals[$_irl_i]}"
            break
          fi
        done
        stmt_trimmed="${stmt#"${stmt%%[![:space:]]*}"}"  # ltrim

        RESULT_ENTRIES+=("${file}|${local_line}|${sym}|${stmt_trimmed}")
        TOTAL_UNUSED=$((TOTAL_UNUSED + 1))
        file_has_unused=true
        unused_lines_for_fix+=("$local_line")

        # Accumulate per-file text
        entry="  line ${local_line}: ${stmt_trimmed}  — ${sym} not referenced"
        _fh_found=false
        for _fh_i in "${!_FH_KEYS[@]}"; do
          if [ "${_FH_KEYS[$_fh_i]}" = "$file" ]; then
            _FH_VALS[$_fh_i]="${_FH_VALS[$_fh_i]}"$'\n'"${entry}"
            _fh_found=true
            break
          fi
        done
        if [ "$_fh_found" = false ]; then
          _FH_KEYS+=("$file")
          _FH_VALS+=("$entry")
        fi
      done
    fi
  done

  # --fix: delete unused import lines with sed (in-place)
  if $FIX && [ ${#unused_lines_for_fix[@]} -gt 0 ]; then
    # Build a sed address expression like: -e '3d' -e '5d'
    sed_args=()
    for ln in "${unused_lines_for_fix[@]}"; do
      sed_args+=(-e "${ln}d")
    done
    sed -i '' "${sed_args[@]}" "$file" 2>/dev/null \
      || sed -i "${sed_args[@]}" "$file" 2>/dev/null \
      || true
  fi

  if $file_has_unused; then
    TOTAL_FILES=$((TOTAL_FILES + 1))
  fi
done <<< "$ALL_FILES"

# ── Output ───────────────────────────────────────────────────────────────────

if [ "$FORMAT" = "json" ]; then
  if command -v jq &>/dev/null; then
    # Build JSON array using jq
    json_entries="["
    first=true
    for entry in "${RESULT_ENTRIES[@]}"; do
      IFS='|' read -r f ln sym stmt <<< "$entry"
      obj=$(jq -n \
        --arg file "$f" \
        --argjson line "$ln" \
        --arg symbol "$sym" \
        --arg importStatement "$stmt" \
        '{file: $file, line: $line, symbol: $symbol, importStatement: $importStatement}')
      if $first; then
        json_entries="${json_entries}${obj}"
        first=false
      else
        json_entries="${json_entries},${obj}"
      fi
    done
    json_entries="${json_entries}]"
    echo "$json_entries" | jq .
  else
    # Fallback: manual JSON
    echo "["
    first=true
    for entry in "${RESULT_ENTRIES[@]}"; do
      IFS='|' read -r f ln sym stmt <<< "$entry"
      stmt_escaped="${stmt//\"/\\\"}"
      f_escaped="${f//\"/\\\"}"
      sym_escaped="${sym//\"/\\\"}"
      $first || echo ","
      printf '  {"file":"%s","line":%s,"symbol":"%s","importStatement":"%s"}' \
        "$f_escaped" "$ln" "$sym_escaped" "$stmt_escaped"
      first=false
    done
    echo ""
    echo "]"
  fi
else
  echo "=== Unused Imports ==="
  echo ""
  if [ ${#RESULT_ENTRIES[@]} -eq 0 ]; then
    echo "No unused imports found."
    exit 0
  fi

  # Print grouped by file, in the order files were encountered
  printed_files=()
  for entry in "${RESULT_ENTRIES[@]}"; do
    IFS='|' read -r f _ _ _ <<< "$entry"
    # Check if already printed
    already=false
    for pf in "${printed_files[@]+"${printed_files[@]}"}"; do
      [ "$pf" = "$f" ] && already=true && break
    done
    if ! $already; then
      printed_files+=("$f")
      echo "${f}:"
      # Look up file hits from parallel arrays
      for _fh_i in "${!_FH_KEYS[@]}"; do
        if [ "${_FH_KEYS[$_fh_i]}" = "$f" ]; then
          echo "${_FH_VALS[$_fh_i]}"
          break
        fi
      done
      echo ""
    fi
  done

  # Pluralise
  file_word="file"
  [ "$TOTAL_FILES" -ne 1 ] && file_word="files"
  import_word="import"
  [ "$TOTAL_UNUSED" -ne 1 ] && import_word="imports"

  echo "Total: ${TOTAL_UNUSED} unused ${import_word} in ${TOTAL_FILES} ${file_word}"

  if $FIX; then
    echo ""
    echo "Unused import lines have been removed."
  fi
fi
