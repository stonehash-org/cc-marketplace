#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# diff-impact.sh
# Analyze the impact of git diff changes by identifying changed symbols,
# their references across the project, and affected test files.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

DIFF_MODE="unstaged"
COMMIT_RANGE=""
SEARCH_PATH="."
FORMAT="text"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--commit RANGE | --staged | --unstaged] [--path DIR] [--format text|json]

Analyze impact of changed code by tracing symbol references and affected tests.

Options:
  --commit RANGE   Use git diff for a commit range (e.g., HEAD~1..HEAD)
  --staged         Analyze staged changes (git diff --cached)
  --unstaged       Analyze unstaged changes (default)
  --path DIR       Project directory to search for references (default: .)
  --format FMT     Output format: text or json (default: text)
  -h, --help       Show this help

Examples:
  $SCRIPT_NAME --commit HEAD~1..HEAD
  $SCRIPT_NAME --staged --path ./src --format json
  $SCRIPT_NAME --unstaged
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)   DIFF_MODE="commit"; COMMIT_RANGE="${2:-}"; shift 2 ;;
    --staged)   DIFF_MODE="staged"; shift ;;
    --unstaged) DIFF_MODE="unstaged"; shift ;;
    --path)     SEARCH_PATH="${2:-}"; shift 2 ;;
    --format)   FORMAT="${2:-}"; shift 2 ;;
    -h|--help)  usage ;;
    *)          echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$DIFF_MODE" == "commit" && -z "$COMMIT_RANGE" ]]; then
  echo "Error: --commit requires a range argument (e.g., HEAD~1..HEAD)" >&2
  exit 1
fi

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json'" >&2
  exit 1
fi

# Verify we are inside a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: not inside a git repository" >&2
  exit 1
fi

if ! command -v rg &>/dev/null; then
  echo "Error: ripgrep (rg) is required but not found in PATH." >&2
  exit 1
fi

if ! command -v tree-sitter &>/dev/null; then
  echo "Error: tree-sitter is required but not found in PATH." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Supported extensions
# ---------------------------------------------------------------------------
EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

is_supported_ext() {
  local file="$1"
  for ext in "${EXTENSIONS[@]}"; do
    case "$file" in
      *."$ext") return 0 ;;
    esac
  done
  return 1
}

build_rg_globs() {
  local args=()
  for ext in "${EXTENSIONS[@]}"; do
    args+=("--glob" "*.$ext")
  done
  printf '%s\0' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Step 1: Get changed files from git diff
# ---------------------------------------------------------------------------
get_diff_label() {
  case "$DIFF_MODE" in
    commit)   echo "$COMMIT_RANGE" ;;
    staged)   echo "staged changes" ;;
    unstaged) echo "unstaged changes" ;;
  esac
}

get_changed_files() {
  case "$DIFF_MODE" in
    commit)   git diff --name-only "$COMMIT_RANGE" 2>/dev/null ;;
    staged)   git diff --cached --name-only 2>/dev/null ;;
    unstaged) git diff --name-only 2>/dev/null ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 2: Get changed line numbers for a file
