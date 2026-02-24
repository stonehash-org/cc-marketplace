#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# type-hierarchy.sh
# Type hierarchy explorer using tree-sitter inheritance queries.
# Read-only analysis — no files are modified.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

usage() {
  local exit_code="${1:-0}"
  cat <<EOF
Usage: $SCRIPT_NAME --symbol CLASS_NAME --path DIR [--format text|mermaid|json] [--direction up|down|both]

Options:
  --symbol NAME       Class or interface name to inspect (required)
  --path DIR          Root directory to scan (required)
  --format FORMAT     Output format: text (default), mermaid, json
  --direction DIR     Traversal direction: up, down, both (default)
  -h, --help          Show this help message

Examples:
  $SCRIPT_NAME --symbol UserService --path ./src
  $SCRIPT_NAME --symbol UserService --path ./src --format mermaid
  $SCRIPT_NAME --symbol BaseModel --path ./src --direction up --format json
EOF
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SYMBOL=""
PATH_DIR=""
FORMAT="text"
DIRECTION="both"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol)
      SYMBOL="${2:-}"
      shift 2
      ;;
    --path)
      PATH_DIR="${2:-}"
      shift 2
      ;;
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --direction)
      DIRECTION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
  esac
done

if [[ -z "$SYMBOL" ]]; then
  echo "Error: --symbol is required." >&2
  usage 1
fi

if [[ -z "$PATH_DIR" ]]; then
  echo "Error: --path is required." >&2
  usage 1
fi

if [[ ! -d "$PATH_DIR" ]]; then
  echo "Error: '$PATH_DIR' is not a directory or does not exist." >&2
  exit 1
fi

case "$FORMAT" in
  text|mermaid|json) ;;
  *)
    echo "Error: --format must be one of: text, mermaid, json" >&2
    usage 1
    ;;
esac

case "$DIRECTION" in
  up|down|both) ;;
  *)
    echo "Error: --direction must be one of: up, down, both" >&2
    usage 1
    ;;
esac

if ! command -v rg &>/dev/null; then
  echo "Error: ripgrep (rg) is required but not found in PATH." >&2
  exit 1
fi

if ! command -v tree-sitter &>/dev/null; then
  echo "Error: tree-sitter CLI is required but not found in PATH." >&2
  exit 1
fi

# Resolve path to absolute
PATH_DIR="$(cd "$PATH_DIR" && pwd)"

# ---------------------------------------------------------------------------
# Hierarchy data (bash 3.2 compatible — parallel arrays with eval)
#
#   CLASS_COUNT           — number of classes recorded
#   CLASS_NAME_$i         — class/interface name
#   CLASS_FILE_$i         — file:line location
#   CLASS_EXTENDS_$i      — parent class name (or "")
#   CLASS_IMPLEMENTS_$i   — space-separated interface names (or "")
# ---------------------------------------------------------------------------
CLASS_COUNT=0

add_class_record() {
  local name="$1"
  local file_loc="$2"
  local extends_name="$3"
  local implements_list="$4"

  # Check if we already have this class; if so, merge
  local i
  for (( i=0; i<CLASS_COUNT; i++ )); do
    local existing_name
    eval "existing_name=\"\$CLASS_NAME_${i}\""
    if [[ "$existing_name" = "$name" ]]; then
      # Merge extends if not set
      local cur_extends
      eval "cur_extends=\"\$CLASS_EXTENDS_${i}\""
      if [[ -z "$cur_extends" && -n "$extends_name" ]]; then
        eval "CLASS_EXTENDS_${i}=\"\$extends_name\""
      fi
      # Merge implements
      if [[ -n "$implements_list" ]]; then
        local cur_impl
        eval "cur_impl=\"\$CLASS_IMPLEMENTS_${i}\""
        if [[ -z "$cur_impl" ]]; then
          eval "CLASS_IMPLEMENTS_${i}=\"\$implements_list\""
        else
          eval "CLASS_IMPLEMENTS_${i}=\"\${cur_impl} \${implements_list}\""
        fi
      fi
      return
    fi
  done

  eval "CLASS_NAME_${CLASS_COUNT}=\"\$name\""
  eval "CLASS_FILE_${CLASS_COUNT}=\"\$file_loc\""
  eval "CLASS_EXTENDS_${CLASS_COUNT}=\"\$extends_name\""
  eval "CLASS_IMPLEMENTS_${CLASS_COUNT}=\"\$implements_list\""
  CLASS_COUNT=$(( CLASS_COUNT + 1 ))
}

