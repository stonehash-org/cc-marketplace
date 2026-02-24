#!/usr/bin/env bash
# move-symbol.sh
# Moves a symbol (function, class, variable) from one file to another,
# updating imports across the project.
#
# Usage:
#   move-symbol.sh --symbol NAME --from FILE --to FILE [--path DIR] [--dry-run] [--format text|json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SYMBOL=""
FROM_FILE=""
TO_FILE=""
SEARCH_PATH="."
DRY_RUN=false
FORMAT="text"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol NAME --from FILE --to FILE [--path DIR] [--dry-run] [--format text|json]

Move a symbol definition from one file to another, updating all imports.

Options:
  --symbol NAME   Symbol name to move (required)
  --from FILE     Source file containing the symbol (required)
  --to FILE       Target file to move the symbol to (required)
  --path DIR      Project root to search for references (default: .)
  --dry-run       Show what would change without modifying files
  --format FMT    Output format: text or json (default: text)
  -h, --help      Show this help

Example:
  $(basename "$0") --symbol parseDate --from src/utils.ts --to src/date-utils.ts
  $(basename "$0") --symbol MyClass --from src/old.py --to src/new.py --dry-run
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol) SYMBOL="$2";      shift 2 ;;
    --from)   FROM_FILE="$2";   shift 2 ;;
    --to)     TO_FILE="$2";     shift 2 ;;
    --path)   SEARCH_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;    shift   ;;
    --format) FORMAT="$2";      shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -z "$SYMBOL" ] || [ -z "$FROM_FILE" ] || [ -z "$TO_FILE" ]; then
  echo "Error: --symbol, --from, and --to are required" >&2
  exit 1
fi

if [ ! -f "$FROM_FILE" ]; then
  echo "Error: source file not found: $FROM_FILE" >&2
  exit 1
fi

if [ "$FORMAT" != "text" ] && [ "$FORMAT" != "json" ]; then
  echo "Error: --format must be 'text' or 'json'" >&2
  exit 1
fi

LANG=$(detect_language "$FROM_FILE")
if [ -z "$LANG" ]; then
  echo "Error: unsupported file type: $FROM_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Locate the symbol definition in the source file
# ---------------------------------------------------------------------------
SYMBOLS_QUERY=$(get_query_file "$LANG" "symbols")
BLOCK_QUERY=$(get_query_file "$LANG" "block-range")

if [ ! -f "$SYMBOLS_QUERY" ]; then
  echo "Error: symbols query not found for language '$LANG'" >&2
  exit 1
fi

# Find the symbol's definition row (0-indexed from tree-sitter)
SYMBOL_DEF_ROW=""
while IFS=$'\t' read -r capture row col text; do
  [ -z "$capture" ] && continue
  [ "$text" != "$SYMBOL" ] && continue
  if [ "$capture" = "symbol.definition" ]; then
    SYMBOL_DEF_ROW="$row"
    break
  fi
done < <(run_query "$SYMBOLS_QUERY" "$FROM_FILE")

if [ -z "$SYMBOL_DEF_ROW" ]; then
  echo "Error: symbol '$SYMBOL' definition not found in $FROM_FILE" >&2
  exit 1
fi

# Convert to 1-indexed line number
SYMBOL_DEF_LINE=$((SYMBOL_DEF_ROW + 1))

# ---------------------------------------------------------------------------
# Step 2: Determine symbol boundaries (start line, end line)
# ---------------------------------------------------------------------------
# Get the line content to classify the symbol type
DEF_LINE_CONTENT=$(get_line "$FROM_FILE" "$SYMBOL_DEF_LINE")
SYMBOL_TYPE=$(classify_symbol "$LANG" "$DEF_LINE_CONTENT")

BLOCK_START=""
BLOCK_END=""

