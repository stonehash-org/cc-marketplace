#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

# ---------------------------------------------------------------------------
# import-map.sh
# Build a file-to-file import adjacency map and detect circular dependencies.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

usage() {
  local exit_code="${1:-0}"
  cat <<EOF
Usage: $SCRIPT_NAME --path DIR [--format json|csv|table] [--filter "src/**"]

Build an adjacency matrix of file dependencies and detect circular imports.

Options:
  --path DIR        Root directory to scan (required)
  --format FORMAT   Output format: table (default), json, csv
  --filter GLOB     Only include files matching glob pattern (e.g. "src/**")
  -h, --help        Show this help message

Examples:
  $SCRIPT_NAME --path ./src
  $SCRIPT_NAME --path ./src --format json
  $SCRIPT_NAME --path ./src --format csv --filter "routes/**"
  $SCRIPT_NAME --path . --filter "src/**" --format table
EOF
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Supported file extensions
# ---------------------------------------------------------------------------
EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PATH_DIR=""
FORMAT="table"
FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      PATH_DIR="${2:-}"
      shift 2
      ;;
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --filter)
      FILTER="${2:-}"
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

if [[ -z "$PATH_DIR" ]]; then
  echo "Error: --path is required." >&2
  usage 1
fi

if [[ ! -d "$PATH_DIR" ]]; then
  echo "Error: '$PATH_DIR' is not a directory or does not exist." >&2
  exit 1
fi

case "$FORMAT" in
  table|json|csv) ;;
  *)
    echo "Error: --format must be one of: table, json, csv" >&2
    usage 1
    ;;
esac

if ! command -v rg &>/dev/null; then
  echo "Error: ripgrep (rg) is required but not found in PATH." >&2
  exit 1
fi

# Resolve path to absolute
PATH_DIR="$(cd "$PATH_DIR" && pwd)"

