#!/usr/bin/env bash
# extract-function.sh
# Extracts a code block into a new function using tree-sitter for scope analysis.
#
# Usage:
#   extract-function.sh --file FILE --start-line N --end-line M --name NEW_FUNC [--dry-run] [--format text|json]

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
FILE=""
START_LINE=""
END_LINE=""
FUNC_NAME=""
DRY_RUN=false
FORMAT="text"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)       FILE="$2";       shift 2 ;;
    --start-line) START_LINE="$2"; shift 2 ;;
    --end-line)   END_LINE="$2";   shift 2 ;;
    --name)       FUNC_NAME="$2";  shift 2 ;;
    --dry-run)    DRY_RUN=true;    shift   ;;
    --format)     FORMAT="$2";     shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$FILE" || -z "$START_LINE" || -z "$END_LINE" || -z "$FUNC_NAME" ]]; then
  echo "Usage: extract-function.sh --file FILE --start-line N --end-line M --name NEW_FUNC [--dry-run] [--format text|json]" >&2
  exit 1
fi

if [[ ! -f "$FILE" ]]; then
  echo "Error: file not found: $FILE" >&2
  exit 1
fi

if ! [[ "$START_LINE" =~ ^[0-9]+$ ]] || ! [[ "$END_LINE" =~ ^[0-9]+$ ]]; then
  echo "Error: --start-line and --end-line must be integers." >&2
  exit 1
fi

if [[ "$START_LINE" -gt "$END_LINE" ]]; then
  echo "Error: --start-line must be <= --end-line." >&2
  exit 1
fi

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json'." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Detect language from file extension
# ---------------------------------------------------------------------------
EXT="${FILE##*.}"
case "$EXT" in
  ts|tsx)      LANG="typescript" ;;
  js|jsx|mjs)  LANG="javascript" ;;
  py)          LANG="python"     ;;
  java)        LANG="java"       ;;
  *)
    echo "Error: unsupported file extension '.$EXT'. Supported: ts, tsx, js, jsx, mjs, py, java." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Helper: resolve the query file for block-range
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)/queries"

# Allow override via environment variable
QUERIES_ROOT="${EXTRACT_FUNC_QUERIES_ROOT:-$QUERIES_ROOT}"

# Map lang → query subdir
case "$LANG" in
  typescript|javascript) QUERY_DIR="$QUERIES_ROOT/typescript" ;;
  python)                QUERY_DIR="$QUERIES_ROOT/python"     ;;
  java)                  QUERY_DIR="$QUERIES_ROOT/java"       ;;
esac

BLOCK_RANGE_QUERY="$QUERY_DIR/block-range.scm"

# ---------------------------------------------------------------------------
# Read file content into an array (1-indexed)
# ---------------------------------------------------------------------------
FILE_LINES=()
while IFS= read -r _fl; do
  FILE_LINES+=("$_fl")
done < "$FILE"
TOTAL_LINES="${#FILE_LINES[@]}"

if [[ "$END_LINE" -gt "$TOTAL_LINES" ]]; then
  echo "Error: --end-line ($END_LINE) exceeds file length ($TOTAL_LINES lines)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract the target block (1-indexed, inclusive)
# ---------------------------------------------------------------------------
BLOCK_LINES=()
for (( i = START_LINE - 1; i < END_LINE; i++ )); do
  BLOCK_LINES+=("${FILE_LINES[$i]}")
done

BLOCK_TEXT="$(printf '%s\n' "${BLOCK_LINES[@]}")"

# ---------------------------------------------------------------------------
# Determine base indentation of the block
# ---------------------------------------------------------------------------
BASE_INDENT=""
for line in "${BLOCK_LINES[@]}"; do
  if [[ -n "${line// }" ]]; then
    BASE_INDENT="${line%%[^ ]*}"
    BASE_INDENT="${BASE_INDENT//	/    }"  # normalise tabs → 4 spaces
    break
  fi
done

# Strip the base indent from block lines for the function body
STRIPPED_BLOCK_LINES=()
for line in "${BLOCK_LINES[@]}"; do
  stripped="${line#$BASE_INDENT}"
  STRIPPED_BLOCK_LINES+=("$stripped")
done

# ---------------------------------------------------------------------------
# Variable analysis using tree-sitter (best-effort; falls back to regex)
# ---------------------------------------------------------------------------

# --- tree-sitter parse for identifier captures ---
run_tree_sitter_identifiers() {
  local target_file="$1"
  # Query that captures every identifier in the file with its position
  local id_query='(identifier) @id'
  if command -v tree-sitter &>/dev/null; then
    # tree-sitter query outputs: pattern_index capture_name start_byte end_byte start_row start_col end_row end_col node_text
    tree-sitter query "$id_query" "$target_file" 2>/dev/null || true
  fi
}