# For functions and classes, use block-range.scm to find the full block
if [ -f "$BLOCK_QUERY" ] && [ "$SYMBOL_TYPE" != "variable" ]; then
  while IFS=$'\t' read -r capture row col text; do
    [ -z "$capture" ] && continue
    if [ "$capture" = "block.name" ] && [ "$text" = "$SYMBOL" ]; then
      # The next block.body capture gives us the body range
      FOUND_NAME=true
      continue
    fi
    if [ "${FOUND_NAME:-}" = "true" ] && [ "$capture" = "block.body" ]; then
      # row is start of body; we need from the declaration line to end of body
      BLOCK_END=$((row + 1))  # 0-indexed -> 1-indexed
      FOUND_NAME=""
      break
    fi
  done < <(run_query "$BLOCK_QUERY" "$FROM_FILE")
fi

# For block-range approach: parse raw tree-sitter output for end row of body
# because run_query only gives us start row, not end row
if [ "$SYMBOL_TYPE" != "variable" ] && [ -f "$BLOCK_QUERY" ]; then
  BLOCK_START=""
  BLOCK_END=""
  ts_raw=$(tree-sitter query "$BLOCK_QUERY" "$FROM_FILE" 2>/dev/null || true)
  if [ -n "$ts_raw" ]; then
    FOUND_NAME=""
    re_v026_name='capture: [0-9]+ - block\.name, start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
    re_v026_body='capture: [0-9]+ - block\.body, start: \(([0-9]+), ([0-9]+)\).* end: \(([0-9]+), ([0-9]+)\)'
    while IFS= read -r line; do
      # Parse @block.name captures
      if [[ "$line" =~ $re_v026_name ]]; then
        name_row="${BASH_REMATCH[1]}"
        name_text="${BASH_REMATCH[3]}"
        if [ "$name_text" = "$SYMBOL" ]; then
          FOUND_NAME="true"
          BLOCK_START=$((name_row + 1))
        fi
      elif [[ "$line" =~ @block\.name[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
        name_row="${BASH_REMATCH[1]}"
        name_text="${BASH_REMATCH[3]}"
        if [ "$name_text" = "$SYMBOL" ]; then
          FOUND_NAME="true"
          # Block starts at the declaration line (same as name row or earlier)
          BLOCK_START=$((name_row + 1))
        fi
      elif [[ "$line" =~ capture:\ block\.name,\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+) ]]; then
        name_text="${BASH_REMATCH[1]}"
        name_row="${BASH_REMATCH[2]}"
        if [ "$name_text" = "$SYMBOL" ]; then
          FOUND_NAME="true"
          BLOCK_START=$((name_row + 1))
        fi
      fi

      # Parse @block.body captures - look for the one right after matching name
      if [ "$FOUND_NAME" = "true" ]; then
        if [[ "$line" =~ $re_v026_body ]]; then
          body_end_row="${BASH_REMATCH[3]}"
          BLOCK_END=$((body_end_row + 1))
          break
        elif [[ "$line" =~ @block\.body[[:space:]]+\(([0-9]+),\ ([0-9]+)\)\ -\ \(([0-9]+),\ ([0-9]+)\) ]]; then
          body_end_row="${BASH_REMATCH[3]}"
          BLOCK_END=$((body_end_row + 1))
          break
        elif [[ "$line" =~ @block\.body[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
          # Fallback: try to get end from the text
          body_start_row="${BASH_REMATCH[1]}"
          :
        elif [[ "$line" =~ capture:\ block\.body.*row:\ ([0-9]+) ]]; then
          :
        fi
      fi
    done <<< "$ts_raw"
  fi

  # If we could not find end from range format, use a heuristic:
  # scan from block start to find the closing brace/dedent
  if [ -n "$BLOCK_START" ] && [ -z "$BLOCK_END" ]; then
    TOTAL_LINES=$(wc -l < "$FROM_FILE" | tr -d ' ')
    case "$LANG" in
      typescript|java)
        # Find matching closing brace by counting braces
        brace_depth=0
        found_open=false
        for (( i = BLOCK_START; i <= TOTAL_LINES; i++ )); do
          line_text=$(get_line "$FROM_FILE" "$i")
          # Count braces on this line
          opens=$(echo "$line_text" | tr -cd '{' | wc -c | tr -d ' ')
          closes=$(echo "$line_text" | tr -cd '}' | wc -c | tr -d ' ')
          brace_depth=$((brace_depth + opens - closes))
          if [ "$opens" -gt 0 ]; then
            found_open=true
          fi
          if [ "$found_open" = true ] && [ "$brace_depth" -le 0 ]; then
            BLOCK_END="$i"
            break
          fi
        done
        ;;
      python)
        # Find end by looking at indentation - block ends when indent decreases
        base_indent=$(get_line "$FROM_FILE" "$BLOCK_START" | sed 's/[^ ].*//' | wc -c | tr -d ' ')
        BLOCK_END="$BLOCK_START"
        for (( i = BLOCK_START + 1; i <= TOTAL_LINES; i++ )); do
          line_text=$(get_line "$FROM_FILE" "$i")
          # Skip empty lines
          if echo "$line_text" | grep -q '^[[:space:]]*$'; then
            BLOCK_END="$i"
            continue
          fi
          cur_indent=$(echo "$line_text" | sed 's/[^ ].*//' | wc -c | tr -d ' ')
          if [ "$cur_indent" -lt "$base_indent" ]; then
            break
          fi
          BLOCK_END="$i"
        done
        ;;
    esac
  fi
fi

# For variables or if block-range didn't find it, use single-line or
# scan for semicolon/end of statement
if [ -z "$BLOCK_START" ] || [ -z "$BLOCK_END" ]; then
  BLOCK_START="$SYMBOL_DEF_LINE"
  if [ "$SYMBOL_TYPE" = "variable" ]; then
    # Check if it is a multi-line declaration (e.g., object literal, array)
    line_text=$(get_line "$FROM_FILE" "$SYMBOL_DEF_LINE")
    case "$LANG" in
      typescript)
        # Check if line contains opening brace/bracket without closing
        opens=$(echo "$line_text" | tr -cd '{[(' | wc -c | tr -d ' ')
        closes=$(echo "$line_text" | tr -cd '}])' | wc -c | tr -d ' ')
        if [ "$opens" -gt "$closes" ]; then
          # Multi-line: scan for balanced closure
          depth=$((opens - closes))
          TOTAL_LINES=$(wc -l < "$FROM_FILE" | tr -d ' ')
          BLOCK_END="$SYMBOL_DEF_LINE"
          for (( i = SYMBOL_DEF_LINE + 1; i <= TOTAL_LINES; i++ )); do
            l=$(get_line "$FROM_FILE" "$i")
            o=$(echo "$l" | tr -cd '{[(' | wc -c | tr -d ' ')
            c=$(echo "$l" | tr -cd '}])' | wc -c | tr -d ' ')
            depth=$((depth + o - c))
            BLOCK_END="$i"
            if [ "$depth" -le 0 ]; then
              break
            fi
          done
        else
          BLOCK_END="$SYMBOL_DEF_LINE"
        fi
        ;;
      *)
        BLOCK_END="$SYMBOL_DEF_LINE"
        ;;
    esac
  else
    BLOCK_END="$SYMBOL_DEF_LINE"
  fi
fi

# Adjust BLOCK_START: walk upward to capture decorators, export keyword, JSDoc, etc.
adjust_block_start() {
  local start="$1"
  local file="$2"

  # Walk upward to include preceding decorators, export keywords, comments
  local cur=$((start - 1))
  while [ "$cur" -ge 1 ]; do
    local prev_line
    prev_line=$(get_line "$file" "$cur")
    # Include export keyword lines
    if echo "$prev_line" | grep -qE '^\s*export\s'; then
      start="$cur"
      cur=$((cur - 1))
      continue
    fi
    # Include decorators (Python @decorator, Java @Annotation)
    if echo "$prev_line" | grep -qE '^\s*@'; then
      start="$cur"
      cur=$((cur - 1))
      continue
    fi
    # Include JSDoc/block comments that end right before
    if echo "$prev_line" | grep -qE '^\s*\*/' || echo "$prev_line" | grep -qE '^\s*\*' || echo "$prev_line" | grep -qE '^\s*/\*\*'; then
      start="$cur"
      cur=$((cur - 1))
      continue
    fi
    # Include single-line comments directly above
    if echo "$prev_line" | grep -qE '^\s*//' || echo "$prev_line" | grep -qE '^\s*#'; then
      start="$cur"
      cur=$((cur - 1))
      continue
    fi
    break
  done

  echo "$start"
}

BLOCK_START=$(adjust_block_start "$BLOCK_START" "$FROM_FILE")

# Also check if the declaration line starts with "export" and is part of the block
first_line=$(get_line "$FROM_FILE" "$BLOCK_START")
HAS_EXPORT=false
if echo "$first_line" | grep -qE '^\s*export\s+(default\s+)?'; then
  HAS_EXPORT=true
fi

# ---------------------------------------------------------------------------
# Step 3: Extract the definition block text
# ---------------------------------------------------------------------------
DEFINITION_BLOCK=""
for (( i = BLOCK_START; i <= BLOCK_END; i++ )); do
  line_text=$(get_line "$FROM_FILE" "$i")
  DEFINITION_BLOCK+="$line_text"
  if [ "$i" -lt "$BLOCK_END" ]; then
    DEFINITION_BLOCK+=$'\n'
  fi
done

# Strip the "export" or "export default" prefix for the target file insertion
# (we will re-add export in the target file if desired)
TARGET_BLOCK="$DEFINITION_BLOCK"

# ---------------------------------------------------------------------------
# Step 4: Determine imports the symbol depends on
# ---------------------------------------------------------------------------
# Collect all identifiers used in the definition block
BLOCK_IDENTIFIERS=()
if command -v tree-sitter &>/dev/null; then
  # Write block to a temp file for tree-sitter analysis
  TEMP_BLOCK=$(mktemp "${TMPDIR:-/tmp}/move-symbol-block.XXXXXX")
  # Add appropriate extension for tree-sitter language detection
  case "$LANG" in
    typescript) TEMP_BLOCK_EXT="${TEMP_BLOCK}.ts" ;;
    python)     TEMP_BLOCK_EXT="${TEMP_BLOCK}.py" ;;
    java)       TEMP_BLOCK_EXT="${TEMP_BLOCK}.java" ;;
    *)          TEMP_BLOCK_EXT="$TEMP_BLOCK" ;;
  esac
  cp "$TEMP_BLOCK" "$TEMP_BLOCK_EXT" 2>/dev/null || true
  printf '%s\n' "$TARGET_BLOCK" > "$TEMP_BLOCK_EXT"

  while IFS=$'\t' read -r capture row col text; do
    [ -z "$capture" ] && continue
    is_excludable "$capture" && continue
    [ "$capture" = "symbol.definition" ] && continue
    [ "$capture" = "symbol.parameter" ] && continue
    BLOCK_IDENTIFIERS+=("$text")
  done < <(run_query "$SYMBOLS_QUERY" "$TEMP_BLOCK_EXT")

  rm -f "$TEMP_BLOCK" "$TEMP_BLOCK_EXT" 2>/dev/null
