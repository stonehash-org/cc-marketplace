#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# complexity-report.sh
# Analyze cyclomatic-style complexity of functions using tree-sitter queries.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

SEARCH_PATH=""
FORMAT="text"
THRESHOLD=10
SORT_BY="complexity"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --path DIR [--format text|json] [--threshold N] [--sort complexity|name|file]

Analyze function complexity using control-flow node counts and nesting depth.

Options:
  --path DIR          Directory to scan (required)
  --format FMT        Output format: text or json (default: text)
  --threshold N       Minimum score to report (default: 10)
  --sort FIELD        Sort by: complexity, name, or file (default: complexity)
  -h, --help          Show this help

Score = branches + (nesting_depth * 2)

Examples:
  $SCRIPT_NAME --path ./src
  $SCRIPT_NAME --path ./src --format json --threshold 15
  $SCRIPT_NAME --path ./src --sort name
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)      SEARCH_PATH="${2:-}"; shift 2 ;;
    --format)    FORMAT="${2:-}"; shift 2 ;;
    --threshold) THRESHOLD="${2:-10}"; shift 2 ;;
    --sort)      SORT_BY="${2:-complexity}"; shift 2 ;;
    -h|--help)   usage ;;
    *)           echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SEARCH_PATH" ]]; then
  echo "Error: --path is required." >&2
  exit 1
fi

if [[ ! -d "$SEARCH_PATH" ]]; then
  echo "Error: '$SEARCH_PATH' is not a directory or does not exist." >&2
  exit 1
fi

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json'" >&2
  exit 1
fi

case "$SORT_BY" in
  complexity|name|file) ;;
  *) echo "Error: --sort must be one of: complexity, name, file" >&2; exit 1 ;;
esac

if ! command -v rg &>/dev/null; then
  echo "Error: ripgrep (rg) is required but not found in PATH." >&2
  exit 1
fi

if ! command -v tree-sitter &>/dev/null; then
  echo "Error: tree-sitter is required but not found in PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Supported extensions and rg glob builder
# ---------------------------------------------------------------------------
EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

