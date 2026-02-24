#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

SEARCH_PATH=""
FORMAT="text"
FILTER_TYPE="all"

usage() {
  cat <<EOF
Usage: $(basename "$0") --path FILE_OR_DIR [--format text|json] [--type definition|function|class|variable|all]

List all symbols in a file or directory using tree-sitter AST analysis.
Groups results by file, then by type (functions, classes, variables).

Options:
  --path FILE_OR_DIR  File or directory to analyze (required)
  --format FMT        Output format: text or json (default: text)
  --type TYPE         Filter by symbol type: function, class, variable, definition, or all (default: all)
  -h, --help          Show this help

Examples:
  $(basename "$0") --path ./src/utils.ts
  $(basename "$0") --path ./src --format json
  $(basename "$0") --path ./src --type function
  $(basename "$0") --path ./src --type class --format json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   SEARCH_PATH="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --type)   FILTER_TYPE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SEARCH_PATH" ]; then
  echo "Error: --path is required" >&2
  usage
fi

if [ ! -e "$SEARCH_PATH" ]; then
  echo "Error: path does not exist: $SEARCH_PATH" >&2
  exit 1
fi

case "$FORMAT" in
  text|json) ;;
  *) echo "Error: --format must be text or json" >&2; exit 1 ;;
esac

case "$FILTER_TYPE" in
  all|definition|function|class|variable) ;;
  *) echo "Error: --type must be one of: all, definition, function, class, variable" >&2; exit 1 ;;
esac

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

# Classify a symbol.definition capture into function/class/variable
# based on keywords found on the same source line.
classify_symbol() {
  local file="$1"
  local line_num="$2"    # 1-based
  local lang="$3"

  local src_line
  src_line=$(sed -n "${line_num}p" "$file" 2>/dev/null || true)

  # Precompile patterns into variables so bash [[ =~ ]] handles them correctly
  local pat_class pat_fn pat_fn2 pat_def pat_method pat_java_method pat_java_class

  case "$lang" in
    typescript)
      pat_class='(^|[[:space:]])class[[:space:]]'
      pat_fn='(^|[[:space:]])(function|async function)[[:space:]]'
      pat_method='(^|[[:space:]])(constructor)[[:space:]]*\('
      pat_arrow='\)[[:space:]]*(:[^{]*)?[[:space:]]*=>'
      if [[ "$src_line" =~ $pat_class ]]; then
        echo "class"
      elif [[ "$src_line" =~ $pat_fn ]] || [[ "$src_line" =~ $pat_method ]]; then
        echo "function"
      elif [[ "$src_line" =~ $pat_arrow ]]; then
        echo "function"
      else
        echo "variable"
      fi
      ;;
    python)
      pat_fn='^[[:space:]]*(async[[:space:]]+)?def[[:space:]]'
      pat_class='^[[:space:]]*class[[:space:]]'
      if [[ "$src_line" =~ $pat_fn ]]; then
        echo "function"
      elif [[ "$src_line" =~ $pat_class ]]; then
        echo "class"
      else
        echo "variable"
      fi
      ;;
    java)
      pat_java_class='(^|[[:space:]])(class|interface|enum)[[:space:]]'
      pat_java_method='[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\('
      if [[ "$src_line" =~ $pat_java_class ]]; then
        echo "class"
      elif [[ "$src_line" =~ $pat_java_method ]]; then
        echo "function"
      else
        echo "variable"
      fi
      ;;
    kotlin)
      local pat_kt_class='(^|[[:space:]])(class|interface|object)[[:space:]]'
      local pat_kt_fn='(^|[[:space:]])(fun)[[:space:]]'
      if [[ "$src_line" =~ $pat_kt_class ]]; then
        echo "class"
      elif [[ "$src_line" =~ $pat_kt_fn ]]; then
        echo "function"
      else
        echo "variable"
      fi
      ;;
    *)
      echo "variable"
      ;;
  esac
}

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# Build list of files to process
if [ -f "$SEARCH_PATH" ]; then
  FILES=("$SEARCH_PATH")
else
  FILES=()
  while IFS= read -r _f; do
    [ -n "$_f" ] && FILES+=("$_f")
  done < <(
    find "$SEARCH_PATH" -type f \( \
      -name "*.ts"  -o -name "*.tsx" \
      -o -name "*.js"  -o -name "*.jsx" \
      -o -name "*.mjs" -o -name "*.cjs" \
      -o -name "*.py" \
      -o -name "*.java" \
    \) 2>/dev/null | sort
  )
fi