get_class_name()       { eval "echo \"\$CLASS_NAME_${1}\""; }
get_class_file()       { eval "echo \"\$CLASS_FILE_${1}\""; }
get_class_extends()    { eval "echo \"\$CLASS_EXTENDS_${1}\""; }
get_class_implements() { eval "echo \"\$CLASS_IMPLEMENTS_${1}\""; }

# Find index by name; returns "" if not found
find_class_index() {
  local target="$1"
  local i
  for (( i=0; i<CLASS_COUNT; i++ )); do
    local n
    eval "n=\"\$CLASS_NAME_${i}\""
    if [[ "$n" = "$target" ]]; then
      echo "$i"
      return
    fi
  done
  echo ""
}

# Relative path from PATH_DIR for display
rel() {
  echo "${1#"${PATH_DIR}/"}"
}

# ---------------------------------------------------------------------------
# Scan files and build hierarchy data
# ---------------------------------------------------------------------------
scan_files() {
  local files
  files="$(find_source_files "$PATH_DIR")"

  if [[ -z "$files" ]]; then
    echo "Warning: No source files found in '$PATH_DIR'." >&2
    return
  fi

  while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue

    local lang
    lang="$(detect_language "$src_file")"
    [[ -z "$lang" ]] && continue

    local query_file="$QUERIES_DIR/$lang/inheritance.scm"
    [[ ! -f "$query_file" ]] && continue

    local query_output
    query_output="$(run_query "$query_file" "$src_file")" || continue
    [[ -z "$query_output" ]] && continue

    local rel_file
    rel_file="$(rel "$src_file")"

    # Parse query output — group captures by proximity (same row range)
    # Each line: capture\trow\tcol\ttext
    local current_class=""
    local current_row=""
    local current_file_loc=""
    local current_extends=""
    local current_implements=""

    while IFS=$'\t' read -r capture row col text; do
      [[ -z "$capture" ]] && continue

      case "$capture" in
        class.name|interface.name)
          # Flush previous class if any
          if [[ -n "$current_class" ]]; then
            add_class_record "$current_class" "$current_file_loc" "$current_extends" "$current_implements"
          fi
          current_class="$text"
          current_row="$row"
          local line_num=$(( row + 1 ))
          current_file_loc="${rel_file}:${line_num}"
          current_extends=""
          current_implements=""
          ;;
        class.extends|interface.extends)
          current_extends="$text"
          ;;
        class.implements)
          if [[ -z "$current_implements" ]]; then
            current_implements="$text"
          else
            current_implements="$current_implements $text"
          fi
          ;;
      esac
    done <<< "$query_output"

    # Flush last class
    if [[ -n "$current_class" ]]; then
      add_class_record "$current_class" "$current_file_loc" "$current_extends" "$current_implements"
    fi

  done <<< "$files"
}

# ---------------------------------------------------------------------------
# Traversal: find parents (walk up)
# Returns newline-separated names in order from immediate parent to root
# ---------------------------------------------------------------------------
walk_up() {
  local start="$1"
  local visited="$start"
  local current="$start"

  while true; do
    local idx
    idx="$(find_class_index "$current")"
    [[ -z "$idx" ]] && break

    local parent
    parent="$(get_class_extends "$idx")"
    [[ -z "$parent" ]] && break

    # Cycle detection
    if echo "$visited" | grep -qxF "$parent"; then
      break
    fi
    visited="${visited}"$'\n'"${parent}"
    echo "$parent"
    current="$parent"
  done
}

# ---------------------------------------------------------------------------
# Traversal: find children (walk down)
# Returns newline-separated names of direct children
# ---------------------------------------------------------------------------
find_children() {
  local parent_name="$1"
  local i
  for (( i=0; i<CLASS_COUNT; i++ )); do
    local ext
    eval "ext=\"\$CLASS_EXTENDS_${i}\""
    if [[ "$ext" = "$parent_name" ]]; then
      local n
      eval "n=\"\$CLASS_NAME_${i}\""
      echo "$n"
    fi
  done
}