fi

# Deduplicate block identifiers
UNIQUE_BLOCK_IDS=()
if [ ${#BLOCK_IDENTIFIERS[@]} -gt 0 ]; then
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    UNIQUE_BLOCK_IDS+=("$id")
  done < <(printf '%s\n' "${BLOCK_IDENTIFIERS[@]}" | sort -u)
fi

# Collect import lines from the source file
# Find all import lines and check which ones contain identifiers used in the block
SOURCE_IMPORT_LINES=()
DEPENDENCY_IMPORTS=()

TOTAL_FROM_LINES=$(wc -l < "$FROM_FILE" | tr -d ' ')
for (( i = 1; i <= TOTAL_FROM_LINES; i++ )); do
  line_text=$(get_line "$FROM_FILE" "$i")
  is_import=false
  case "$LANG" in
    typescript)
      echo "$line_text" | grep -qE '^\s*(import|const\s+.*=\s*require)' && is_import=true
      ;;
    python)
      echo "$line_text" | grep -qE '^\s*(import |from )' && is_import=true
      ;;
    java)
      echo "$line_text" | grep -qE '^\s*import ' && is_import=true
      ;;
  esac

  if [ "$is_import" = true ]; then
    SOURCE_IMPORT_LINES+=("$i:$line_text")
    # Check if any identifier in this import is used in the block
    for id in ${UNIQUE_BLOCK_IDS[@]+"${UNIQUE_BLOCK_IDS[@]}"}; do
      if echo "$line_text" | grep -qw "$id"; then
        DEPENDENCY_IMPORTS+=("$line_text")
        break
      fi
    done
  fi
