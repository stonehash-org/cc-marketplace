#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

SEARCH_PATH="."
FORMAT="text"
IGNORE_EXPORTS=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --path DIR [--format text|json] [--ignore-exports]

Detect dead code — symbols that are defined but never referenced elsewhere.

Options:
  --path DIR          Directory to scan (required)
  --format FMT        Output format: text or json (default: text)
  --ignore-exports    Skip symbols that appear in export statements
  -h, --help          Show this help

Examples:
  $(basename "$0") --path ./src
  $(basename "$0") --path . --format json
  $(basename "$0") --path ./src --ignore-exports
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)           SEARCH_PATH="$2"; shift 2 ;;
    --format)         FORMAT="$2"; shift 2 ;;
    --ignore-exports) IGNORE_EXPORTS=true; shift ;;
    -h|--help)        usage ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$SEARCH_PATH" ]; then
  echo "Error: --path must be a directory: $SEARCH_PATH" >&2
  exit 1
fi

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json'" >&2
  exit 1
fi

detect_language() {
  local file="$1"
  case "$file" in
    *.ts|*.tsx)              echo "typescript" ;;
    *.js|*.jsx|*.mjs|*.cjs) echo "typescript" ;;
    *.py)                    echo "python" ;;
    *.java)                  echo "java" ;;
    *.kt|*.kts)       echo "kotlin" ;;
    *)                       echo "" ;;
  esac
}

symbol_type_from_capture() {
  # Map tree-sitter node context to a human-readable type label.
  # We derive type from the query capture tag and a node-kind hint passed as $2.
  local capture="$1"
  local node_kind="${2:-}"
  case "$node_kind" in
    function_declaration|function_definition|method_declaration|method_definition|arrow_function)
      echo "function" ;;
    class_declaration|class_definition)
      echo "class" ;;
    interface_declaration)
      echo "interface" ;;
    variable_declarator|assignment)
      echo "variable" ;;
    *)
      echo "symbol" ;;
  esac
}

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# Build the glob arguments for rg
build_rg_globs() {
  local args=()
  for ext in "${EXTENSIONS[@]}"; do
    args+=("--glob" "*.$ext")
  done
  printf '%s\0' "${args[@]}"
}

# Count real code occurrences of a symbol name in the project using tree-sitter,
# excluding the definition site itself (identified by file:line).
# Returns the count of symbol.reference / symbol.import / symbol.export captures
# that match the name, across all candidate files.
count_references() {
  local sym="$1"
  local def_file="$2"
  local def_line="$3"   # 1-based line number of the definition

  local count=0

  # Quick pre-filter with ripgrep to avoid running tree-sitter on every file
  local rg_args=()
  while IFS= read -r -d '' arg; do
    rg_args+=("$arg")
  done < <(build_rg_globs)

  local candidates
  candidates=$(rg -l --fixed-strings "$sym" "${rg_args[@]}" "$SEARCH_PATH" 2>/dev/null || true)
  [ -z "$candidates" ] && echo 0 && return

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local lang
    lang=$(detect_language "$file")
    [ -z "$lang" ] && continue

    local query_file="$QUERIES_DIR/$lang/symbols.scm"
    [ ! -f "$query_file" ] && continue

    local ts_output
    ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
    [ -z "$ts_output" ] && continue

    local re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
    while IFS= read -r line; do
      local capture row text

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

      [ "$text" != "$sym" ] && continue

      # Exclude strings and comments
      [[ "$capture" == string.* ]] && continue
      [[ "$capture" == comment.* ]] && continue

      # Exclude the definition capture itself
      [[ "$capture" == "symbol.definition" ]] && continue

      # Also exclude the definition line in the definition file to avoid
      # counting export-on-same-line or parameter captures at the def site
      if [[ "$file" == "$def_file" ]]; then
        local one_based=$(( row + 1 ))
        [ "$one_based" -eq "$def_line" ] && continue
      fi

      count=$(( count + 1 ))
    done <<< "$ts_output"
  done <<< "$candidates"

  echo "$count"
}

