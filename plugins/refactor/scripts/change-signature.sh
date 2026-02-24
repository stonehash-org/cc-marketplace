#!/usr/bin/env bash
# change-signature.sh
# Change a function's signature (parameters) and update all call sites.
#
# Usage:
#   change-signature.sh --symbol FUNC_NAME --path DIR \
#     [--add-param "name:type=default"] \
#     [--remove-param "name"] \
#     [--rename-param "old:new"] \
#     [--reorder-params "name1,name2,name3"] \
#     [--dry-run] [--format text|json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

# shellcheck source=./shared-lib.sh
source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SYMBOL=""
SEARCH_PATH="."
DRY_RUN=false
FORMAT="text"

ADD_PARAMS=()
REMOVE_PARAMS=()
RENAME_PARAMS=()
REORDER_PARAMS=""

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol FUNC_NAME --path DIR [options]

Change a function's signature and update all call sites.

Options:
  --symbol NAME              Function name (required)
  --path DIR                 Directory to search in (default: .)
  --add-param "name:type=default"   Add a new parameter
  --remove-param "name"      Remove a parameter
  --rename-param "old:new"   Rename a parameter
  --reorder-params "a,b,c"   Reorder parameters
  --dry-run                  Show what would change without modifying files
  --format FMT               Output format: text or json (default: text)
  -h, --help                 Show this help

Examples:
  $(basename "$0") --symbol processData --path ./src --add-param "timeout:number=5000"
  $(basename "$0") --symbol handleRequest --path . --remove-param "legacy" --dry-run
  $(basename "$0") --symbol calculate --path ./src --rename-param "opts:config"
  $(basename "$0") --symbol render --path . --reorder-params "ctx,data,options" --format json
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol)         SYMBOL="$2"; shift 2 ;;
    --path)           SEARCH_PATH="$2"; shift 2 ;;
    --add-param)      ADD_PARAMS+=("$2"); shift 2 ;;
    --remove-param)   REMOVE_PARAMS+=("$2"); shift 2 ;;
    --rename-param)   RENAME_PARAMS+=("$2"); shift 2 ;;
    --reorder-params) REORDER_PARAMS="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --format)         FORMAT="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -z "$SYMBOL" ]; then
  echo "Error: --symbol is required" >&2
  exit 1
fi