done

# Deduplicate dependency imports
UNIQUE_DEP_IMPORTS=()
if [ ${#DEPENDENCY_IMPORTS[@]} -gt 0 ]; then
  while IFS= read -r imp; do
    [ -z "$imp" ] && continue
    UNIQUE_DEP_IMPORTS+=("$imp")
  done < <(printf '%s\n' "${DEPENDENCY_IMPORTS[@]}" | sort -u)
fi

# ---------------------------------------------------------------------------
# Step 5: Build the content to insert into the target file
# ---------------------------------------------------------------------------
INSERT_CONTENT=""

# Add dependency imports first
for imp in ${UNIQUE_DEP_IMPORTS[@]+"${UNIQUE_DEP_IMPORTS[@]}"}; do
  INSERT_CONTENT+="$imp"$'\n'
done

if [ ${#UNIQUE_DEP_IMPORTS[@]} -gt 0 ]; then
  INSERT_CONTENT+=$'\n'
fi

# Add the definition block
INSERT_CONTENT+="$TARGET_BLOCK"$'\n'

# ---------------------------------------------------------------------------
# Step 6: Compute relative import path from source to target
# ---------------------------------------------------------------------------
compute_relative_path() {
  local from_file="$1"
  local to_file="$2"

  local from_dir
  from_dir=$(dirname "$from_file")
  local to_no_ext="${to_file%.*}"

  # Use python3 for reliable relative path computation
  python3 -c "
import os.path
rel = os.path.relpath('$to_no_ext', '$from_dir')
if not rel.startswith('.'):
    rel = './' + rel
print(rel)
"
}

REL_IMPORT_PATH=$(compute_relative_path "$FROM_FILE" "$TO_FILE")

# Also compute relative path from target back to source (for dependency imports
# that might reference the source file)
REL_FROM_TARGET=$(compute_relative_path "$TO_FILE" "$FROM_FILE")

# ---------------------------------------------------------------------------
# Step 7: Build the re-export/import statement for the source file
# ---------------------------------------------------------------------------
build_reexport() {
  local lang="$1"
  local symbol="$2"
  local import_path="$3"

  case "$lang" in
    typescript)
      echo "export { $symbol } from '$import_path';"
      ;;
    python)
      # Convert file path to module path
      local module_path
      module_path=$(echo "$import_path" | sed 's|^\./||; s|/|.|g')
      echo "from $module_path import $symbol"
      ;;
    java)
      # Java: not applicable in the same way; add a comment
      echo "// Symbol '$symbol' moved to $(basename "$TO_FILE")"
      ;;
  esac
}

REEXPORT_STMT=$(build_reexport "$LANG" "$SYMBOL" "$REL_IMPORT_PATH")

# ---------------------------------------------------------------------------
# Step 8: Build import statement for other files to use the new location
# ---------------------------------------------------------------------------
build_import() {
  local lang="$1"
  local symbol="$2"
  local import_path="$3"

  case "$lang" in
    typescript)
      echo "import { $symbol } from '$import_path';"
      ;;
    python)
      local module_path
      module_path=$(echo "$import_path" | sed 's|^\./||; s|/|.|g')
      echo "from $module_path import $symbol"
      ;;
    java)
      echo "import $import_path.$symbol;"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 9: Find files that import the symbol from the source file