# ---------------------------------------------------------------------------
# Output: text format
# ---------------------------------------------------------------------------
output_text() {
  local sym_idx
  sym_idx="$(find_class_index "$SYMBOL")"

  if [[ -z "$sym_idx" ]]; then
    echo "Error: Symbol '$SYMBOL' not found in scanned files." >&2
    exit 1
  fi

  local sym_file sym_extends sym_implements
  sym_file="$(get_class_file "$sym_idx")"
  sym_extends="$(get_class_extends "$sym_idx")"
  sym_implements="$(get_class_implements "$sym_idx")"

  echo "=== Type Hierarchy for '$SYMBOL' ==="
  echo ""

  # Build the chain for display
  # Collect parents in reverse order (root first)
  local parents=""
  if [[ "$DIRECTION" = "up" || "$DIRECTION" = "both" ]]; then
    parents="$(walk_up "$SYMBOL")"
  fi

  # Reverse parents list so root is first
  local reversed_parents=""
  if [[ -n "$parents" ]]; then
    reversed_parents="$(echo "$parents" | tail -r 2>/dev/null || echo "$parents" | tac 2>/dev/null || {
      # Pure bash fallback for reversing lines
      local _lines=""
      while IFS= read -r _l; do
        _lines="${_l}"$'\n'"${_lines}"
      done <<< "$parents"
      printf '%s' "$_lines"
    })"
  fi

  # Print parent chain
  local indent="  "
  if [[ -n "$reversed_parents" ]]; then
    while IFS= read -r pname; do
      [[ -z "$pname" ]] && continue
      local pidx ploc
      pidx="$(find_class_index "$pname")"
      if [[ -n "$pidx" ]]; then
        ploc="$(get_class_file "$pidx")"
      else
        ploc="(external)"
      fi
      echo "${indent}${pname} (${ploc})"
      indent="${indent}    "
    done <<< "$reversed_parents"
    # Connect to symbol
    local connector
    connector="${indent%    }"
    echo "${connector}└── ${SYMBOL} (${sym_file})"
  else
    echo "${indent}${SYMBOL} (${sym_file})"
  fi

  # Print children
  if [[ "$DIRECTION" = "down" || "$DIRECTION" = "both" ]]; then
    local children
    children="$(find_children "$SYMBOL")"
    if [[ -n "$children" ]]; then
      local child_indent
      if [[ -n "$reversed_parents" ]]; then
        child_indent="${indent}"
      else
        child_indent="${indent}    "
      fi
      local child_list=""
      local child_count=0
      while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        child_count=$(( child_count + 1 ))
        child_list="${child_list}${cname}"$'\n'
      done <<< "$children"

      local printed=0
      while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        printed=$(( printed + 1 ))
        local cidx cloc prefix
        cidx="$(find_class_index "$cname")"
        if [[ -n "$cidx" ]]; then
          cloc="$(get_class_file "$cidx")"
        else
          cloc="(unknown)"
        fi
        if [[ "$printed" -eq "$child_count" ]]; then
          prefix="└──"
        else
          prefix="├──"
        fi
        echo "${child_indent}${prefix} ${cname} (${cloc})"
      done <<< "$child_list"
    fi
  fi

  # Print implements
  if [[ -n "$sym_implements" ]]; then
    echo ""
    # Format as comma-separated list
    local impl_display
    impl_display="$(echo "$sym_implements" | tr ' ' '\n' | sort -u | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')"
    echo "Implements: ${impl_display}"
  fi
}

# ---------------------------------------------------------------------------
# Output: mermaid format
# ---------------------------------------------------------------------------
output_mermaid() {
  local sym_idx
  sym_idx="$(find_class_index "$SYMBOL")"

  if [[ -z "$sym_idx" ]]; then
    echo "Error: Symbol '$SYMBOL' not found in scanned files." >&2
    exit 1
  fi

  local sym_extends sym_implements
  sym_extends="$(get_class_extends "$sym_idx")"
  sym_implements="$(get_class_implements "$sym_idx")"

  echo "classDiagram"

  # Parents (extends chain going up)
  if [[ "$DIRECTION" = "up" || "$DIRECTION" = "both" ]]; then
    if [[ -n "$sym_extends" ]]; then
      echo "  ${sym_extends} <|-- ${SYMBOL}"
      # Continue up the chain
      local parents
      parents="$(walk_up "$SYMBOL")"
      local prev="$sym_extends"
      while IFS= read -r pname; do
        [[ -z "$pname" ]] && continue
        [[ "$pname" = "$sym_extends" ]] && continue
        echo "  ${pname} <|-- ${prev}"
        prev="$pname"
      done <<< "$parents"
    fi
  fi

  # Children (extends going down)
  if [[ "$DIRECTION" = "down" || "$DIRECTION" = "both" ]]; then
    local children
    children="$(find_children "$SYMBOL")"
    if [[ -n "$children" ]]; then
      while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        echo "  ${SYMBOL} <|-- ${cname}"
      done <<< "$children"
    fi
  fi

  # Implements
  if [[ -n "$sym_implements" ]]; then
    local impl
    for impl in $sym_implements; do
      echo "  ${SYMBOL} ..|> ${impl}"
    done
  fi
}