if [ ${#ADD_PARAMS[@]} -eq 0 ] && [ ${#REMOVE_PARAMS[@]} -eq 0 ] && \
   [ ${#RENAME_PARAMS[@]} -eq 0 ] && [ -z "$REORDER_PARAMS" ]; then
  echo "Error: At least one operation is required (--add-param, --remove-param, --rename-param, --reorder-params)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Find function definition using symbols.scm
# ---------------------------------------------------------------------------
DEF_FILE=""
DEF_LINE=0
DEF_LANG=""

CANDIDATES=$(eval rg -l --fixed-strings '"$SYMBOL"' '"$SEARCH_PATH"' \
  $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)

if [ -z "$CANDIDATES" ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '{"symbol":"'"$SYMBOL"'","error":"No files contain this symbol","dryRun":'"$DRY_RUN"'}'
  else
    echo "Error: No files containing '$SYMBOL' found in $SEARCH_PATH" >&2
  fi
  exit 1
fi

# Search for @symbol.definition matching the function name
while IFS= read -r file; do
  [ -z "$file" ] && continue
  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  query_file=$(get_query_file "$lang" "symbols")
  [ ! -f "$query_file" ] && continue

  ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    local_capture="" local_row="" local_col="" local_text=""
    if [[ "$line" =~ $re_v026 ]]; then
      local_capture="${BASH_REMATCH[1]}"
      local_row="${BASH_REMATCH[2]}"
      local_col="${BASH_REMATCH[3]}"
      local_text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      local_capture="${BASH_REMATCH[1]}"
      local_row="${BASH_REMATCH[2]}"
      local_col="${BASH_REMATCH[3]}"
      local_text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
      local_capture="${BASH_REMATCH[1]}"
      local_text="${BASH_REMATCH[2]}"
      local_row="${BASH_REMATCH[3]}"
      local_col="${BASH_REMATCH[4]}"
    else
      continue
    fi

    if [ "$local_capture" = "symbol.definition" ] && [ "$local_text" = "$SYMBOL" ]; then
      # Verify it is a function/method definition
      check_line=$((local_row + 1))
      line_content=$(get_line "$file" "$check_line")
      sym_type=$(classify_symbol "$lang" "$line_content")
      if [ "$sym_type" = "function" ]; then
        DEF_FILE="$file"
        DEF_LINE="$check_line"
        DEF_LANG="$lang"
        break 2
      fi
    fi
  done <<< "$ts_output"
done <<< "$CANDIDATES"

if [ -z "$DEF_FILE" ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '{"symbol":"'"$SYMBOL"'","error":"Function definition not found","dryRun":'"$DRY_RUN"'}'
  else
    echo "Error: Function definition for '$SYMBOL' not found" >&2
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Parse the function's parameter list from the source code
# ---------------------------------------------------------------------------
DEF_LINE_CONTENT=$(get_line "$DEF_FILE" "$DEF_LINE")

# Extract the parameter text between the first ( and the matching )
# Handle multi-line parameter lists by reading subsequent lines if needed
FULL_DEF="$DEF_LINE_CONTENT"
OPEN_PARENS=0
CLOSE_PARENS=0
EXTRA_LINES=0

# Count parens in current line
count_line="$FULL_DEF"
while [[ "$count_line" == *"("* ]]; do
  OPEN_PARENS=$((OPEN_PARENS + 1))
  count_line="${count_line#*\(}"
done
count_line="$FULL_DEF"
while [[ "$count_line" == *")"* ]]; do
  CLOSE_PARENS=$((CLOSE_PARENS + 1))
  count_line="${count_line#*\)}"
done

# Read additional lines if parentheses are unbalanced
while [ "$OPEN_PARENS" -gt "$CLOSE_PARENS" ]; do
  EXTRA_LINES=$((EXTRA_LINES + 1))
  next_line=$(get_line "$DEF_FILE" "$((DEF_LINE + EXTRA_LINES))")
  FULL_DEF="$FULL_DEF
$next_line"
  count_line="$next_line"
  while [[ "$count_line" == *"("* ]]; do
    OPEN_PARENS=$((OPEN_PARENS + 1))
    count_line="${count_line#*\(}"
  done
  count_line="$next_line"
  while [[ "$count_line" == *")"* ]]; do
    CLOSE_PARENS=$((CLOSE_PARENS + 1))
    count_line="${count_line#*\)}"
  done
done

# Extract content between the first ( and its matching )
PARAM_TEXT=""
extract_params() {
  local input="$1"
  local depth=0
  local started=false
  local result=""
  local i=0
  local len=${#input}

  while [ "$i" -lt "$len" ]; do
    local ch="${input:$i:1}"
    if [ "$ch" = "(" ] && [ "$started" = false ]; then
      started=true
      depth=1
    elif [ "$ch" = "(" ] && [ "$started" = true ]; then
      depth=$((depth + 1))
      result="$result$ch"
    elif [ "$ch" = ")" ] && [ "$started" = true ]; then
      depth=$((depth - 1))
      if [ "$depth" -eq 0 ]; then
        break
      fi
      result="$result$ch"
    elif [ "$started" = true ]; then
      result="$result$ch"
    fi
    i=$((i + 1))
  done
  echo "$result"
}

PARAM_TEXT=$(extract_params "$FULL_DEF")

# Split parameters by comma (respecting nested parens/brackets)
split_params() {
  local input="$1"
  local depth=0
  local current=""
  local i=0
  local len=${#input}

  while [ "$i" -lt "$len" ]; do
    local ch="${input:$i:1}"
    if [ "$ch" = "," ] && [ "$depth" -eq 0 ]; then
      # Trim whitespace
      current=$(echo "$current" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$current" ] && echo "$current"
      current=""
    elif [ "$ch" = "(" ] || [ "$ch" = "[" ] || [ "$ch" = "{" ]; then
      depth=$((depth + 1))
      current="$current$ch"
    elif [ "$ch" = ")" ] || [ "$ch" = "]" ] || [ "$ch" = "}" ]; then
      depth=$((depth - 1))
      current="$current$ch"
    else
      current="$current$ch"
    fi
    i=$((i + 1))
  done
  current=$(echo "$current" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$current" ] && echo "$current"
}

OLD_PARAMS=()
while IFS= read -r p; do
  [ -n "$p" ] && OLD_PARAMS+=("$p")
done < <(split_params "$PARAM_TEXT")

# Extract just the parameter names (strip type annotations, defaults)
extract_param_name() {
  local param="$1"
  local lang="$2"
  local name=""

  case "$lang" in
    typescript)
      # e.g., "data: string", "options?: Config", "callback = noop"
      name=$(echo "$param" | sed 's/[?:=].*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      ;;
    python)
      # e.g., "data", "options: dict = None", "*args", "**kwargs", "self"
      name=$(echo "$param" | sed 's/[:=].*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      name=$(echo "$name" | sed 's/^\*\*//' | sed 's/^\*//')
      ;;
    java)
      # e.g., "String data", "int count", "final Config options"
      # Take the last word as the name
      name=$(echo "$param" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '{print $NF}')
      ;;
  esac
  echo "$name"
}

OLD_PARAM_NAMES=()
for p in "${OLD_PARAMS[@]+"${OLD_PARAMS[@]}"}"; do
  pname=$(extract_param_name "$p" "$DEF_LANG")
  OLD_PARAM_NAMES+=("$pname")
done

# ---------------------------------------------------------------------------
# Step 3: Apply requested changes to the parameter list
# ---------------------------------------------------------------------------
NEW_PARAMS=("${OLD_PARAMS[@]+"${OLD_PARAMS[@]}"}")
NEW_PARAM_NAMES=("${OLD_PARAM_NAMES[@]+"${OLD_PARAM_NAMES[@]}"}")

# Track changes for reporting
CHANGES_DESC=()

# --- 3a: --add-param "name:type=default" ---
for add_spec in "${ADD_PARAMS[@]+"${ADD_PARAMS[@]}"}"; do
  [ -z "$add_spec" ] && continue

  add_name=""
  add_type=""
  add_default=""

  # Parse the spec: name:type=default
  remainder="$add_spec"
  if [[ "$remainder" == *"="* ]]; then
    add_default="${remainder##*=}"
    remainder="${remainder%=*}"
  fi
  if [[ "$remainder" == *":"* ]]; then
    add_name="${remainder%%:*}"
    add_type="${remainder#*:}"
  else
    add_name="$remainder"
  fi

  # Build the full parameter string based on language
  new_param=""
  case "$DEF_LANG" in
    typescript)
      if [ -n "$add_type" ] && [ -n "$add_default" ]; then
        new_param="$add_name: $add_type = $add_default"
      elif [ -n "$add_type" ]; then
        new_param="$add_name: $add_type"
      elif [ -n "$add_default" ]; then
        new_param="$add_name = $add_default"
      else
        new_param="$add_name"
      fi
      ;;
    python)
      if [ -n "$add_type" ] && [ -n "$add_default" ]; then
        new_param="$add_name: $add_type = $add_default"
      elif [ -n "$add_type" ]; then
        new_param="$add_name: $add_type"
      elif [ -n "$add_default" ]; then
        new_param="$add_name = $add_default"
      else
        new_param="$add_name"
      fi
      ;;
    java)
      if [ -n "$add_type" ]; then
        new_param="$add_type $add_name"
      else
        new_param="Object $add_name"
      fi
      ;;
  esac

  NEW_PARAMS+=("$new_param")
  NEW_PARAM_NAMES+=("$add_name")
  CHANGES_DESC+=("add parameter '$add_name'")
done

# --- 3b: --remove-param "name" ---
for rm_name in "${REMOVE_PARAMS[@]+"${REMOVE_PARAMS[@]}"}"; do
  [ -z "$rm_name" ] && continue

  FILTERED_PARAMS=()
  FILTERED_NAMES=()
  found=false
  for i in "${!NEW_PARAMS[@]}"; do
    if [ "${NEW_PARAM_NAMES[$i]}" = "$rm_name" ] && [ "$found" = false ]; then
      found=true
      continue
    fi
    FILTERED_PARAMS+=("${NEW_PARAMS[$i]}")
    FILTERED_NAMES+=("${NEW_PARAM_NAMES[$i]}")
  done

  if [ "$found" = true ]; then
    NEW_PARAMS=("${FILTERED_PARAMS[@]+"${FILTERED_PARAMS[@]}"}")
    NEW_PARAM_NAMES=("${FILTERED_NAMES[@]+"${FILTERED_NAMES[@]}"}")
    CHANGES_DESC+=("remove parameter '$rm_name'")
  else
    echo "Warning: Parameter '$rm_name' not found in signature" >&2
  fi
done

# --- 3c: --rename-param "old:new" ---
for rn_spec in "${RENAME_PARAMS[@]+"${RENAME_PARAMS[@]}"}"; do
  [ -z "$rn_spec" ] && continue

  rn_old="${rn_spec%%:*}"
  rn_new="${rn_spec#*:}"

  found=false
  for i in "${!NEW_PARAM_NAMES[@]}"; do
    if [ "${NEW_PARAM_NAMES[$i]}" = "$rn_old" ]; then
      # Replace the old name in the full parameter string
      NEW_PARAMS[$i]=$(echo "${NEW_PARAMS[$i]}" | sed "s/\b${rn_old}\b/${rn_new}/")
      NEW_PARAM_NAMES[$i]="$rn_new"
      found=true
      break
    fi
  done

  if [ "$found" = true ]; then
    CHANGES_DESC+=("rename parameter '$rn_old' -> '$rn_new'")
  else
    echo "Warning: Parameter '$rn_old' not found for renaming" >&2
  fi
done

# --- 3d: --reorder-params "a,b,c" ---
if [ -n "$REORDER_PARAMS" ]; then
  IFS=',' read -ra REORDER_LIST <<< "$REORDER_PARAMS"

  REORDERED_PARAMS=()
  REORDERED_NAMES=()

  for rname in "${REORDER_LIST[@]}"; do
    rname=$(echo "$rname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    found=false
    for i in "${!NEW_PARAM_NAMES[@]}"; do
      if [ "${NEW_PARAM_NAMES[$i]}" = "$rname" ]; then
        REORDERED_PARAMS+=("${NEW_PARAMS[$i]}")
        REORDERED_NAMES+=("$rname")
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      echo "Warning: Parameter '$rname' not found for reordering" >&2
    fi
  done

  # Append any params not mentioned in the reorder list
  for i in "${!NEW_PARAM_NAMES[@]}"; do
    in_list=false
    for rname in "${REORDER_LIST[@]}"; do
      rname=$(echo "$rname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ "${NEW_PARAM_NAMES[$i]}" = "$rname" ]; then
        in_list=true
        break
      fi
    done
    if [ "$in_list" = false ]; then
      REORDERED_PARAMS+=("${NEW_PARAMS[$i]}")
      REORDERED_NAMES+=("${NEW_PARAM_NAMES[$i]}")
    fi
  done

  NEW_PARAMS=("${REORDERED_PARAMS[@]+"${REORDERED_PARAMS[@]}"}")
  NEW_PARAM_NAMES=("${REORDERED_NAMES[@]+"${REORDERED_NAMES[@]}"}")
  CHANGES_DESC+=("reorder parameters to '${REORDER_PARAMS}'")
fi

# ---------------------------------------------------------------------------
# Step 4: Build old and new parameter strings
# ---------------------------------------------------------------------------
OLD_PARAM_STR=""
if [ ${#OLD_PARAMS[@]} -gt 0 ]; then
  OLD_PARAM_STR=$(IFS=', '; echo "${OLD_PARAMS[*]}")
fi

NEW_PARAM_STR=""
if [ ${#NEW_PARAMS[@]} -gt 0 ]; then
  NEW_PARAM_STR=$(IFS=', '; echo "${NEW_PARAMS[*]}")
fi

# Build display names for output
OLD_DISPLAY="$SYMBOL($(IFS=', '; echo "${OLD_PARAM_NAMES[*]+"${OLD_PARAM_NAMES[*]}"}"))"
NEW_DISPLAY="$SYMBOL($(IFS=', '; echo "${NEW_PARAM_NAMES[*]+"${NEW_PARAM_NAMES[*]}"}"))"

# ---------------------------------------------------------------------------
# Step 5: Update the function definition
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = false ]; then
  # Build old and new definition lines
  OLD_PAREN_CONTENT="$PARAM_TEXT"
  NEW_PAREN_CONTENT="$NEW_PARAM_STR"

  if [ "$EXTRA_LINES" -eq 0 ]; then
    # Single-line parameter list: use sed to replace
    # Escape special characters for sed
    escape_sed() {
      echo "$1" | sed 's/[&/\]/\\&/g'
    }
    OLD_ESCAPED=$(escape_sed "$OLD_PAREN_CONTENT")
    NEW_ESCAPED=$(escape_sed "$NEW_PAREN_CONTENT")
    sed -i '' "${DEF_LINE}s/(${OLD_ESCAPED})/(${NEW_ESCAPED})/" "$DEF_FILE"
  else
    # Multi-line: reconstruct the definition line with new params on one line
    # Read the file into an array
    FILE_LINES=()
    while IFS= read -r _fl; do
      FILE_LINES+=("$_fl")
    done < "$DEF_FILE"

    # Get the prefix (everything before the opening paren on the definition line)
    PREFIX="${DEF_LINE_CONTENT%%(*}"
    # Get the suffix from the last line of the definition (everything after the closing paren)
    LAST_DEF_LINE=$((DEF_LINE + EXTRA_LINES))
    LAST_LINE_CONTENT=$(get_line "$DEF_FILE" "$LAST_DEF_LINE")
    SUFFIX="${LAST_LINE_CONTENT#*\)}"

    NEW_DEF_LINE="${PREFIX}(${NEW_PARAM_STR})${SUFFIX}"

    # Write: lines before def, new def line, lines after multi-line def
    {
      for (( i = 0; i < DEF_LINE - 1; i++ )); do
        printf '%s\n' "${FILE_LINES[$i]}"
      done
      printf '%s\n' "$NEW_DEF_LINE"
      for (( i = LAST_DEF_LINE; i < ${#FILE_LINES[@]}; i++ )); do
        printf '%s\n' "${FILE_LINES[$i]}"
      done
    } > "$DEF_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Find all call sites using call-arguments.scm
# ---------------------------------------------------------------------------
CALL_SITES=()
CALL_SITES_UPDATED=0

# Build the positional index mapping from old to new
# For each old param position, determine what happens:
#   - removed: mark for removal
#   - renamed: no call-site change needed (positional args stay the same)
#   - reordered: need to rearrange arguments

# Compute the old-to-new position mapping for reorder
build_position_map() {
  # For each new param name, find its original position in OLD_PARAM_NAMES
  local i=0
  for nname in "${NEW_PARAM_NAMES[@]+"${NEW_PARAM_NAMES[@]}"}"; do
    local j=0
    local found=false
    for oname in "${OLD_PARAM_NAMES[@]+"${OLD_PARAM_NAMES[@]}"}"; do
      if [ "$oname" = "$nname" ]; then
        echo "$j"
        found=true
        break
      fi
      j=$((j + 1))
    done
    # If not found (it is a new param), output -1
    if [ "$found" = false ]; then
      echo "-1"
    fi
    i=$((i + 1))
  done
}

POSITION_MAP=()
while IFS= read -r pos; do
  POSITION_MAP+=("$pos")
done < <(build_position_map)

# Determine which old positions are removed
REMOVED_POSITIONS=()
for rm_name in "${REMOVE_PARAMS[@]+"${REMOVE_PARAMS[@]}"}"; do
  [ -z "$rm_name" ] && continue
  for i in "${!OLD_PARAM_NAMES[@]}"; do
    if [ "${OLD_PARAM_NAMES[$i]}" = "$rm_name" ]; then
      REMOVED_POSITIONS+=("$i")
    fi
  done
done

# Find default values for added params
ADD_DEFAULTS=()
for add_spec in "${ADD_PARAMS[@]+"${ADD_PARAMS[@]}"}"; do
  [ -z "$add_spec" ] && continue
  if [[ "$add_spec" == *"="* ]]; then
    ADD_DEFAULTS+=("${add_spec##*=}")
  else
    ADD_DEFAULTS+=("")
  fi
done

# Search all candidate files for call sites
CALL_CANDIDATES=$(eval rg -l --fixed-strings '"$SYMBOL"' '"$SEARCH_PATH"' \
  $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)

while IFS= read -r file; do
  [ -z "$file" ] && continue
  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  call_query=$(get_query_file "$lang" "call-arguments")
  [ ! -f "$call_query" ] && continue

  ts_output=$(tree-sitter query "$call_query" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  # Parse call captures: pairs of call.name and call.arguments
  PENDING_CALL_NAME=""
  PENDING_CALL_ROW=""

  re_v026_call='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
  while IFS= read -r line; do
    c_capture="" c_row="" c_col="" c_text=""
    if [[ "$line" =~ $re_v026_call ]]; then
      c_capture="${BASH_REMATCH[1]}"
      c_row="${BASH_REMATCH[2]}"
      c_col="${BASH_REMATCH[3]}"
      c_text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ @([a-z_.]+)[[:space:]]+\(([0-9]+),\ ([0-9]+)\).*\`([^\`]+)\` ]]; then
      c_capture="${BASH_REMATCH[1]}"
      c_row="${BASH_REMATCH[2]}"
      c_col="${BASH_REMATCH[3]}"
      c_text="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
      c_capture="${BASH_REMATCH[1]}"
      c_text="${BASH_REMATCH[2]}"
      c_row="${BASH_REMATCH[3]}"
      c_col="${BASH_REMATCH[4]}"
    else
      continue
    fi

    if [ "$c_capture" = "call.name" ] && [ "$c_text" = "$SYMBOL" ]; then
      PENDING_CALL_NAME="$c_text"
      PENDING_CALL_ROW="$c_row"
    elif [ "$c_capture" = "call.name" ] && [ "$c_text" != "$SYMBOL" ]; then
      PENDING_CALL_NAME=""
      PENDING_CALL_ROW=""
    elif [ "$c_capture" = "call.arguments" ] && [ -n "$PENDING_CALL_NAME" ]; then
      call_line=$((PENDING_CALL_ROW + 1))
      args_text="$c_text"

      # Strip the surrounding parentheses from arguments text
      args_inner=$(echo "$args_text" | sed 's/^(//;s/)$//')

      # Split arguments
      OLD_ARGS=()
      while IFS= read -r a; do
        [ -n "$a" ] && OLD_ARGS+=("$a")
      done < <(split_params "$args_inner")

      # Build new argument list
      NEW_ARGS=()
      needs_update=false

      # Check if we need to do anything
      has_removes=${#REMOVED_POSITIONS[@]}
      has_adds=${#ADD_PARAMS[@]}
      has_reorder=false
      if [ -n "$REORDER_PARAMS" ]; then
        has_reorder=true
      fi

      if [ "$has_removes" -gt 0 ] || [ "$has_adds" -gt 0 ] || [ "$has_reorder" = true ]; then
        needs_update=true
      fi

      if [ "$needs_update" = true ]; then
        # Start with old args, removing the ones marked for removal
        KEPT_ARGS=()
        KEPT_NAMES=()
        for i in "${!OLD_ARGS[@]}"; do
          is_removed=false
          for rp in "${REMOVED_POSITIONS[@]+"${REMOVED_POSITIONS[@]}"}"; do
            if [ "$i" -eq "$rp" ]; then
              is_removed=true
              break
            fi
          done
          if [ "$is_removed" = false ]; then
            KEPT_ARGS+=("${OLD_ARGS[$i]}")
            # Map this position to the param name if possible
            if [ "$i" -lt "${#OLD_PARAM_NAMES[@]}" ]; then
              KEPT_NAMES+=("${OLD_PARAM_NAMES[$i]}")
            else
              KEPT_NAMES+=("_unknown_$i")
            fi
          fi
        done

        # Handle reorder: rearrange KEPT_ARGS based on the new param name order
        # (excluding added params which come at the end)
        if [ "$has_reorder" = true ]; then
          REORDERED_ARGS=()
          IFS=',' read -ra REORDER_TARGET <<< "$REORDER_PARAMS"
          for rname in "${REORDER_TARGET[@]}"; do
            rname=$(echo "$rname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Find this name in KEPT_NAMES
            found=false
            for ki in "${!KEPT_NAMES[@]}"; do
              if [ "${KEPT_NAMES[$ki]}" = "$rname" ]; then
                REORDERED_ARGS+=("${KEPT_ARGS[$ki]}")
                found=true
                break
              fi
            done
            if [ "$found" = false ]; then
              # Could be a new param; skip for now
              :
            fi
          done
          # Append any args not in the reorder list
          for ki in "${!KEPT_NAMES[@]}"; do
            in_reorder=false
            for rname in "${REORDER_TARGET[@]}"; do
              rname=$(echo "$rname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
              if [ "${KEPT_NAMES[$ki]}" = "$rname" ]; then
                in_reorder=true
                break
              fi
            done
            if [ "$in_reorder" = false ]; then
              REORDERED_ARGS+=("${KEPT_ARGS[$ki]}")
            fi
          done
          NEW_ARGS=("${REORDERED_ARGS[@]+"${REORDERED_ARGS[@]}"}")
        else
          NEW_ARGS=("${KEPT_ARGS[@]+"${KEPT_ARGS[@]}"}")
        fi

        # Append default values for added params
        for default_val in "${ADD_DEFAULTS[@]+"${ADD_DEFAULTS[@]}"}"; do
          if [ -n "$default_val" ]; then
            NEW_ARGS+=("$default_val")
          fi
        done

        # Build new arguments string
        NEW_ARGS_STR=""
        if [ ${#NEW_ARGS[@]} -gt 0 ]; then
          NEW_ARGS_STR=$(IFS=', '; echo "${NEW_ARGS[*]}")
        fi

        # Build old arguments string for replacement
        OLD_ARGS_STR=""
        if [ ${#OLD_ARGS[@]} -gt 0 ]; then
          OLD_ARGS_STR=$(IFS=', '; echo "${OLD_ARGS[*]}")
        fi

        CALL_SITES+=("$file:$call_line")
        CALL_SITES_UPDATED=$((CALL_SITES_UPDATED + 1))

        if [ "$DRY_RUN" = false ]; then
          # Replace the arguments on the call-site line
          # Use the full args_text (with parens) for precise matching
          escape_sed_pattern() {
            echo "$1" | sed 's/[[\.*^$()+?{|]/\\&/g'
          }
          escape_sed_replace() {
            echo "$1" | sed 's/[&/\]/\\&/g'
          }

          OLD_CALL_ESCAPED=$(escape_sed_pattern "($OLD_ARGS_STR)")
          NEW_CALL_ESCAPED=$(escape_sed_replace "($NEW_ARGS_STR)")

          sed -i '' "${call_line}s/${OLD_CALL_ESCAPED}/${NEW_CALL_ESCAPED}/" "$file"
        fi
      fi

      # Handle Python named arguments for --rename-param
      if [ "$lang" = "python" ] && [ ${#RENAME_PARAMS[@]} -gt 0 ]; then
        for rn_spec in "${RENAME_PARAMS[@]}"; do
          rn_old="${rn_spec%%:*}"
          rn_new="${rn_spec#*:}"
          # Check if any argument uses the named keyword style: old_name=value
          if echo "$args_inner" | grep -q "\b${rn_old}[[:space:]]*="; then
            if [ "$DRY_RUN" = false ]; then
              sed -i '' "${call_line}s/\b${rn_old}\([[:space:]]*=\)/${rn_new}\1/" "$file"
            fi
            # Only add to call sites if not already counted
            already_counted=false
            for cs in "${CALL_SITES[@]+"${CALL_SITES[@]}"}"; do
              if [ "$cs" = "$file:$call_line" ]; then
                already_counted=true
                break
              fi
            done
            if [ "$already_counted" = false ]; then
              CALL_SITES+=("$file:$call_line")
              CALL_SITES_UPDATED=$((CALL_SITES_UPDATED + 1))
            fi
          fi
        done
      fi

      PENDING_CALL_NAME=""
      PENDING_CALL_ROW=""
    fi
  done <<< "$ts_output"
done <<< "$CALL_CANDIDATES"

# ---------------------------------------------------------------------------
# Step 7: Output
# ---------------------------------------------------------------------------
STATUS="OK"
if [ "$DRY_RUN" = true ]; then
  STATUS="DRY RUN"
fi

if [ "$FORMAT" = "json" ]; then
  old_params_json=$(printf '%s\n' "${OLD_PARAM_NAMES[@]+"${OLD_PARAM_NAMES[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  new_params_json=$(printf '%s\n' "${NEW_PARAM_NAMES[@]+"${NEW_PARAM_NAMES[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  call_sites_json=$(printf '%s\n' "${CALL_SITES[@]+"${CALL_SITES[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  changes_json=$(printf '%s\n' "${CHANGES_DESC[@]+"${CHANGES_DESC[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg sym "$SYMBOL" \
    --arg def_file "$DEF_FILE" \
    --argjson def_line "$DEF_LINE" \
    --argjson old_params "$old_params_json" \
    --argjson new_params "$new_params_json" \
    --argjson call_sites_updated "$CALL_SITES_UPDATED" \
    --argjson call_sites "$call_sites_json" \
    --argjson changes "$changes_json" \
    --argjson dry_run "$DRY_RUN" \
    '{
      symbol: $sym,
      definition: {file: $def_file, line: $def_line},
      oldParams: $old_params,
      newParams: $new_params,
      callSitesUpdated: $call_sites_updated,
      callSites: $call_sites,
      changes: $changes,
      dryRun: $dry_run
    }'
else
  echo "=== Change Signature: $SYMBOL ==="
  echo ""
  echo "Definition: $DEF_FILE:$DEF_LINE"
  echo "  Old: $OLD_DISPLAY"
  echo "  New: $NEW_DISPLAY"
  echo ""
  echo "Call sites updated: $CALL_SITES_UPDATED"
  for cs in "${CALL_SITES[@]+"${CALL_SITES[@]}"}"; do
    echo "  $cs"
  done
  echo ""
  echo "STATUS: $STATUS"
fi