# ---------------------------------------------------------------------------
EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")
UPDATED_FILES=()

from_basename=$(basename "$FROM_FILE")
from_module="${from_basename%.*}"
from_rel="${FROM_FILE#./}"
from_rel_no_ext="${from_rel%.*}"

to_basename=$(basename "$TO_FILE")
to_module="${to_basename%.*}"
to_rel="${TO_FILE#./}"
to_rel_no_ext="${to_rel%.*}"

# Find candidate files that reference both the symbol and the source file module
IMPORT_CANDIDATES=""
if [ -d "$SEARCH_PATH" ]; then
  IMPORT_CANDIDATES=$(eval rg -l --fixed-strings '"$SYMBOL"' '"$SEARCH_PATH"' \
    $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)
fi

# Process each candidate file to update imports
while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ "$file" = "$FROM_FILE" ] && continue
  [ "$file" = "$TO_FILE" ] && continue

  file_lang=$(detect_language "$file")
  [ -z "$file_lang" ] && continue

  # Check if this file imports the symbol from the source file
  has_import_from_source=false
  import_line_num=""

  case "$file_lang" in
    typescript)
      # Match import lines that reference the source module
      import_match=$(rg -n "import.*$SYMBOL.*from.*['\"].*${from_module}['\"]" "$file" 2>/dev/null || true)
      if [ -n "$import_match" ]; then
        has_import_from_source=true
        import_line_num=$(echo "$import_match" | head -1 | cut -d: -f1)
      fi
      ;;
    python)
      import_match=$(rg -n "(from\s+\S*${from_module}\s+import.*${SYMBOL}|import\s+\S*${from_module})" "$file" 2>/dev/null || true)
      if [ -n "$import_match" ]; then
        has_import_from_source=true
        import_line_num=$(echo "$import_match" | head -1 | cut -d: -f1)
      fi
      ;;
    java)
      import_match=$(rg -n "import\s+.*${SYMBOL}" "$file" 2>/dev/null || true)
      if [ -n "$import_match" ]; then
        has_import_from_source=true
        import_line_num=$(echo "$import_match" | head -1 | cut -d: -f1)
      fi
      ;;
  esac

  if [ "$has_import_from_source" = true ] && [ -n "$import_line_num" ]; then
    # Compute relative import path from this file to the target file
    file_to_target_rel=$(compute_relative_path "$file" "$TO_FILE")
    old_import_line=$(get_line "$file" "$import_line_num")

    # Build the new import line
    case "$file_lang" in
      typescript)
        # Replace the module path in the import statement
        # Handle both single and double quotes
        new_import_line=$(echo "$old_import_line" | sed "s|from ['\"][^'\"]*${from_module}[^'\"]*['\"]|from '${file_to_target_rel}'|")
        ;;
      python)
        # Replace the module path
        old_module_path=$(echo "$old_import_line" | grep -oE 'from\s+\S+' | sed 's/from\s*//')
        new_module_path=$(echo "$file_to_target_rel" | sed 's|^\./||; s|/|.|g')
        new_import_line=$(echo "$old_import_line" | sed "s|${old_module_path}|${new_module_path}|")
        ;;
      java)
        new_import_line=$(build_import "$file_lang" "$SYMBOL" "$file_to_target_rel")
        ;;
    esac

    if [ "$DRY_RUN" = false ]; then
      sed -i '' "${import_line_num}s|.*|${new_import_line}|" "$file"
    fi

    UPDATED_FILES+=("$file:$import_line_num")
  fi