# --- Parse tree-sitter output into parallel arrays (bash 3.2 compatible) ---
# Maps: identifier_name -> space-separated list of "row" values where it appears
ID_ROW_KEYS=()
ID_ROW_VALS=()

if command -v tree-sitter &>/dev/null; then
  re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r ts_line; do
    # tree-sitter CLI output format (depends on version):
    #   capture: N - id, start: (row, col), end: (row, col), text: `name`
    if [[ "$ts_line" =~ $re_v026 ]]; then
      row="${BASH_REMATCH[2]}"
      name="${BASH_REMATCH[4]}"
      row=$(( row + 1 ))
    #   Pattern 0 @id [start_row, start_col] - [end_row, end_col]: "name"
    elif [[ "$ts_line" =~ \[([0-9]+),\ *[0-9]+\]\ *-\ *\[[0-9]+,\ *[0-9]+\]:\ *\"([^\"]+)\" ]]; then
      row="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[2]}"
      # tree-sitter rows are 0-indexed; convert to 1-indexed
      row=$(( row + 1 ))
    else
      continue
    fi
    _idr_found=false
    for _idr_i in "${!ID_ROW_KEYS[@]}"; do
      if [ "${ID_ROW_KEYS[$_idr_i]}" = "$name" ]; then
        ID_ROW_VALS[$_idr_i]="${ID_ROW_VALS[$_idr_i]} $row"
        _idr_found=true
        break
      fi
    done
    if [ "$_idr_found" = false ]; then
      ID_ROW_KEYS+=("$name")
      ID_ROW_VALS+=(" $row")
    fi
  done < <(run_tree_sitter_identifiers "$FILE")
fi

# ---------------------------------------------------------------------------
# Regex-based fallback variable extraction
# ---------------------------------------------------------------------------
# Collect identifier names from the block via regex
extract_identifiers_from_text() {
  local text="$1"
  echo "$text" | grep -oE '\b[a-zA-Z_][a-zA-Z0-9_]*\b' | sort -u
}

# Common keywords to exclude from variable analysis
KEYWORDS_TS="function|const|let|var|return|if|else|for|while|do|switch|case|break|continue|new|this|typeof|instanceof|import|export|default|class|extends|async|await|try|catch|finally|throw|void|null|undefined|true|false|of|in|from|type|interface|enum|public|private|protected|static|readonly|abstract|yield|super|delete"
KEYWORDS_PY="def|class|return|if|elif|else|for|while|and|or|not|in|is|import|from|as|with|try|except|finally|raise|pass|break|continue|lambda|yield|global|nonlocal|del|assert|True|False|None|self|cls|async|await"
KEYWORDS_JAVA="public|private|protected|static|final|abstract|synchronized|volatile|transient|native|class|interface|enum|extends|implements|return|if|else|for|while|do|switch|case|break|continue|new|this|super|try|catch|finally|throw|throws|import|package|void|int|long|double|float|boolean|char|byte|short|null|true|false|instanceof|String|Object"

case "$LANG" in
  typescript|javascript) KW_PATTERN="$KEYWORDS_TS" ;;
  python)                KW_PATTERN="$KEYWORDS_PY" ;;
  java)                  KW_PATTERN="$KEYWORDS_JAVA" ;;
esac

is_keyword() {
  local word="$1"
  echo "$word" | grep -qE "^($KW_PATTERN)$"
}

# Identifiers appearing inside the block
BLOCK_IDS=()
while IFS= read -r id; do
  is_keyword "$id" && continue
  BLOCK_IDS+=("$id")
done < <(extract_identifiers_from_text "$BLOCK_TEXT")

# ---------------------------------------------------------------------------
# Determine params, return_vars using positional heuristics
# ---------------------------------------------------------------------------
BEFORE_TEXT="$(printf '%s\n' "${FILE_LINES[@]:0:$((START_LINE - 1))}")"
AFTER_TEXT=""
if [[ "$END_LINE" -lt "$TOTAL_LINES" ]]; then
  AFTER_TEXT="$(printf '%s\n' "${FILE_LINES[@]:$END_LINE}")"
fi

PARAMS=()
RETURN_VARS=()