# ---------------------------------------------------------------------------
# resolve_abspath: portable realpath substitute (macOS bash 3.2 compatible)
# ---------------------------------------------------------------------------
resolve_abspath() {
  local base_dir="$1"
  local rel_path="$2"

  if command -v python3 &>/dev/null; then
    python3 -c "
import os, sys
base = sys.argv[1]
rel  = sys.argv[2]
print(os.path.normpath(os.path.join(base, rel)))
" "$base_dir" "$rel_path" 2>/dev/null && return
  fi

  if command -v python &>/dev/null; then
    python -c "
import os, sys
base = sys.argv[1]
rel  = sys.argv[2]
print(os.path.normpath(os.path.join(base, rel)))
" "$base_dir" "$rel_path" 2>/dev/null && return
  fi

  # Pure-shell fallback
  local _base _name
  _base="$(dirname "$rel_path")"
  _name="$(basename "$rel_path")"
  ( cd "$base_dir" && cd "$_base" && printf '%s/%s' "$(pwd -P)" "$_name" ) 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Collect all source files, respecting --filter
# ---------------------------------------------------------------------------
collect_files() {
  local rg_args=""
  for ext in "${EXTENSIONS[@]}"; do
    rg_args="$rg_args --glob *.$ext"
  done

  if [[ -n "$FILTER" ]]; then
    # shellcheck disable=SC2086
    rg --files $rg_args --glob "$FILTER" "$PATH_DIR" 2>/dev/null | sort || true
  else
    # shellcheck disable=SC2086
    rg --files $rg_args "$PATH_DIR" 2>/dev/null | sort || true
  fi
}

# ---------------------------------------------------------------------------
# extract_imports: given a source file, print one imported path per line
# ---------------------------------------------------------------------------
extract_imports() {
  local src_file="$1"
  local lang
  lang="$(detect_language "$src_file")"

  case "$lang" in
    typescript)
      # Match:
      #   import ... from 'PATH' / "PATH"
      #   import 'PATH' / "PATH"
      #   require('PATH') / require("PATH")
      #   export ... from 'PATH' / "PATH"
      rg --no-filename --no-line-number \
        -e "from\s+['\"]([^'\"]+)['\"]" \
        -e "import\s+['\"]([^'\"]+)['\"]" \
        -e "require\s*\(\s*['\"]([^'\"]+)['\"]" \
        "$src_file" 2>/dev/null \
        | grep -oE "['\"][^'\"]+['\"]" \
        | tr -d "'\""  \
        | grep -v '^$' \
        || true
      ;;
    python)
      # Match:
      #   from .module import x  (relative)
      #   from module import x   (absolute)
      #   import module
      {
        # Relative imports: from .foo or from ..foo
        rg --no-filename --no-line-number \
          -e "^\s*from\s+(\\.+[A-Za-z0-9_.]*)\s+import" \
          "$src_file" 2>/dev/null \
          | grep -oE "from\s+\\.+[A-Za-z0-9_.]*" \
          | sed 's/^from[[:space:]]*//' \
          || true

        # Absolute imports: from module import ...
        rg --no-filename --no-line-number \
          -e "^\s*from\s+([A-Za-z][A-Za-z0-9_.]*)\s+import" \
          "$src_file" 2>/dev/null \
          | grep -oE "from\s+[A-Za-z][A-Za-z0-9_.]*" \
          | sed 's/^from[[:space:]]*//' \
          || true

        # import module
        rg --no-filename --no-line-number \
          -e "^\s*import\s+([A-Za-z][A-Za-z0-9_.]*)" \
          "$src_file" 2>/dev/null \
          | grep -oE "import\s+[A-Za-z][A-Za-z0-9_.]+" \
          | sed 's/^import[[:space:]]*//' \
          || true
      } | grep -v '^$' || true
      ;;
    java)
      # Match: import com.example.Class;
      rg --no-filename --no-line-number \
        -e "^\s*import\s+([A-Za-z0-9_.]+)\s*;" \
        "$src_file" 2>/dev/null \
        | grep -oE "import\s+[A-Za-z0-9_.]+" \
        | sed 's/^import[[:space:]]*//' \
        | grep -v '^$' \
        || true
      ;;
    *)
      ;;
  esac
}