# Returns 1-based line numbers of changed lines (additions/modifications)
# ---------------------------------------------------------------------------
get_changed_lines() {
  local file="$1"
  local diff_output=""

  case "$DIFF_MODE" in
    commit)   diff_output=$(git diff -U0 "$COMMIT_RANGE" -- "$file" 2>/dev/null || true) ;;
    staged)   diff_output=$(git diff --cached -U0 -- "$file" 2>/dev/null || true) ;;
    unstaged) diff_output=$(git diff -U0 -- "$file" 2>/dev/null || true) ;;
  esac

  [ -z "$diff_output" ] && return

  # Parse @@ hunk headers for the new-file side: @@ -old,count +new,count @@
  # Extract the +new,count portion to derive changed line numbers
  echo "$diff_output" | while IFS= read -r line; do
    if [[ "$line" =~ ^@@.*\+([0-9]+)(,([0-9]+))?.*@@ ]]; then
      local start="${BASH_REMATCH[1]}"
      local count="${BASH_REMATCH[3]:-1}"
      # count=0 means pure deletion hunk — no new lines
      if [ "$count" -gt 0 ]; then
        local i
        for (( i=0; i<count; i++ )); do
          echo $(( start + i ))
        done
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Step 3: Identify changed symbols in a file
# A symbol is "changed" if any changed line falls within its definition range.
# Uses block-range.scm for function boundaries and symbols.scm for definitions.
# Output: tab-separated: symbol_name\tdef_line(1-based)
# ---------------------------------------------------------------------------
get_changed_symbols() {
  local file="$1"
  local changed_lines_str="$2"

  [ -z "$changed_lines_str" ] && return
  [ ! -f "$file" ] && return

  local lang
  lang=$(detect_language "$file")
  [ -z "$lang" ] && return

  local symbols_query="$QUERIES_DIR/$lang/symbols.scm"
  local block_query="$QUERIES_DIR/$lang/block-range.scm"
  [ ! -f "$symbols_query" ] && return

  # Get all symbol definitions with their line numbers (0-based from tree-sitter)
  local ts_symbols
  ts_symbols=$(tree-sitter query "$symbols_query" "$file" 2>/dev/null || true)
  [ -z "$ts_symbols" ] && return

  # Collect symbol definitions: name -> line (1-based)
  # Use associative-array-like approach with parallel arrays for bash 3.2
  local def_count=0

  local re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    local capture="" row="" text=""

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

    [ "$capture" != "symbol.definition" ] && continue

    local one_based=$(( row + 1 ))
    eval "def_name_${def_count}=\"\$text\""
    eval "def_line_${def_count}=\"\$one_based\""
    def_count=$(( def_count + 1 ))
  done <<< "$ts_symbols"

  [ "$def_count" -eq 0 ] && return

  # Get function boundaries if block-range.scm exists
  local block_count=0
  if [ -f "$block_query" ]; then
    local ts_blocks
    ts_blocks=$(tree-sitter query "$block_query" "$file" 2>/dev/null || true)

    if [ -n "$ts_blocks" ]; then
      local pending_name="" pending_name_row=""

      local re_v026_block='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
      while IFS= read -r line; do
        local capture="" start_row="" end_row="" text=""

        if [[ "$line" =~ $re_v026_block ]]; then
          capture="${BASH_REMATCH[1]}"
          start_row="${BASH_REMATCH[2]}"
          end_row="$start_row"
          text="${BASH_REMATCH[4]}"
        elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\)\ -\ \(([0-9]+),\ ([0-9]+)\).*\`([^\`]*)\` ]]; then
          capture="${BASH_REMATCH[1]}"
          start_row="${BASH_REMATCH[2]}"
          end_row="${BASH_REMATCH[4]}"
          text="${BASH_REMATCH[6]}"
        elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
          capture="${BASH_REMATCH[1]}"
          start_row="${BASH_REMATCH[2]}"
          end_row="$start_row"
          text="${BASH_REMATCH[4]}"
        elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
          capture="${BASH_REMATCH[1]}"
          text="${BASH_REMATCH[2]}"
          start_row="${BASH_REMATCH[3]}"
          end_row="$start_row"
        else
          continue
        fi

        if [[ "$capture" == "block.name" ]]; then
          pending_name="$text"
          pending_name_row="$start_row"
        elif [[ "$capture" == "block.body" ]]; then
          local bn="${pending_name:-}"
          local bn_row="${pending_name_row:-$start_row}"
          # Store block: name, start_row(1-based), end_row(1-based)
          eval "block_name_${block_count}=\"\$bn\""
          eval "block_start_${block_count}=\"\$(( bn_row + 1 ))\""
          eval "block_end_${block_count}=\"\$(( end_row + 1 ))\""
          block_count=$(( block_count + 1 ))
          pending_name=""
          pending_name_row=""
        fi
      done <<< "$ts_blocks"
    fi
  fi

  # For each symbol definition, check if any changed line falls within its range.
  # For function/method definitions, use block boundaries.
  # For other symbols (variables, etc.), use just the definition line.
  # Track emitted symbols to avoid duplicates (bash 3.2 compatible).
  local _emitted_list=""

  local i
  for (( i=0; i<def_count; i++ )); do
    local sym_name sym_line
    eval "sym_name=\"\$def_name_${i}\""
    eval "sym_line=\"\$def_line_${i}\""

    local key="${sym_name}:${sym_line}"
    if echo "$_emitted_list" | grep -qF "|${key}|"; then
      continue
    fi

    # Determine the range for this symbol
    local range_start="$sym_line"
    local range_end="$sym_line"

    # Check if this symbol matches a block (function/method)
    local b
    for (( b=0; b<block_count; b++ )); do
      local bname bstart bend
      eval "bname=\"\$block_name_${b}\""
      eval "bstart=\"\$block_start_${b}\""
      eval "bend=\"\$block_end_${b}\""

      if [[ "$bname" == "$sym_name" && "$bstart" -le "$sym_line" && "$bend" -ge "$sym_line" ]]; then
        range_start="$bstart"
        range_end="$bend"
        break
      fi
      # Also match if the definition line is the block start line
      if [[ "$bstart" == "$sym_line" || "$(( bstart - 1 ))" == "$sym_line" ]]; then
        range_start="$sym_line"
        range_end="$bend"
        break
      fi
    done

    # Check if any changed line falls within the symbol's range
    local matched=false
    while IFS= read -r cline; do
      [ -z "$cline" ] && continue
      if [[ "$cline" -ge "$range_start" && "$cline" -le "$range_end" ]]; then
        matched=true
        break
      fi
    done <<< "$changed_lines_str"

    if $matched; then
      _emitted_list="${_emitted_list}|${key}|"
      printf '%s\t%s\n' "$sym_name" "$sym_line"
    fi
  done

  # Clean up
  for (( i=0; i<def_count; i++ )); do
    unset "def_name_${i}" "def_line_${i}" 2>/dev/null || true
  done
  for (( i=0; i<block_count; i++ )); do
    unset "block_name_${i}" "block_start_${i}" "block_end_${i}" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Step 4: Find references to a symbol across the project
# Returns tab-separated: file:line entries
# ---------------------------------------------------------------------------
find_symbol_references() {
  local sym="$1"
  local def_file="$2"
  local def_line="$3"

  local rg_args=()
  while IFS= read -r -d '' arg; do
    rg_args+=("$arg")
  done < <(build_rg_globs)

  local candidates
  candidates=$(rg -l --fixed-strings "$sym" "${rg_args[@]}" "$SEARCH_PATH" 2>/dev/null || true)
  [ -z "$candidates" ] && return

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

    local re_v026_ref='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
    while IFS= read -r line; do
      local capture="" row="" text=""

      if [[ "$line" =~ $re_v026_ref ]]; then
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

      # Exclude the definition itself
      [[ "$capture" == "symbol.definition" ]] && continue

      local one_based=$(( row + 1 ))

      # Skip the definition line in the definition file
      if [[ "$file" == "$def_file" && "$one_based" -eq "$def_line" ]]; then
        continue
      fi

      printf '%s:%s\n' "$file" "$one_based"
    done <<< "$ts_output"
  done <<< "$candidates"
}

# ---------------------------------------------------------------------------
# Step 5: Test file detection
# ---------------------------------------------------------------------------
is_test_file() {
  local file="$1"
  case "$file" in
    *.test.*|*.spec.*) return 0 ;;
    */tests/*|*/__tests__/*) return 0 ;;
    */test_*.py|*/*Test.java) return 0 ;;
    test_*.py|*Test.java) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Step 6: Impact score calculation
# ---------------------------------------------------------------------------
calc_impact_score() {
  local total_refs="$1"
  local total_files="$2"

  if [[ "$total_refs" -gt 15 || "$total_files" -gt 8 ]]; then
    echo "HIGH"
  elif [[ "$total_refs" -ge 5 || "$total_files" -ge 3 ]]; then
    echo "MEDIUM"
  else
    echo "LOW"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

DIFF_LABEL=$(get_diff_label)
CHANGED_FILES=$(get_changed_files || true)

if [ -z "$CHANGED_FILES" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"range":"%s","changedSymbols":[],"affectedTests":[],"totalReferences":0,"totalFiles":0,"impactScore":"LOW"}\n' \
      "$DIFF_LABEL"
  else
    echo "=== Impact Analysis ($DIFF_LABEL) ==="
    echo ""
    echo "No changed files found."
  fi
  exit 0
fi

# Filter to supported extensions only
SUPPORTED_FILES=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  if is_supported_ext "$file"; then
    if [ -z "$SUPPORTED_FILES" ]; then
      SUPPORTED_FILES="$file"
    else
      SUPPORTED_FILES="${SUPPORTED_FILES}"$'\n'"$file"
    fi
  fi
done <<< "$CHANGED_FILES"

if [ -z "$SUPPORTED_FILES" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"range":"%s","changedSymbols":[],"affectedTests":[],"totalReferences":0,"totalFiles":0,"impactScore":"LOW"}\n' \
      "$DIFF_LABEL"
  else
    echo "=== Impact Analysis ($DIFF_LABEL) ==="
    echo ""
    echo "No supported source files in diff."
  fi
  exit 0
fi

# Collect changed symbols across all changed files
# Each entry: sym_name\tdef_line\tdef_file
ALL_CHANGED_SYMBOLS=""

while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue

  changed_lines=$(get_changed_lines "$file")
  [ -z "$changed_lines" ] && continue

  symbols=$(get_changed_symbols "$file" "$changed_lines")
  [ -z "$symbols" ] && continue

  while IFS=$'\t' read -r sym_name sym_line; do
    [ -z "$sym_name" ] && continue
    local_entry="${sym_name}\t${sym_line}\t${file}"
    if [ -z "$ALL_CHANGED_SYMBOLS" ]; then
      ALL_CHANGED_SYMBOLS="$local_entry"
    else
      ALL_CHANGED_SYMBOLS="${ALL_CHANGED_SYMBOLS}"$'\n'"$local_entry"
    fi
  done <<< "$symbols"
done <<< "$SUPPORTED_FILES"

if [ -z "$ALL_CHANGED_SYMBOLS" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"range":"%s","changedSymbols":[],"affectedTests":[],"totalReferences":0,"totalFiles":0,"impactScore":"LOW"}\n' \
      "$DIFF_LABEL"
  else
    echo "=== Impact Analysis ($DIFF_LABEL) ==="
    echo ""
    echo "No changed symbols identified."
  fi
  exit 0
fi

# For each changed symbol, find references
# Store results in parallel arrays (bash 3.2 compatible)
sym_result_count=0
_all_ref_files_list=""
_all_ref_files_count=0
# test_file_symbols: parallel arrays mapping test file -> comma-separated symbol names
_tfs_keys=()
_tfs_vals=()

while IFS=$'\t' read -r sym_name sym_line sym_file; do
  [ -z "$sym_name" ] && continue

  refs=$(find_symbol_references "$sym_name" "$sym_file" "$sym_line")

  # Collect unique files and reference locations
  ref_count=0
  _sym_ref_list=""
  _sym_ref_count=0
  ref_locations=""

  if [ -n "$refs" ]; then
    while IFS= read -r ref_entry; do
      [ -z "$ref_entry" ] && continue
      ref_count=$(( ref_count + 1 ))

      # Extract file from file:line
      ref_file="${ref_entry%:*}"
      if ! echo "$_sym_ref_list" | grep -qF "|${ref_file}|"; then
        _sym_ref_list="${_sym_ref_list}|${ref_file}|"
        _sym_ref_count=$(( _sym_ref_count + 1 ))
      fi
      if ! echo "$_all_ref_files_list" | grep -qF "|${ref_file}|"; then
        _all_ref_files_list="${_all_ref_files_list}|${ref_file}|"
        _all_ref_files_count=$(( _all_ref_files_count + 1 ))
      fi

      if [ -z "$ref_locations" ]; then
        ref_locations="$ref_entry"
      else
        ref_locations="${ref_locations}"$'\n'"$ref_entry"
      fi

      # Track test files
      if is_test_file "$ref_file"; then
        _tfs_found=false
        for _tfs_i in "${!_tfs_keys[@]}"; do
          if [ "${_tfs_keys[$_tfs_i]}" = "$ref_file" ]; then
            # Check if symbol already listed for this test file
            case ",${_tfs_vals[$_tfs_i]}," in
              *,"$sym_name",*) ;;
              *) _tfs_vals[$_tfs_i]="${_tfs_vals[$_tfs_i]},${sym_name}" ;;
            esac
            _tfs_found=true
            break
          fi
        done
        if [ "$_tfs_found" = false ]; then
          _tfs_keys+=("$ref_file")
          _tfs_vals+=("$sym_name")
        fi
      fi
    done <<< "$refs"
  fi

  file_count="$_sym_ref_count"

  eval "sr_name_${sym_result_count}=\"\$sym_name\""
  eval "sr_file_${sym_result_count}=\"\$sym_file\""
  eval "sr_line_${sym_result_count}=\"\$sym_line\""
  eval "sr_refcount_${sym_result_count}=\"\$ref_count\""
  eval "sr_filecount_${sym_result_count}=\"\$file_count\""
  eval "sr_refs_${sym_result_count}=\"\$ref_locations\""
  sym_result_count=$(( sym_result_count + 1 ))
done <<< "$ALL_CHANGED_SYMBOLS"

# Calculate totals
TOTAL_REFS=0
for (( i=0; i<sym_result_count; i++ )); do
  rc=""
  eval "rc=\"\$sr_refcount_${i}\""
  TOTAL_REFS=$(( TOTAL_REFS + rc ))
done
TOTAL_FILES="$_all_ref_files_count"
IMPACT_SCORE=$(calc_impact_score "$TOTAL_REFS" "$TOTAL_FILES")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  j_range=$(printf '%s' "$DIFF_LABEL" | sed 's/\\/\\\\/g; s/"/\\"/g')

  printf '{\n'
  printf '  "range": "%s",\n' "$j_range"
  printf '  "changedSymbols": ['

  first=true
  for (( i=0; i<sym_result_count; i++ )); do
    local sn sf sl src sfc srefs
    eval "sn=\"\$sr_name_${i}\""
    eval "sf=\"\$sr_file_${i}\""
    eval "sl=\"\$sr_line_${i}\""
    eval "src=\"\$sr_refcount_${i}\""
    eval "sfc=\"\$sr_filecount_${i}\""
    eval "srefs=\"\$sr_refs_${i}\""

    $first || printf ','
    first=false

    local j_name j_file
    j_name=$(printf '%s' "$sn" | sed 's/\\/\\\\/g; s/"/\\"/g')
    j_file=$(printf '%s' "$sf" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Build references array
    local refs_json="[]"
    if [ -n "$srefs" ]; then
      refs_json=$(printf '%s\n' "$srefs" | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
    fi

    printf '\n    {"name": "%s", "file": "%s", "line": %s, "referenceCount": %s, "fileCount": %s, "references": %s}' \
      "$j_name" "$j_file" "$sl" "$src" "$sfc" "$refs_json"
  done

  if [ "$sym_result_count" -gt 0 ]; then
    printf '\n  '
  fi
  printf '],\n'

  # Affected tests
  printf '  "affectedTests": ['
  first=true
  for _tfs_i in "${!_tfs_keys[@]}"; do
    $first || printf ','
    first=false

    j_tf=$(printf '%s' "${_tfs_keys[$_tfs_i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Convert comma-separated symbols to JSON array
    sym_list="${_tfs_vals[$_tfs_i]}"
    syms_json=$(printf '%s\n' "$sym_list" | tr ',' '\n' | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")

    printf '\n    {"file": "%s", "symbols": %s}' "$j_tf" "$syms_json"
  done
  if [ "${#_tfs_keys[@]}" -gt 0 ]; then
    printf '\n  '
  fi
  printf '],\n'

  printf '  "totalReferences": %s,\n' "$TOTAL_REFS"
  printf '  "totalFiles": %s,\n' "$TOTAL_FILES"
  printf '  "impactScore": "%s"\n' "$IMPACT_SCORE"
  printf '}\n'
else
  echo "=== Impact Analysis ($DIFF_LABEL) ==="
  echo ""

  if [ "$sym_result_count" -gt 0 ]; then
    echo "Changed symbols:"
    for (( i=0; i<sym_result_count; i++ )); do
      local sn sf sl src sfc
      eval "sn=\"\$sr_name_${i}\""
      eval "sf=\"\$sr_file_${i}\""
      eval "sl=\"\$sr_line_${i}\""
      eval "src=\"\$sr_refcount_${i}\""
      eval "sfc=\"\$sr_filecount_${i}\""

      printf '  %s (%s:%s)  — %s reference%s in %s file%s\n' \
        "$sn" "$sf" "$sl" \
        "$src" "$([ "$src" -ne 1 ] && echo 's' || true)" \
        "$sfc" "$([ "$sfc" -ne 1 ] && echo 's' || true)"
    done
    echo ""
  fi

  if [ "${#_tfs_keys[@]}" -gt 0 ]; then
    echo "Affected test files:"
    for _tfs_i in "${!_tfs_keys[@]}"; do
      sym_list="${_tfs_vals[$_tfs_i]}"
      printf '  %s (references: %s)\n' "${_tfs_keys[$_tfs_i]}" "$sym_list"
    done
    echo ""
  fi

  echo "Impact score: $IMPACT_SCORE ($TOTAL_REFS reference$([ "$TOTAL_REFS" -ne 1 ] && echo 's' || true) across $TOTAL_FILES file$([ "$TOTAL_FILES" -ne 1 ] && echo 's' || true))"
fi

# Clean up
for (( i=0; i<sym_result_count; i++ )); do
  unset "sr_name_${i}" "sr_file_${i}" "sr_line_${i}" "sr_refcount_${i}" "sr_filecount_${i}" "sr_refs_${i}" 2>/dev/null || true
done