for id in "${BLOCK_IDS[@]}"; do
  [[ -z "$id" ]] && continue

  defined_before=false
  used_after=false
  defined_inside=false

  # Check if defined before the block (assignment/declaration)
  case "$LANG" in
    typescript|javascript)
      echo "$BEFORE_TEXT" | grep -qE "(const|let|var)\s+\b${id}\b" && defined_before=true
      echo "$BEFORE_TEXT" | grep -qE "function\s+\b${id}\b" && defined_before=true
      # Also consider function parameters
      ;;
    python)
      echo "$BEFORE_TEXT" | grep -qE "^\s*\b${id}\b\s*=" && defined_before=true
      ;;
    java)
      echo "$BEFORE_TEXT" | grep -qE "\b\w+\s+\b${id}\b\s*[=;(,)]" && defined_before=true
      ;;
  esac

  # Check if defined inside the block
  case "$LANG" in
    typescript|javascript)
      echo "$BLOCK_TEXT" | grep -qE "(const|let|var)\s+\b${id}\b" && defined_inside=true
      ;;
    python)
      echo "$BLOCK_TEXT" | grep -qE "^\s*\b${id}\b\s*=" && defined_inside=true
      ;;
    java)
      echo "$BLOCK_TEXT" | grep -qE "\b\w+\s+\b${id}\b\s*[=;(,)]" && defined_inside=true
      ;;
  esac

  # Check if used after the block
  [[ -n "$AFTER_TEXT" ]] && echo "$AFTER_TEXT" | grep -qE "\b${id}\b" && used_after=true

  # Classify
  if $defined_before && ! $defined_inside; then
    PARAMS+=("$id")
  elif $defined_inside && $used_after; then
    RETURN_VARS+=("$id")
  fi
  # else: local only — keep as-is
done

# Deduplicate
PARAMS=($(printf '%s\n' "${PARAMS[@]}" | sort -u))
RETURN_VARS=($(printf '%s\n' "${RETURN_VARS[@]}" | sort -u))

# ---------------------------------------------------------------------------
# Find the enclosing function scope using tree-sitter block-range query
# ---------------------------------------------------------------------------
ENCLOSING_FUNC_START_LINE=1  # default: top of file

find_enclosing_function() {
  if [[ ! -f "$BLOCK_RANGE_QUERY" ]]; then
    return
  fi
  if ! command -v tree-sitter &>/dev/null; then
    return
  fi

  # Run tree-sitter with the block-range query
  local best_start=0
  local best_end=999999999

  local re_v026_body='capture: [0-9]+ - block\.body, start: \(([0-9]+), [0-9]+\).* end: \(([0-9]+), [0-9]+\)'
  while IFS= read -r ts_line; do
    # Match lines like: capture: N - block.body, start: (row, col), end: (row, col), text: `...`
    if [[ "$ts_line" =~ $re_v026_body ]]; then
      local s=$(( BASH_REMATCH[1] + 1 ))
      local e=$(( BASH_REMATCH[2] + 1 ))
      if [[ "$s" -le "$START_LINE" && "$e" -ge "$END_LINE" ]]; then
        if [[ "$s" -ge "$best_start" && "$e" -le "$best_end" ]]; then
          best_start="$s"
          best_end="$e"
        fi
      fi
    # Match lines like: @block.body [start_row, start_col] - [end_row, end_col]:
    elif [[ "$ts_line" =~ @block\.body\ \[([0-9]+),\ *[0-9]+\]\ *-\ *\[([0-9]+),\ *[0-9]+\] ]]; then
      local s=$(( BASH_REMATCH[1] + 1 ))  # convert 0-indexed → 1-indexed
      local e=$(( BASH_REMATCH[2] + 1 ))
      # Must enclose our selection and be tighter than previous best
      if [[ "$s" -le "$START_LINE" && "$e" -ge "$END_LINE" ]]; then
        if [[ "$s" -ge "$best_start" && "$e" -le "$best_end" ]]; then
          best_start="$s"
          best_end="$e"
        fi
      fi
    fi
  done < <(tree-sitter query "$BLOCK_RANGE_QUERY" "$FILE" 2>/dev/null || true)

  if [[ "$best_start" -gt 0 ]]; then
    ENCLOSING_FUNC_START_LINE="$best_start"
  fi
}

find_enclosing_function

# ---------------------------------------------------------------------------
# Generate new function code
# ---------------------------------------------------------------------------
INDENT="$BASE_INDENT"  # function body indentation = block's own indentation

# Build body string (indented one extra level for the new function body)
case "$LANG" in
  python) EXTRA_INDENT="    " ;;
  *)      EXTRA_INDENT="    " ;;
esac

INDENTED_BODY=""
for line in "${STRIPPED_BLOCK_LINES[@]}"; do
  INDENTED_BODY+="${EXTRA_INDENT}${line}"$'\n'
done