# ---------------------------------------------------------------------------
# Output: json format
# ---------------------------------------------------------------------------
output_json() {
  local sym_idx
  sym_idx="$(find_class_index "$SYMBOL")"

  if [[ -z "$sym_idx" ]]; then
    echo "Error: Symbol '$SYMBOL' not found in scanned files." >&2
    exit 1
  fi

  local sym_file sym_extends sym_implements
  sym_file="$(get_class_file "$sym_idx")"
  sym_extends="$(get_class_extends "$sym_idx")"
  sym_implements="$(get_class_implements "$sym_idx")"

  # Escape for JSON
  json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  }

  # Build implements array
  local impl_json="[]"
  if [[ -n "$sym_implements" ]]; then
    impl_json="["
    local first=true
    local impl
    for impl in $sym_implements; do
      if $first; then
        impl_json+="\"$(json_escape "$impl")\""
        first=false
      else
        impl_json+=", \"$(json_escape "$impl")\""
      fi
    done
    impl_json+="]"
  fi

  # Build children array
  local children_json="["
  local cfirst=true
  if [[ "$DIRECTION" = "down" || "$DIRECTION" = "both" ]]; then
    local children
    children="$(find_children "$SYMBOL")"
    if [[ -n "$children" ]]; then
      while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        local cidx cloc
        cidx="$(find_class_index "$cname")"
        if [[ -n "$cidx" ]]; then
          cloc="$(get_class_file "$cidx")"
        else
          cloc=""
        fi
        if $cfirst; then
          children_json+="{\"name\": \"$(json_escape "$cname")\", \"location\": \"$(json_escape "$cloc")\"}"
          cfirst=false
        else
          children_json+=", {\"name\": \"$(json_escape "$cname")\", \"location\": \"$(json_escape "$cloc")\"}"
        fi
      done <<< "$children"
    fi
  fi
  children_json+="]"

  # Build parents array
  local parents_json="["
  local pfirst=true
  if [[ "$DIRECTION" = "up" || "$DIRECTION" = "both" ]]; then
    local parents
    parents="$(walk_up "$SYMBOL")"
    if [[ -n "$parents" ]]; then
      while IFS= read -r pname; do
        [[ -z "$pname" ]] && continue
        local pidx ploc
        pidx="$(find_class_index "$pname")"
        if [[ -n "$pidx" ]]; then
          ploc="$(get_class_file "$pidx")"
        else
          ploc=""
        fi
        if $pfirst; then
          parents_json+="{\"name\": \"$(json_escape "$pname")\", \"location\": \"$(json_escape "$ploc")\"}"
          pfirst=false
        else
          parents_json+=", {\"name\": \"$(json_escape "$pname")\", \"location\": \"$(json_escape "$ploc")\"}"
        fi
      done <<< "$parents"
    fi
  fi
  parents_json+="]"

  # Emit JSON
  local extends_val="null"
  if [[ -n "$sym_extends" ]]; then
    extends_val="\"$(json_escape "$sym_extends")\""
  fi

  printf '{\n'
  printf '  "symbol": "%s",\n' "$(json_escape "$SYMBOL")"
  printf '  "location": "%s",\n' "$(json_escape "$sym_file")"
  printf '  "extends": %s,\n' "$extends_val"
  printf '  "implements": %s,\n' "$impl_json"
  printf '  "children": %s,\n' "$children_json"
  printf '  "parents": %s\n' "$parents_json"
  printf '}\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  scan_files

  case "$FORMAT" in
    text)    output_text ;;
    mermaid) output_mermaid ;;
    json)    output_json ;;
  esac
}

main