# Collect all definitions across all source files
# Each entry: file|symbol|type|line
collect_definitions() {
  local rg_args=()
  while IFS= read -r -d '' arg; do
    rg_args+=("$arg")
  done < <(build_rg_globs)

  # Find all source files
  local all_files
  all_files=$(rg --files "${rg_args[@]}" "$SEARCH_PATH" 2>/dev/null || true)
  [ -z "$all_files" ] && return

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local lang
    lang=$(detect_language "$file")
    [ -z "$lang" ] && continue

    local query_file="$QUERIES_DIR/$lang/symbols.scm"
    [ ! -f "$query_file" ] && continue

    local ts_output
    ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
    [ -z "$ts_output" ] && continue

    # Track which (symbol, line) pairs we've already emitted for this file
    # to avoid duplicates when multiple captures fire on the same node.
    # Uses a delimited string for bash 3.2 compatibility (no associative arrays).
    local _seen_defs_list=""

    # Also collect export names for --ignore-exports
    local _export_names_list=""
    local re_v026_exp='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
    if $IGNORE_EXPORTS; then
      while IFS= read -r line; do
        local capture row text
        if [[ "$line" =~ $re_v026_exp ]]; then
          capture="${BASH_REMATCH[1]}"
          row="${BASH_REMATCH[2]}"
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
        if [[ "$capture" == "symbol.export" ]]; then
          _export_names_list="${_export_names_list}|${text}|"
        fi
      done <<< "$ts_output"
    fi

    local re_v026_def='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
    while IFS= read -r line; do
      local capture row col text node_kind

      if [[ "$line" =~ $re_v026_def ]]; then
        capture="${BASH_REMATCH[1]}"
        row="${BASH_REMATCH[2]}"
        col="${BASH_REMATCH[3]}"
        text="${BASH_REMATCH[4]}"
      elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
        capture="${BASH_REMATCH[1]}"
        row="${BASH_REMATCH[2]}"
        col="${BASH_REMATCH[3]}"
        text="${BASH_REMATCH[4]}"
      elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
        capture="${BASH_REMATCH[1]}"
        text="${BASH_REMATCH[2]}"
        row="${BASH_REMATCH[3]}"
        col="${BASH_REMATCH[4]}"
      else
        continue
      fi

      [ "$capture" != "symbol.definition" ] && continue

      local one_based=$(( row + 1 ))
      local key="${text}:${one_based}"
      if echo "$_seen_defs_list" | grep -qF "|${key}|"; then
        continue
      fi
      _seen_defs_list="${_seen_defs_list}|${key}|"

      # Skip exports if requested
      if $IGNORE_EXPORTS && echo "$_export_names_list" | grep -qF "|${text}|"; then
        continue
      fi

      # Derive type label by peeking at the preceding non-blank line of ts_output
      # (tree-sitter prints the node kind before the captures block).
      # Since we parse flat output we use a heuristic: check surrounding context.
      # We pass an empty node_kind; symbol_type_from_capture will default to "symbol".
      local sym_type
      sym_type=$(symbol_type_from_capture "$capture" "")

      # Better heuristic: grep the source file line for keywords
      local src_line
      src_line=$(sed -n "${one_based}p" "$file" 2>/dev/null || true)
      if [[ "$src_line" =~ (^|[[:space:]])(async[[:space:]]+)?function[[:space:]] ]]; then
        sym_type="function"
      elif [[ "$src_line" =~ (^|[[:space:]])class[[:space:]] ]]; then
        sym_type="class"
      elif [[ "$src_line" =~ (^|[[:space:]])interface[[:space:]] ]]; then
        sym_type="interface"
      elif [[ "$src_line" =~ (^|[[:space:]])(const|let|var)[[:space:]] ]]; then
        sym_type="variable"
      elif [[ "$src_line" =~ (^|[[:space:]])def[[:space:]] ]]; then
        sym_type="function"
      elif [[ "$src_line" =~ "=>" ]]; then
        sym_type="function"
      fi

      printf '%s\t%s\t%s\t%s\n' "$file" "$text" "$sym_type" "$one_based"
    done <<< "$ts_output"

    # No need to unset — local string variables go out of scope
  done <<< "$all_files"
}

# ---- Main ----------------------------------------------------------------