# Build return statement
RETURN_STMT=""
if [[ "${#RETURN_VARS[@]}" -gt 0 ]]; then
  case "$LANG" in
    typescript|javascript)
      if [[ "${#RETURN_VARS[@]}" -eq 1 ]]; then
        RETURN_STMT="${EXTRA_INDENT}return ${RETURN_VARS[0]};"$'\n'
      else
        RETURN_STMT="${EXTRA_INDENT}return { $(IFS=', '; echo "${RETURN_VARS[*]}") };"$'\n'
      fi
      ;;
    python)
      RETURN_STMT="${EXTRA_INDENT}return $(IFS=', '; echo "${RETURN_VARS[*]}")"$'\n'
      ;;
    java)
      if [[ "${#RETURN_VARS[@]}" -eq 1 ]]; then
        RETURN_STMT="${EXTRA_INDENT}return ${RETURN_VARS[0]};"$'\n'
      else
        # Java doesn't have tuples; wrap in Object[] as a best-effort
        RETURN_STMT="${EXTRA_INDENT}// TODO: refactor multi-return into a dedicated class"$'\n'
        RETURN_STMT+="${EXTRA_INDENT}return new Object[]{ $(IFS=', '; echo "${RETURN_VARS[*]}") };"$'\n'
      fi
      ;;
  esac
fi

# Build parameter list string
PARAM_LIST="$(IFS=', '; echo "${PARAMS[*]:-}")"

# Return type hint (Java needs types; we use Object as a placeholder)
JAVA_RETURN_TYPE="void"
if [[ "${#RETURN_VARS[@]}" -eq 1 ]]; then
  JAVA_RETURN_TYPE="Object"
elif [[ "${#RETURN_VARS[@]}" -gt 1 ]]; then
  JAVA_RETURN_TYPE="Object[]"
fi

JAVA_PARAMS=""
for p in "${PARAMS[@]}"; do
  [[ -n "$JAVA_PARAMS" ]] && JAVA_PARAMS+=", "
  JAVA_PARAMS+="Object $p"
done

# Construct the new function definition
case "$LANG" in
  typescript|javascript)
    NEW_FUNC_DEF="${INDENT}function ${FUNC_NAME}(${PARAM_LIST}) {"$'\n'
    NEW_FUNC_DEF+="${INDENTED_BODY}"
    NEW_FUNC_DEF+="${RETURN_STMT}"
    NEW_FUNC_DEF+="${INDENT}}"$'\n'
    ;;
  python)
    NEW_FUNC_DEF="${INDENT}def ${FUNC_NAME}(${PARAM_LIST}):"$'\n'
    NEW_FUNC_DEF+="${INDENTED_BODY}"
    NEW_FUNC_DEF+="${RETURN_STMT}"
    ;;
  java)
    NEW_FUNC_DEF="${INDENT}private ${JAVA_RETURN_TYPE} ${FUNC_NAME}(${JAVA_PARAMS}) {"$'\n'
    NEW_FUNC_DEF+="${INDENTED_BODY}"
    NEW_FUNC_DEF+="${RETURN_STMT}"
    NEW_FUNC_DEF+="${INDENT}}"$'\n'
    ;;
esac

# ---------------------------------------------------------------------------
# Build the replacement call
# ---------------------------------------------------------------------------
case "$LANG" in
  typescript|javascript)
    if [[ "${#RETURN_VARS[@]}" -eq 1 ]]; then
      CALL_STMT="${BASE_INDENT}const ${RETURN_VARS[0]} = ${FUNC_NAME}(${PARAM_LIST});"
    elif [[ "${#RETURN_VARS[@]}" -gt 1 ]]; then
      DESTRUCTURE="{ $(IFS=', '; echo "${RETURN_VARS[*]}") }"
      CALL_STMT="${BASE_INDENT}const ${DESTRUCTURE} = ${FUNC_NAME}(${PARAM_LIST});"
    else
      CALL_STMT="${BASE_INDENT}${FUNC_NAME}(${PARAM_LIST});"
    fi
    ;;
  python)
    if [[ "${#RETURN_VARS[@]}" -gt 0 ]]; then
      LHS="$(IFS=', '; echo "${RETURN_VARS[*]}")"
      CALL_STMT="${BASE_INDENT}${LHS} = ${FUNC_NAME}(${PARAM_LIST})"
    else
      CALL_STMT="${BASE_INDENT}${FUNC_NAME}(${PARAM_LIST})"
    fi
    ;;
  java)
    if [[ "${#RETURN_VARS[@]}" -eq 1 ]]; then
      CALL_STMT="${BASE_INDENT}Object ${RETURN_VARS[0]} = ${FUNC_NAME}(${PARAM_LIST});"
    elif [[ "${#RETURN_VARS[@]}" -gt 1 ]]; then
      CALL_STMT="${BASE_INDENT}Object[] _result = ${FUNC_NAME}(${PARAM_LIST});"
      for i in "${!RETURN_VARS[@]}"; do
        CALL_STMT+=$'\n'"${BASE_INDENT}Object ${RETURN_VARS[$i]} = _result[$i];"
      done
    else
      CALL_STMT="${BASE_INDENT}${FUNC_NAME}(${PARAM_LIST});"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Assemble the new file content