done <<< "$IMPORT_CANDIDATES"

# ---------------------------------------------------------------------------
# Step 10: Apply changes (unless dry-run)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = false ]; then
  # 10a. Insert the definition block into the target file
  if [ -f "$TO_FILE" ]; then
    # Read existing target content
    existing_content=$(cat "$TO_FILE")

    # Check if dependency imports already exist in target, skip duplicates
    IMPORTS_TO_ADD=""
    for imp in ${UNIQUE_DEP_IMPORTS[@]+"${UNIQUE_DEP_IMPORTS[@]}"}; do
      if ! grep -qF "$imp" "$TO_FILE" 2>/dev/null; then
        IMPORTS_TO_ADD+="$imp"$'\n'
      fi
    done

    # Append the block at the end of the target file
    {
      printf '%s\n' "$existing_content"
      echo ""
      if [ -n "$IMPORTS_TO_ADD" ]; then
        printf '%s' "$IMPORTS_TO_ADD"
        echo ""
      fi
      printf '%s\n' "$TARGET_BLOCK"
    } > "$TO_FILE"
  else
    # Create the target file with imports and the definition block
    to_dir=$(dirname "$TO_FILE")
    mkdir -p "$to_dir"
    printf '%s' "$INSERT_CONTENT" > "$TO_FILE"
  fi

  # 10b. Remove the definition block from the source file
  # Also remove the blank line after the block if present
  sed_range="${BLOCK_START},${BLOCK_END}d"
  sed -i '' "$sed_range" "$FROM_FILE"

  # Remove any resulting double blank lines at the deletion point
  # Use a simple pass to collapse multiple blank lines
  sed -i '' '/^$/N;/^\n$/d' "$FROM_FILE"

  # 10c. Add re-export statement in the source file
  # Find the right place to insert it (after existing imports, or at end of file)
  last_import_line=0
  source_total=$(wc -l < "$FROM_FILE" | tr -d ' ')
  for (( i = 1; i <= source_total; i++ )); do
    line_text=$(get_line "$FROM_FILE" "$i")
    case "$LANG" in
      typescript)
        echo "$line_text" | grep -qE '^\s*(import|export\s+\{.*\}\s+from)' && last_import_line="$i"
        ;;
      python)
        echo "$line_text" | grep -qE '^\s*(import |from )' && last_import_line="$i"
        ;;
      java)
        echo "$line_text" | grep -qE '^\s*import ' && last_import_line="$i"
        ;;
    esac
  done

  if [ "$last_import_line" -gt 0 ]; then
    insert_at=$((last_import_line + 1))
    # Use sed to insert after the last import line
    sed -i '' "${last_import_line}a\\