# Collect definitions
DEFS=$(collect_definitions)

if [ -z "$DEFS" ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '[]'
  else
    echo "=== Dead Code Report for $SEARCH_PATH ==="
    echo ""
    echo "No symbol definitions found."
  fi
  exit 0
fi

# For each definition, count external references
# Accumulate results using parallel arrays (bash 3.2 compatible)
declare -a DEAD_FILES_ORDER=()
declare -a FILE_RESULTS_KEYS=()
declare -a FILE_RESULTS_VALS=()
TOTAL_DEAD=0
TOTAL_FILES=0

while IFS=$'\t' read -r def_file sym_name sym_type sym_line; do
  [ -z "$def_file" ] && continue

  ref_count=$(count_references "$sym_name" "$def_file" "$sym_line")

  if [ "$ref_count" -eq 0 ]; then
    TOTAL_DEAD=$(( TOTAL_DEAD + 1 ))
    local_entry="${sym_name}|${sym_type}|${sym_line}|${ref_count}"
    _fr_found=false
    for _fr_i in "${!FILE_RESULTS_KEYS[@]}"; do
      if [ "${FILE_RESULTS_KEYS[$_fr_i]}" = "$def_file" ]; then
        FILE_RESULTS_VALS[$_fr_i]="${FILE_RESULTS_VALS[$_fr_i]}"$'\n'"$local_entry"
        _fr_found=true
        break
      fi
    done
    if [ "$_fr_found" = false ]; then
      FILE_RESULTS_KEYS+=("$def_file")
      FILE_RESULTS_VALS+=("$local_entry")
      DEAD_FILES_ORDER+=("$def_file")
    fi
  fi
done <<< "$DEFS"

TOTAL_FILES=${#DEAD_FILES_ORDER[@]}

# ---- Output --------------------------------------------------------------

if [ "$FORMAT" = "json" ]; then
  first=true
  printf '['
  for file in "${DEAD_FILES_ORDER[@]}"; do
    # Look up the results for this file
    _fr_val=""
    for _fr_i in "${!FILE_RESULTS_KEYS[@]}"; do
      if [ "${FILE_RESULTS_KEYS[$_fr_i]}" = "$file" ]; then
        _fr_val="${FILE_RESULTS_VALS[$_fr_i]}"
        break
      fi
    done
    while IFS='|' read -r sym type line refs; do
      [ -z "$sym" ] && continue
      $first || printf ','
      first=false
      printf '\n  {"file":%s,"symbol":%s,"type":%s,"line":%s,"references":0}' \
        "$(printf '%s' "$file" | jq -R .)" \
        "$(printf '%s' "$sym"  | jq -R .)" \
        "$(printf '%s' "$type" | jq -R .)" \
        "$line"
    done <<< "$_fr_val"
  done
  printf '\n]\n'
else
  echo "=== Dead Code Report for $SEARCH_PATH ==="
  echo ""

  if [ "$TOTAL_DEAD" -eq 0 ]; then
    echo "No unused symbols found."
    exit 0
  fi

  for file in "${DEAD_FILES_ORDER[@]}"; do
    # Print relative path when possible for readability
    rel_file="${file#$SEARCH_PATH/}"
    echo "${rel_file}:"
    # Look up the results for this file
    _fr_val=""
    for _fr_i in "${!FILE_RESULTS_KEYS[@]}"; do
      if [ "${FILE_RESULTS_KEYS[$_fr_i]}" = "$file" ]; then
        _fr_val="${FILE_RESULTS_VALS[$_fr_i]}"
        break
      fi
    done
    while IFS='|' read -r sym type line refs; do
      [ -z "$sym" ] && continue
      printf "  [%s] %s (line %s) — 0 references\n" "$type" "$sym" "$line"
    done <<< "$_fr_val"
    echo ""
  done

  if [ "$TOTAL_FILES" -eq 1 ]; then
    file_word="file"
  else
    file_word="files"
  fi
  echo "Total: $TOTAL_DEAD unused symbol$([ "$TOTAL_DEAD" -ne 1 ] && echo 's' || true) across $TOTAL_FILES $file_word"
fi