# ---------------------------------------------------------------------------
# Lines before enclosing function (0-indexed end = ENCLOSING_FUNC_START_LINE - 2)
BEFORE_ENCLOSING_LINES=("${FILE_LINES[@]:0:$((ENCLOSING_FUNC_START_LINE - 1))}")

# Lines from enclosing function start to just before the block
BETWEEN_LINES=("${FILE_LINES[@]:$((ENCLOSING_FUNC_START_LINE - 1)):$((START_LINE - ENCLOSING_FUNC_START_LINE))}")

# Lines after the block to end of file
AFTER_BLOCK_LINES=("${FILE_LINES[@]:$END_LINE}")

NEW_FILE_CONTENT=""

# 1. Everything before the enclosing function
if [[ "${#BEFORE_ENCLOSING_LINES[@]}" -gt 0 ]]; then
  NEW_FILE_CONTENT+="$(printf '%s\n' "${BEFORE_ENCLOSING_LINES[@]}")"$'\n'
fi

# 2. The new extracted function definition (inserted before enclosing function)
NEW_FILE_CONTENT+="${NEW_FUNC_DEF}"$'\n'

# 3. The enclosing function up to the block
if [[ "${#BETWEEN_LINES[@]}" -gt 0 ]]; then
  NEW_FILE_CONTENT+="$(printf '%s\n' "${BETWEEN_LINES[@]}")"$'\n'
fi

# 4. The replacement call
NEW_FILE_CONTENT+="${CALL_STMT}"$'\n'

# 5. Everything after the block
if [[ "${#AFTER_BLOCK_LINES[@]}" -gt 0 ]]; then
  NEW_FILE_CONTENT+="$(printf '%s\n' "${AFTER_BLOCK_LINES[@]}")"
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "$FORMAT" == "json" ]]; then
  # Escape for JSON
  escape_json() {
    python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))" <<< "$1"
  }
  NEW_FUNC_JSON="$(escape_json "$NEW_FUNC_DEF")"
  CALL_JSON="$(escape_json "$CALL_STMT")"
  PARAMS_JSON="$(python3 -c "import sys, json; print(json.dumps(sys.argv[1:]))" "${PARAMS[@]:-_empty}")"
  RETURN_JSON="$(python3 -c "import sys, json; print(json.dumps(sys.argv[1:]))" "${RETURN_VARS[@]:-_empty}")"

  cat <<JSON
{
  "language": "$LANG",
  "file": "$FILE",
  "start_line": $START_LINE,
  "end_line": $END_LINE,
  "function_name": "$FUNC_NAME",
  "params": $(python3 -c "import sys,json; a=sys.argv[1:]; print(json.dumps([x for x in a if x != '_empty']))" "${PARAMS[@]:-_empty}"),
  "return_vars": $(python3 -c "import sys,json; a=sys.argv[1:]; print(json.dumps([x for x in a if x != '_empty']))" "${RETURN_VARS[@]:-_empty}"),
  "new_function": $NEW_FUNC_JSON,
  "call_replacement": $CALL_JSON,
  "dry_run": $DRY_RUN
}
JSON
else
  echo "Language   : $LANG"
  echo "File       : $FILE"
  echo "Block      : lines ${START_LINE}-${END_LINE}"
  echo "New func   : $FUNC_NAME"
  echo "Params     : ${PARAMS[*]:-<none>}"
  echo "Return vars: ${RETURN_VARS[*]:-<none>}"
  echo ""
  echo "=== New function definition ==="
  echo "$NEW_FUNC_DEF"
  echo "=== Call replacement ==="
  echo "$CALL_STMT"
fi

if $DRY_RUN; then
  if [[ "$FORMAT" == "text" ]]; then
    echo ""
    echo "(dry-run: no files were modified)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Write the new file
# ---------------------------------------------------------------------------
printf '%s' "$NEW_FILE_CONTENT" > "$FILE"

if [[ "$FORMAT" == "text" ]]; then
  echo ""
  echo "File updated: $FILE"
fi