build_rg_globs() {
  local args=()
  for ext in "${EXTENSIONS[@]}"; do
    args+=("--glob" "*.$ext")
  done
  printf '%s\0' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Parse tree-sitter query output into tab-separated records.
# Each line: capture_name\tstart_row\tend_row\ttext
#
# tree-sitter query outputs multi-line blocks per match. We parse the two
# known formats from the run_query helper's regex patterns, but we also
# need end_row. The standard tree-sitter CLI output looks like:
#   pattern: N
#     capture: NAME, start: (ROW, COL), end: (ROW, COL), text: `...`
# We extract start_row and end_row from each capture line.
# ---------------------------------------------------------------------------
parse_ts_output() {
  local ts_output="$1"
  [ -z "$ts_output" ] && return

  local re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    local capture="" start_row="" end_row="" text=""

    # Format: capture: N - capture_name, start: (row, col), end: (row, col), text: `...`
    if [[ "$line" =~ $re_v026 ]]; then
      capture="${BASH_REMATCH[1]}"
      start_row="${BASH_REMATCH[2]}"
      end_row="$start_row"
      text="${BASH_REMATCH[4]}"
    # Format: @capture (start_row, start_col) - (end_row, end_col) `text`
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\)\ -\ \(([0-9]+),\ ([0-9]+)\).*\`([^\`]*)\` ]]; then
      capture="${BASH_REMATCH[1]}"
      start_row="${BASH_REMATCH[2]}"
      end_row="${BASH_REMATCH[4]}"
      text="${BASH_REMATCH[6]}"
    # Format: @capture (start_row, start_col) `text`  (no end row — use start)
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      capture="${BASH_REMATCH[1]}"
      start_row="${BASH_REMATCH[2]}"
      end_row="$start_row"
      text="${BASH_REMATCH[4]}"
    # Format: capture: NAME, text: "...", row: N, col: N
    elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
      capture="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
      start_row="${BASH_REMATCH[3]}"
      end_row="$start_row"
    else
      continue
    fi

    printf '%s\t%s\t%s\t%s\n' "$capture" "$start_row" "$end_row" "$text"
  done <<< "$ts_output"
}

# ---------------------------------------------------------------------------
# Analyze a single source file: find functions, count control-flow nodes,
# calculate complexity scores.
#
# Output: tab-separated lines per function:
#   file\tline\tname\tscore\tbranches\tdepth\tlines
# ---------------------------------------------------------------------------
analyze_file() {
  local file="$1"
  local lang
  lang=$(detect_language "$file")
  [ -z "$lang" ] && return

  local block_query="$QUERIES_DIR/$lang/block-range.scm"
  local cf_query="$QUERIES_DIR/$lang/control-flow.scm"
  [ ! -f "$block_query" ] && return
  [ ! -f "$cf_query" ] && return

  # --- Step 1: Get function boundaries ---
  local block_raw
  block_raw=$(tree-sitter query "$block_query" "$file" 2>/dev/null || true)
  [ -z "$block_raw" ] && return

  local block_parsed
  block_parsed=$(parse_ts_output "$block_raw")
  [ -z "$block_parsed" ] && return

  # Build function list: arrays of name, body_start, body_end
  # We pair @block.name with the immediately following @block.body
  local func_count=0
  local pending_name=""
  local pending_name_row=""

  # Parallel arrays (bash 3 compatible)
  # func_name_N, func_start_N, func_end_N, func_name_row_N
  while IFS=$'\t' read -r cap srow erow txt; do
    [ -z "$cap" ] && continue

    if [[ "$cap" == "block.name" ]]; then
      pending_name="$txt"
      pending_name_row="$srow"
    elif [[ "$cap" == "block.body" ]]; then
      local fn_name="${pending_name:-<anonymous>}"
      local fn_name_row="${pending_name_row:-$srow}"
      eval "func_name_${func_count}=\"\$fn_name\""
      eval "func_start_${func_count}=\"\$srow\""
      eval "func_end_${func_count}=\"\$erow\""
      eval "func_name_row_${func_count}=\"\$fn_name_row\""
      func_count=$(( func_count + 1 ))
      pending_name=""
      pending_name_row=""
    fi
  done <<< "$block_parsed"

  [ "$func_count" -eq 0 ] && return

  # --- Step 2: Get control-flow nodes ---
  local cf_raw
  cf_raw=$(tree-sitter query "$cf_query" "$file" 2>/dev/null || true)

  local cf_parsed=""
  if [ -n "$cf_raw" ]; then
    cf_parsed=$(parse_ts_output "$cf_raw")
  fi

  # --- Step 3: For each function, count branches and calculate nesting ---
  local i
  for (( i=0; i<func_count; i++ )); do
    local fn_name fn_start fn_end fn_name_row
    eval "fn_name=\"\$func_name_${i}\""
    eval "fn_start=\"\$func_start_${i}\""
    eval "fn_end=\"\$func_end_${i}\""
    eval "fn_name_row=\"\$func_name_row_${i}\""

    local branches=0
    local line_count=$(( fn_end - fn_start + 1 ))

    # Collect control-flow nodes within this function's range
    # Store their start/end rows for nesting calculation
    local cf_node_count=0

    if [ -n "$cf_parsed" ]; then
      while IFS=$'\t' read -r cf_cap cf_srow cf_erow cf_txt; do
        [ -z "$cf_cap" ] && continue
        # Check if this control-flow node is within the function boundary
        if [[ "$cf_srow" -ge "$fn_start" && "$cf_srow" -le "$fn_end" ]]; then
          eval "cf_srow_${cf_node_count}=\"\$cf_srow\""
          eval "cf_erow_${cf_node_count}=\"\$cf_erow\""
          cf_node_count=$(( cf_node_count + 1 ))
          branches=$(( branches + 1 ))
        fi
      done <<< "$cf_parsed"
    fi

    # Calculate nesting depth: for each cf node, count how many other
    # cf nodes in the same function enclose it (their range contains
    # this node's start row). Max across all nodes = nesting depth.
    local max_depth=0
    local j k
    for (( j=0; j<cf_node_count; j++ )); do
      local node_srow node_erow
      eval "node_srow=\"\$cf_srow_${j}\""
      eval "node_erow=\"\$cf_erow_${j}\""

      local depth=0
      for (( k=0; k<cf_node_count; k++ )); do
        [ "$k" -eq "$j" ] && continue
        local other_srow other_erow
        eval "other_srow=\"\$cf_srow_${k}\""
        eval "other_erow=\"\$cf_erow_${k}\""

        # Does the other node enclose this one?
        if [[ "$other_srow" -le "$node_srow" && "$other_erow" -ge "$node_erow" ]]; then
          depth=$(( depth + 1 ))
        fi
      done

      if [[ "$depth" -gt "$max_depth" ]]; then
        max_depth="$depth"
      fi
    done

    # Clean up cf node vars
    for (( j=0; j<cf_node_count; j++ )); do
      unset "cf_srow_${j}" "cf_erow_${j}" 2>/dev/null || true
    done

    # Score = branches + (nesting_depth * 2)
    local score=$(( branches + (max_depth * 2) ))

    # line number is 1-based
    local fn_line=$(( fn_name_row + 1 ))

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$file" "$fn_line" "$fn_name" "$score" "$branches" "$max_depth" "$line_count"
  done

  # Clean up function vars
  for (( i=0; i<func_count; i++ )); do
    unset "func_name_${i}" "func_start_${i}" "func_end_${i}" "func_name_row_${i}" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Discover all source files
rg_args=()
while IFS= read -r -d '' arg; do
  rg_args+=("$arg")
done < <(build_rg_globs)

ALL_FILES=$(rg --files "${rg_args[@]}" "$SEARCH_PATH" 2>/dev/null | sort || true)

if [ -z "$ALL_FILES" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"threshold":%s,"totalFunctions":0,"flaggedFunctions":[]}\n' "$THRESHOLD"
  else
    echo "=== Complexity Report (threshold: $THRESHOLD) ==="
    echo ""
    echo "No source files found in '$SEARCH_PATH'."
  fi
  exit 0
fi

# Analyze all files and collect results
ALL_RESULTS=""
TOTAL_FUNCTIONS=0

while IFS= read -r file; do
  [ -z "$file" ] && continue

  file_results=$(analyze_file "$file")
  [ -z "$file_results" ] && continue

  while IFS= read -r result_line; do
    [ -z "$result_line" ] && continue
    TOTAL_FUNCTIONS=$(( TOTAL_FUNCTIONS + 1 ))
    if [ -z "$ALL_RESULTS" ]; then
      ALL_RESULTS="$result_line"
    else
      ALL_RESULTS="${ALL_RESULTS}"$'\n'"$result_line"
    fi
  done <<< "$file_results"
done <<< "$ALL_FILES"

# Filter by threshold
FLAGGED=""
FLAGGED_COUNT=0

if [ -n "$ALL_RESULTS" ]; then
  while IFS=$'\t' read -r f_file f_line f_name f_score f_branches f_depth f_lines; do
    [ -z "$f_file" ] && continue
    if [ "$f_score" -ge "$THRESHOLD" ]; then
      FLAGGED_COUNT=$(( FLAGGED_COUNT + 1 ))
      local_entry="${f_file}\t${f_line}\t${f_name}\t${f_score}\t${f_branches}\t${f_depth}\t${f_lines}"
      if [ -z "$FLAGGED" ]; then
        FLAGGED="$local_entry"
      else
        FLAGGED="${FLAGGED}"$'\n'"$local_entry"
      fi
    fi
  done <<< "$ALL_RESULTS"
fi

# Sort flagged results
if [ -n "$FLAGGED" ]; then
  case "$SORT_BY" in
    complexity)
      # Sort by score descending (field 4)
      FLAGGED=$(printf '%b\n' "$FLAGGED" | sort -t$'\t' -k4 -rn)
      ;;
    name)
      # Sort by function name ascending (field 3)
      FLAGGED=$(printf '%b\n' "$FLAGGED" | sort -t$'\t' -k3)
      ;;
    file)
      # Sort by file path ascending, then line number (fields 1,2)
      FLAGGED=$(printf '%b\n' "$FLAGGED" | sort -t$'\t' -k1,1 -k2,2n)
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  printf '{\n'
  printf '  "threshold": %s,\n' "$THRESHOLD"
  printf '  "totalFunctions": %s,\n' "$TOTAL_FUNCTIONS"
  printf '  "flaggedFunctions": ['

  if [ -n "$FLAGGED" ]; then
    first=true
    while IFS=$'\t' read -r f_file f_line f_name f_score f_branches f_depth f_lines; do
      [ -z "$f_file" ] && continue
      $first || printf ','
      first=false
      # Escape file and name for JSON
      local j_file j_name
      j_file=$(printf '%s' "$f_file" | sed 's/\\/\\\\/g; s/"/\\"/g')
      j_name=$(printf '%s' "$f_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf '\n    {"file": "%s", "line": %s, "name": "%s", "score": %s, "branches": %s, "depth": %s, "lines": %s}' \
        "$j_file" "$f_line" "$j_name" "$f_score" "$f_branches" "$f_depth" "$f_lines"
    done <<< "$FLAGGED"
    printf '\n  '
  fi

  printf ']\n}\n'
else
  echo "=== Complexity Report (threshold: $THRESHOLD) ==="
  echo ""

  if [ "$FLAGGED_COUNT" -eq 0 ]; then
    echo "No functions above threshold."
    echo ""
    echo "Summary: 0 functions above threshold (out of $TOTAL_FUNCTIONS total)"
    exit 0
  fi

  # Categorize: HIGH (score >= 20), MEDIUM (score >= threshold)
  HIGH=""
  MEDIUM=""

  if [ -n "$FLAGGED" ]; then
    while IFS=$'\t' read -r f_file f_line f_name f_score f_branches f_depth f_lines; do
      [ -z "$f_file" ] && continue
      # Build display line with relative path
      local rel_file="${f_file#$SEARCH_PATH/}"
      local display
      display=$(printf '  %s:%s\t%s()\tscore: %s\tbranches: %s\tdepth: %s\tlines: %s' \
        "$rel_file" "$f_line" "$f_name" "$f_score" "$f_branches" "$f_depth" "$f_lines")

      if [ "$f_score" -ge 20 ]; then
        if [ -z "$HIGH" ]; then
          HIGH="$display"
        else
          HIGH="${HIGH}"$'\n'"$display"
        fi
      else
        if [ -z "$MEDIUM" ]; then
          MEDIUM="$display"
        else
          MEDIUM="${MEDIUM}"$'\n'"$display"
        fi
      fi
    done <<< "$FLAGGED"
  fi

  if [ -n "$HIGH" ]; then
    echo "HIGH (score >= 20):"
    printf '%s\n' "$HIGH" | column -t -s$'\t'
    echo ""
  fi

  if [ -n "$MEDIUM" ]; then
    echo "MEDIUM (score >= $THRESHOLD):"
    printf '%s\n' "$MEDIUM" | column -t -s$'\t'
    echo ""
  fi

  echo "Summary: $FLAGGED_COUNT function$([ "$FLAGGED_COUNT" -ne 1 ] && echo 's' || true) above threshold (out of $TOTAL_FUNCTIONS total)"
fi