# ---------------------------------------------------------------------------
# resolve_import: given source file and import string, return actual file path
# or empty string if not resolvable to a local file.
# ---------------------------------------------------------------------------
resolve_import() {
  local src_file="$1"
  local import_str="$2"
  local src_dir
  src_dir="$(dirname "$src_file")"

  local lang
  lang="$(detect_language "$src_file")"

  case "$lang" in
    typescript)
      # Only resolve relative paths
      if [[ "$import_str" != ./* && "$import_str" != ../* ]]; then
        echo ""
        return
      fi

      local candidate
      candidate="$(resolve_abspath "$src_dir" "$import_str")"
      [[ -z "$candidate" ]] && { echo ""; return; }

      # If it exists as-is
      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return
      fi

      # Try appending supported extensions
      for ext in "${EXTENSIONS[@]}"; do
        if [[ -f "${candidate}.${ext}" ]]; then
          echo "${candidate}.${ext}"
          return
        fi
      done

      # Try index file in directory
      if [[ -d "$candidate" ]]; then
        for ext in "${EXTENSIONS[@]}"; do
          if [[ -f "${candidate}/index.${ext}" ]]; then
            echo "${candidate}/index.${ext}"
            return
          fi
        done
      fi

      echo ""
      ;;
    python)
      # Handle relative imports (starting with .)
      if [[ "$import_str" == .* ]]; then
        # Count leading dots for relative depth
        local dots=""
        local rest="$import_str"
        while [[ "$rest" == .* ]]; do
          dots="${dots}."
          rest="${rest#.}"
        done
        local dot_count=${#dots}

        # Navigate up directories
        local base_dir="$src_dir"
        local i
        for (( i=1; i<dot_count; i++ )); do
          base_dir="$(dirname "$base_dir")"
        done

        # Convert module.path to module/path
        local mod_path=""
        if [[ -n "$rest" ]]; then
          mod_path="$(echo "$rest" | tr '.' '/')"
        fi

        if [[ -n "$mod_path" ]]; then
          local candidate
          candidate="$(resolve_abspath "$base_dir" "$mod_path")"
          [[ -z "$candidate" ]] && { echo ""; return; }

          if [[ -f "${candidate}.py" ]]; then
            echo "${candidate}.py"
            return
          fi
          if [[ -d "$candidate" && -f "${candidate}/__init__.py" ]]; then
            echo "${candidate}/__init__.py"
            return
          fi
        fi

        echo ""
        return
      fi

      # Absolute Python imports: convert dots to slashes and search from PATH_DIR
      local mod_path
      mod_path="$(echo "$import_str" | tr '.' '/')"
      local candidate="${PATH_DIR}/${mod_path}"

      if [[ -f "${candidate}.py" ]]; then
        echo "${candidate}.py"
        return
      fi
      if [[ -d "$candidate" && -f "${candidate}/__init__.py" ]]; then
        echo "${candidate}/__init__.py"
        return
      fi

      echo ""
      ;;
    java)
      # import pkg.Class -> pkg/Class.java
      local java_path
      java_path="$(echo "$import_str" | tr '.' '/')"
      local candidate="${PATH_DIR}/${java_path}.java"

      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return
      fi

      echo ""
      ;;
    *)
      echo ""
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Relative path from PATH_DIR for display
# ---------------------------------------------------------------------------
rel() {
  local abs="$1"
  echo "${abs#"${PATH_DIR}/"}"
}

# ---------------------------------------------------------------------------
# Graph state (bash 3.2 compatible — parallel arrays with eval)
# ---------------------------------------------------------------------------
EDGE_COUNT=0
NODE_COUNT=0
NODE_LIST=""

# Store nodes as a newline-separated list
add_node() {
  local node="$1"
  if ! printf '%s' "$NODE_LIST" | grep -qxF "$node"; then
    NODE_LIST="${NODE_LIST}${node}"$'\n'
    eval "NODE_${NODE_COUNT}=\"\$node\""
    NODE_COUNT=$(( NODE_COUNT + 1 ))
  fi
}

get_node() {
  eval "echo \"\$NODE_${1}\""
}

add_edge() {
  local from="$1"
  local to="$2"
  eval "EDGE_FROM_${EDGE_COUNT}=\"\$from\""
  eval "EDGE_TO_${EDGE_COUNT}=\"\$to\""
  EDGE_COUNT=$(( EDGE_COUNT + 1 ))
}

get_edge_from() { eval "echo \"\$EDGE_FROM_${1}\""; }
get_edge_to()   { eval "echo \"\$EDGE_TO_${1}\"";   }

# ---------------------------------------------------------------------------
# Build the dependency graph
# ---------------------------------------------------------------------------
build_graph() {
  local all_files
  all_files="$(collect_files)"

  if [[ -z "$all_files" ]]; then
    echo "Warning: No source files found in '$PATH_DIR'." >&2
    return
  fi

  while IFS= read -r src_abs; do
    [[ -z "$src_abs" ]] && continue

    local src_rel
    src_rel="$(rel "$src_abs")"
    add_node "$src_rel"

    local imports
    imports="$(extract_imports "$src_abs")"

    while IFS= read -r imp; do
      [[ -z "$imp" ]] && continue

      local resolved
      resolved="$(resolve_import "$src_abs" "$imp")"

      # Skip unresolved / external imports
      [[ -z "$resolved" ]] && continue

      # Skip files outside PATH_DIR
      [[ "$resolved" != "${PATH_DIR}"/* ]] && continue

      local dep_rel
      dep_rel="$(rel "$resolved")"
      add_node "$dep_rel"
      add_edge "$src_rel" "$dep_rel"
    done <<< "$imports"
  done <<< "$all_files"
}

# ---------------------------------------------------------------------------
# Circular dependency detection via DFS
#
# Uses dynamically-named variables for adjacency list and state tracking
# to remain bash 3.2 compatible (no associative arrays).
# ---------------------------------------------------------------------------

# Build adjacency list: for each node index, store a space-separated list of
# neighbor indices.
build_adjacency() {
  local i
  for (( i=0; i<NODE_COUNT; i++ )); do
    eval "ADJ_${i}=\"\""
  done

  for (( i=0; i<EDGE_COUNT; i++ )); do
    local from to from_idx to_idx
    from="$(get_edge_from "$i")"
    to="$(get_edge_to "$i")"
    from_idx="$(node_index "$from")"
    to_idx="$(node_index "$to")"
    if [[ -n "$from_idx" && -n "$to_idx" ]]; then
      local cur
      eval "cur=\"\$ADJ_${from_idx}\""
      eval "ADJ_${from_idx}=\"\$cur \$to_idx\""
    fi
  done
}

# Find node index by label (linear scan)
node_index() {
  local label="$1"
  local i
  for (( i=0; i<NODE_COUNT; i++ )); do
    local n
    eval "n=\"\$NODE_${i}\""
    if [[ "$n" == "$label" ]]; then
      echo "$i"
      return
    fi
  done
  echo ""
}

# DFS state per node:
#   DFS_STATE_N: 0=unvisited, 1=in-stack, 2=done
#   DFS_PARENT_N: parent index in DFS tree (-1 for root)

CYCLES=""
CYCLE_COUNT=0

detect_cycles() {
  local i
  for (( i=0; i<NODE_COUNT; i++ )); do
    eval "DFS_STATE_${i}=0"
  done

  for (( i=0; i<NODE_COUNT; i++ )); do
    local st
    eval "st=\$DFS_STATE_${i}"
    if [[ "$st" -eq 0 ]]; then
      dfs_visit "$i" ""
    fi
  done
}

# DFS visit: node_idx, path (space-separated list of indices in current stack)
dfs_visit() {
  local node="$1"
  local path="$2"

  eval "DFS_STATE_${node}=1"
  local new_path="${path} ${node}"

  local neighbors
  eval "neighbors=\"\$ADJ_${node}\""

  for neighbor in $neighbors; do
    local nst
    eval "nst=\$DFS_STATE_${neighbor}"

    if [[ "$nst" -eq 1 ]]; then
      # Back edge found — extract cycle from path
      local cycle=""
      local found=false
      for p in $new_path; do
        if [[ "$p" -eq "$neighbor" ]]; then
          found=true
        fi
        if $found; then
          local nname
          eval "nname=\"\$NODE_${p}\""
          if [[ -z "$cycle" ]]; then
            cycle="$nname"
          else
            cycle="${cycle} -> ${nname}"
          fi
        fi
      done
      # Close the cycle
      local start_name
      eval "start_name=\"\$NODE_${neighbor}\""
      cycle="${cycle} -> ${start_name}"

      eval "CYCLE_${CYCLE_COUNT}=\"\$cycle\""
      CYCLE_COUNT=$(( CYCLE_COUNT + 1 ))

    elif [[ "$nst" -eq 0 ]]; then
      dfs_visit "$neighbor" "$new_path"
    fi
  done

  eval "DFS_STATE_${node}=2"
}

get_cycle() { eval "echo \"\$CYCLE_${1}\""; }

# ---------------------------------------------------------------------------
# Collect unique "to" targets for table column headers
# ---------------------------------------------------------------------------
collect_targets() {
  local targets=""
  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local to
    to="$(get_edge_to "$i")"
    if ! printf '%s' "$targets" | grep -qxF "$to"; then
      targets="${targets}${to}"$'\n'
    fi
  done
  echo "$targets"
}

# Check if an edge exists from -> to
has_edge() {
  local from="$1"
  local to="$2"
  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local ef et
    ef="$(get_edge_from "$i")"
    et="$(get_edge_to "$i")"
    if [[ "$ef" == "$from" && "$et" == "$to" ]]; then
      return 0
    fi
  done
  return 1
}

# Collect unique "from" sources (nodes that have at least one outgoing edge)
collect_sources() {
  local sources=""
  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local from
    from="$(get_edge_from "$i")"
    if ! printf '%s' "$sources" | grep -qxF "$from"; then
      sources="${sources}${from}"$'\n'
    fi
  done
  echo "$sources"
}

# ---------------------------------------------------------------------------
# Truncate a string to max width
# ---------------------------------------------------------------------------
truncate_str() {
  local str="$1"
  local max="$2"
  if [[ ${#str} -gt $max ]]; then
    echo "${str:0:$(( max - 2 ))}.."
  else
    echo "$str"
  fi
}

# ---------------------------------------------------------------------------
# Output: table format
# ---------------------------------------------------------------------------
output_table() {
  echo "=== Import Map ==="
  echo ""

  if [[ "$EDGE_COUNT" -eq 0 ]]; then
    echo "No dependencies found."
    return
  fi

  # Collect column headers (targets) and row labels (sources)
  local targets_raw sources_raw
  targets_raw="$(collect_targets)"
  sources_raw="$(collect_sources)"

  # Build arrays of targets and sources
  local target_count=0
  local source_count=0

  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    eval "TARGET_${target_count}=\"\$t\""
    target_count=$(( target_count + 1 ))
  done <<< "$targets_raw"

  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    eval "SOURCE_${source_count}=\"\$s\""
    source_count=$(( source_count + 1 ))
  done <<< "$sources_raw"

  # Determine column widths
  local from_col_width=20
  local cell_width=0
  local i

  # Find max source name length
  for (( i=0; i<source_count; i++ )); do
    local sname
    eval "sname=\"\$SOURCE_${i}\""
    local slen=${#sname}
    if [[ $slen -gt $from_col_width ]]; then
      from_col_width=$slen
    fi
  done

  # Cap from column
  if [[ $from_col_width -gt 40 ]]; then
    from_col_width=40
  fi

  # Find max target name length (for column headers)
  for (( i=0; i<target_count; i++ )); do
    local tname
    eval "tname=\"\$TARGET_${i}\""
    # Use basename for column headers
    local bname
    bname="$(basename "$tname")"
    local tlen=${#bname}
    if [[ $tlen -gt $cell_width ]]; then
      cell_width=$tlen
    fi
  done

  # Minimum cell width
  if [[ $cell_width -lt 7 ]]; then
    cell_width=7
  fi
  # Cap cell width
  if [[ $cell_width -gt 20 ]]; then
    cell_width=20
  fi

  # Print header row
  printf "%-${from_col_width}s" "From / To"
  for (( i=0; i<target_count; i++ )); do
    local tname bname
    eval "tname=\"\$TARGET_${i}\""
    bname="$(basename "$tname")"
    bname="$(truncate_str "$bname" "$cell_width")"
    printf " | %-${cell_width}s" "$bname"
  done
  echo ""

  # Print separator
  local sep=""
  local j
  for (( j=0; j<from_col_width; j++ )); do
    sep="${sep}-"
  done
  for (( i=0; i<target_count; i++ )); do
    sep="${sep}-+-"
    for (( j=0; j<cell_width; j++ )); do
      sep="${sep}-"
    done
  done
  echo "$sep"

  # Print rows
  for (( i=0; i<source_count; i++ )); do
    local sname
    eval "sname=\"\$SOURCE_${i}\""
    local display_name
    display_name="$(truncate_str "$sname" "$from_col_width")"
    printf "%-${from_col_width}s" "$display_name"

    for (( j=0; j<target_count; j++ )); do
      local tname
      eval "tname=\"\$TARGET_${j}\""
      if has_edge "$sname" "$tname"; then
        # Center the asterisk
        local pad=$(( (cell_width - 1) / 2 ))
        printf " | %${pad}s*%-$(( cell_width - pad - 1 ))s" "" ""
      else
        printf " | %-${cell_width}s" ""
      fi
    done
    echo ""
  done

  # Print circular dependencies
  if [[ "$CYCLE_COUNT" -gt 0 ]]; then
    echo ""
    echo "CIRCULAR DEPENDENCIES:"
    local c
    for (( c=0; c<CYCLE_COUNT; c++ )); do
      local cycle
      cycle="$(get_cycle "$c")"
      echo "  $cycle"
    done
  fi
}

# ---------------------------------------------------------------------------
# Output: JSON format
# ---------------------------------------------------------------------------
output_json() {
  # Collect unique file list
  local files_json='['
  local first=true
  local i
  for (( i=0; i<NODE_COUNT; i++ )); do
    local n
    eval "n=\"\$NODE_${i}\""
    local escaped
    escaped="$(printf '%s' "$n" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    if $first; then
      files_json+="\"${escaped}\""
      first=false
    else
      files_json+=", \"${escaped}\""
    fi
  done
  files_json+=']'

  # Build dependencies object: { "file": ["dep1", "dep2"], ... }
  local deps_json='{'
  local sources_raw
  sources_raw="$(collect_sources)"
  local dfirst=true

  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    local src_escaped
    src_escaped="$(printf '%s' "$src" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    local deps_arr='['
    local afirst=true
    for (( i=0; i<EDGE_COUNT; i++ )); do
      local ef et
      ef="$(get_edge_from "$i")"
      et="$(get_edge_to "$i")"
      if [[ "$ef" == "$src" ]]; then
        local te
        te="$(printf '%s' "$et" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        if $afirst; then
          deps_arr+="\"${te}\""
          afirst=false
        else
          deps_arr+=", \"${te}\""
        fi
      fi
    done
    deps_arr+=']'

    if $dfirst; then
      deps_json+="\"${src_escaped}\": ${deps_arr}"
      dfirst=false
    else
      deps_json+=", \"${src_escaped}\": ${deps_arr}"
    fi
  done <<< "$sources_raw"
  deps_json+='}'

  # Build circular dependencies array
  local cycles_json='['
  local cfirst=true
  local c
  for (( c=0; c<CYCLE_COUNT; c++ )); do
    local cycle
    cycle="$(get_cycle "$c")"
    # Split " -> " separated cycle into JSON array
    local carr='['
    local pfirst=true
    local old_ifs="$IFS"
    # Split on " -> "
    local parts
    parts="$(echo "$cycle" | sed 's/ -> /\n/g')"
    while IFS= read -r part; do
      [[ -z "$part" ]] && continue
      local pe
      pe="$(printf '%s' "$part" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      if $pfirst; then
        carr+="\"${pe}\""
        pfirst=false
      else
        carr+=", \"${pe}\""
      fi
    done <<< "$parts"
    IFS="$old_ifs"
    carr+=']'

    if $cfirst; then
      cycles_json+="$carr"
      cfirst=false
    else
      cycles_json+=", $carr"
    fi
  done
  cycles_json+=']'

  printf '{\n'
  printf '  "files": %s,\n' "$files_json"
  printf '  "dependencies": %s,\n' "$deps_json"
  printf '  "circularDependencies": %s\n' "$cycles_json"
  printf '}\n'
}

# ---------------------------------------------------------------------------
# Output: CSV format
# ---------------------------------------------------------------------------
output_csv() {
  echo "from,to"
  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local from to
    from="$(get_edge_from "$i")"
    to="$(get_edge_to "$i")"
    printf '%s,%s\n' "$from" "$to"
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  build_graph

  if [[ "$EDGE_COUNT" -gt 0 ]]; then
    build_adjacency
    detect_cycles
  fi

  case "$FORMAT" in
    table) output_table ;;
    json)  output_json ;;
    csv)   output_csv ;;
  esac
}

main