if [ ${#FILES[@]} -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '[]'
  else
    echo "No supported source files found in: $SEARCH_PATH"
  fi
  exit 0
fi

# Accumulate all symbols as tab-separated records: file TAB name TAB type TAB line TAB col
ALL_SYMBOLS=()

for file in "${FILES[@]}"; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue

  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  query_file="$QUERIES_DIR/$lang/symbols.scm"
  [ ! -f "$query_file" ] && continue

  ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    capture="" row="" col="" text=""

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
    elif [[ "$line" =~ capture:[[:space:]]*([a-z_.]+),[[:space:]]*text:[[:space:]]*\"([^\"]*)\",\ row:[[:space:]]*([0-9]+),\ col:[[:space:]]*([0-9]+) ]]; then
      capture="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
      row="${BASH_REMATCH[3]}"
      col="${BASH_REMATCH[4]}"
    else
      continue
    fi

    # Only process symbol.definition captures
    [ "$capture" != "symbol.definition" ] && continue

    # Skip empty names
    [ -z "$text" ] && continue

    line_num=$((row + 1))
    col_num=$((col + 1))

    sym_type=$(classify_symbol "$file" "$line_num" "$lang")

    ALL_SYMBOLS+=("${file}	${text}	${sym_type}	${line_num}	${col_num}")
  done <<< "$ts_output"
done

# Apply --type filter
FILTERED_SYMBOLS=()
for entry in "${ALL_SYMBOLS[@]}"; do
  IFS=$'\t' read -r _f _n sym_type _l _c <<< "$entry"
  case "$FILTER_TYPE" in
    all)        FILTERED_SYMBOLS+=("$entry") ;;
    definition) FILTERED_SYMBOLS+=("$entry") ;;   # all definitions pass
    function)   [ "$sym_type" = "function" ]  && FILTERED_SYMBOLS+=("$entry") ;;
    class)      [ "$sym_type" = "class" ]     && FILTERED_SYMBOLS+=("$entry") ;;
    variable)   [ "$sym_type" = "variable" ]  && FILTERED_SYMBOLS+=("$entry") ;;
  esac
done

if [ ${#FILTERED_SYMBOLS[@]} -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '[]'
  else
    echo "No symbols found"
  fi
  exit 0
fi

# ── JSON output ──────────────────────────────────────────────────────────────
if [ "$FORMAT" = "json" ]; then
  (
    printf '[\n'
    first=true
    for entry in "${FILTERED_SYMBOLS[@]}"; do
      IFS=$'\t' read -r sym_file sym_name sym_type sym_line sym_col <<< "$entry"
      if [ "$first" = true ]; then
        first=false
      else
        printf ',\n'
      fi
      # Use jq for proper JSON escaping of each object
      jq -n \
        --arg file "$sym_file" \
        --arg name "$sym_name" \
        --arg type "$sym_type" \
        --argjson line "$sym_line" \
        --argjson col  "$sym_col" \
        '{file: $file, name: $name, type: $type, line: $line, col: $col}'
    done
    printf '\n]\n'
  )
  exit 0
fi

# ── Text output: grouped by file, then by type ───────────────────────────────
# Collect unique files in order (bash 3.2 compatible -- no associative arrays)
_seen_files_list=""
file_order=()
for entry in "${FILTERED_SYMBOLS[@]}"; do
  sym_file="${entry%%	*}"
  if ! echo "$_seen_files_list" | grep -qF "|${sym_file}|"; then
    _seen_files_list="${_seen_files_list}|${sym_file}|"
    file_order+=("$sym_file")
  fi
done

total=${#FILTERED_SYMBOLS[@]}
echo "=== Symbol List (total: $total) ==="
echo ""

for sym_file in "${file_order[@]}"; do
  echo "FILE: $sym_file"

  for sym_type_group in function class variable; do
    group_entries=()
    for entry in "${FILTERED_SYMBOLS[@]}"; do
      IFS=$'\t' read -r ef en et el ec <<< "$entry"
      [ "$ef" = "$sym_file" ] || continue
      [ "$et" = "$sym_type_group" ] || continue
      group_entries+=("$en	$el	$ec")
    done

    [ ${#group_entries[@]} -eq 0 ] && continue

    case "$sym_type_group" in
      function) label="Functions" ;;
      class)    label="Classes" ;;
      variable) label="Variables" ;;
    esac

    echo "  ${label} (${#group_entries[@]}):"
    for g in "${group_entries[@]}"; do
      IFS=$'\t' read -r gname gline gcol <<< "$g"
      printf "    %-40s %s:%s\n" "$gname" "$sym_file" "$gline"
    done
  done

  echo ""
done