${REEXPORT_STMT}
" "$FROM_FILE"
  else
    # No imports found; add at the top of the file (after any shebang/package line)
    case "$LANG" in
      python)
        # Insert after shebang or encoding comment if present
        first_code_line=1
        head_line=$(get_line "$FROM_FILE" 1)
        if echo "$head_line" | grep -qE '^#'; then
          first_code_line=2
        fi
        sed -i '' "${first_code_line}i\\
${REEXPORT_STMT}
" "$FROM_FILE"
        ;;
      java)
        # Insert after package declaration if present
        pkg_line=$(rg -n '^\s*package ' "$FROM_FILE" 2>/dev/null | head -1 | cut -d: -f1)
        insert_at="${pkg_line:-1}"
        sed -i '' "${insert_at}a\\
${REEXPORT_STMT}
" "$FROM_FILE"
        ;;
      *)
        sed -i '' "1i\\
${REEXPORT_STMT}
" "$FROM_FILE"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  updated_json="[]"
  if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    updated_json=$(printf '%s\n' "${UPDATED_FILES[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  fi

  jq -n \
    --arg symbol "$SYMBOL" \
    --arg from "$FROM_FILE" \
    --arg to "$TO_FILE" \
    --argjson startLine "$BLOCK_START" \
    --argjson endLine "$BLOCK_END" \
    --argjson depImports "${#UNIQUE_DEP_IMPORTS[@]}" \
    --argjson updatedFiles "$updated_json" \
    --arg dryRun "$DRY_RUN" \
    '{
      symbol: $symbol,
      from: $from,
      to: $to,
      extractedLines: {start: $startLine, end: $endLine},
      dependencyImports: $depImports,
      updatedFiles: $updatedFiles,
      dryRun: ($dryRun == "true")
    }'
else
  echo "=== Move Symbol '$SYMBOL' ==="
  echo "From: $FROM_FILE"
  echo "To:   $TO_FILE"
  echo ""
  echo "Extracted: lines ${BLOCK_START}-${BLOCK_END} ($SYMBOL_TYPE definition)"
  echo "Dependencies: ${#UNIQUE_DEP_IMPORTS[@]} imports copied to target"
  echo "Updated imports: ${#UPDATED_FILES[@]} files"
  for ref in ${UPDATED_FILES[@]+"${UPDATED_FILES[@]}"}; do
    echo "  $ref"
  done
  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "STATUS: DRY RUN"
  else
    echo "STATUS: OK"
  fi
fi
