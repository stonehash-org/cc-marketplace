#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# dependency-graph.sh
# File dependency graph generator using import/require analysis.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

usage() {
  local exit_code="${1:-0}"
  cat <<EOF
Usage: $SCRIPT_NAME --path DIR [--format mermaid|dot|json] [--depth N] [--filter GLOB]

Options:
  --path DIR        Root directory to scan (required)
  --format FORMAT   Output format: mermaid (default), dot, json
  --depth N         Limit graph depth from entry points (0 = unlimited)
  --filter GLOB     Only include files matching glob pattern (e.g. "*.ts")
  -h, --help        Show this help message

Examples:
  $SCRIPT_NAME --path ./src
  $SCRIPT_NAME --path ./src --format dot
  $SCRIPT_NAME --path ./src --format json --depth 3
  $SCRIPT_NAME --path ./src --filter "*.ts" --format mermaid
EOF
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Supported file extensions
# ---------------------------------------------------------------------------
EXTENSIONS="ts tsx js jsx mjs cjs py java"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PATH_DIR=""
FORMAT="mermaid"
DEPTH=0
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
    --depth)
      DEPTH="${2:-0}"
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
  mermaid|dot|json) ;;
  *)
    echo "Error: --format must be one of: mermaid, dot, json" >&2
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
# detect_language: returns language identifier for a file extension
# ---------------------------------------------------------------------------
detect_language() {
  local ext="$1"
  case "$ext" in
    ts|tsx|js|jsx|mjs|cjs) echo "js" ;;
    py)                      echo "python" ;;
    java)                    echo "java" ;;
    *)                       echo "unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# resolve_abspath: portable realpath substitute (no GNU coreutils required).
# Resolves a relative path against a base directory.
# ---------------------------------------------------------------------------
resolve_abspath() {
  local base_dir="$1"
  local rel_path="$2"

  # Use Python if available (most reliable cross-platform option)
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

  # Pure-shell fallback: cd into a temp subshell
  local _base _name
  _base="$(dirname "$rel_path")"
  _name="$(basename "$rel_path")"
  ( cd "$base_dir" && cd "$_base" && printf '%s/%s' "$(pwd -P)" "$_name" ) 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_rg_globs: emit --glob flags for each extension, one per line
# ---------------------------------------------------------------------------
build_rg_globs() {
  for ext in $EXTENSIONS; do
    printf -- '--glob\n*.%s\n' "$ext"
  done
}

# ---------------------------------------------------------------------------
# extract_imports: given a source file, print one imported path per line
# ---------------------------------------------------------------------------
extract_imports() {
  local src_file="$1"
  local ext="${src_file##*.}"
  local lang
  lang="$(detect_language "$ext")"

  case "$lang" in
    js)
      # Match:
      #   import ... from 'PATH' / "PATH"
      #   import 'PATH' / "PATH"
      #   require('PATH') / require("PATH")
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
      #   from PATH import ...  -> extract PATH
      #   import PATH           -> extract PATH
      {
        rg --no-filename --no-line-number \
          -e "^\s*from\s+([A-Za-z0-9_.]+)\s+import" \
          "$src_file" 2>/dev/null \
          | grep -oE "from\s+[A-Za-z0-9_.]+" \
          | sed 's/^from[[:space:]]*//' \
          || true

        rg --no-filename --no-line-number \
          -e "^\s*import\s+([A-Za-z0-9_.]+)" \
          "$src_file" 2>/dev/null \
          | grep -oE "import\s+[A-Za-z0-9_.]+" \
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

  # Only attempt resolution for relative paths (./foo or ../bar)
  if [[ "$import_str" != ./* && "$import_str" != ../* ]]; then
    echo ""
    return
  fi

  local candidate
  candidate="$(resolve_abspath "$src_dir" "$import_str")"

  if [[ -z "$candidate" ]]; then
    echo ""
    return
  fi

  # If the candidate exists as-is, return it
  if [[ -f "$candidate" ]]; then
    echo "$candidate"
    return
  fi

  # Try appending each supported extension
  for ext in $EXTENSIONS; do
    if [[ -f "${candidate}.${ext}" ]]; then
      echo "${candidate}.${ext}"
      return
    fi
  done

  # Try index file inside directory
  if [[ -d "$candidate" ]]; then
    for ext in $EXTENSIONS; do
      if [[ -f "${candidate}/index.${ext}" ]]; then
        echo "${candidate}/index.${ext}"
        return
      fi
    done
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# Collect all source files, one per line, respecting --filter
# ---------------------------------------------------------------------------
collect_files() {
  local rg_args=""
  for ext in $EXTENSIONS; do
    rg_args="$rg_args --glob *.$ext"
  done

  if [[ -n "$FILTER" ]]; then
    # shellcheck disable=SC2086
    rg --files $rg_args --glob "$FILTER" "$PATH_DIR" 2>/dev/null || true
  else
    # shellcheck disable=SC2086
    rg --files $rg_args "$PATH_DIR" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Graph state (parallel arrays — bash 3 compatible)
#   EDGE_FROM_n  = number of edges recorded
#   EDGE_FROM_$i / EDGE_TO_$i = dynamically named vars for each edge
#   NODE_SET     = newline-separated unique node labels
# ---------------------------------------------------------------------------
EDGE_COUNT=0
NODE_SET=""

# Add a node to the unique set
add_node() {
  local node="$1"
  # Use a fixed-string grep so special chars don't cause issues
  if ! printf '%s' "$NODE_SET" | grep -qxF "$node"; then
    NODE_SET="${NODE_SET}${node}"$'\n'
  fi
}

# Add an edge (from, to)
add_edge() {
  local from="$1"
  local to="$2"
  # Store in dynamically-named variables (bash 3 safe)
  eval "EDGE_FROM_${EDGE_COUNT}=\"\$from\""
  eval "EDGE_TO_${EDGE_COUNT}=\"\$to\""
  EDGE_COUNT=$(( EDGE_COUNT + 1 ))
}

# Get edge from/to by index
get_edge_from() { eval "echo \"\$EDGE_FROM_${1}\""; }
get_edge_to()   { eval "echo \"\$EDGE_TO_${1}\"";   }

# Relative path from PATH_DIR for display
rel() {
  local abs="$1"
  echo "${abs#"${PATH_DIR}/"}"
}

# ---------------------------------------------------------------------------
# BFS / depth-limited traversal to build the graph
# ---------------------------------------------------------------------------
build_graph() {
  local all_files
  all_files="$(collect_files)"

  if [[ -z "$all_files" ]]; then
    echo "Warning: No source files found in '$PATH_DIR'." >&2
    return
  fi

  # visited: newline-separated absolute paths already processed
  local visited=""
  # queue: newline-separated "DEPTH:ABSPATH" entries
  local queue=""

  # Seed queue with all discovered files at depth 0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    queue="${queue}0:${f}"$'\n'
    add_node "$(rel "$f")"
  done <<< "$all_files"

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue

    local depth_val="${entry%%:*}"
    local src_abs="${entry#*:}"

    # Skip already-visited files
    if printf '%s' "$visited" | grep -qxF "$src_abs"; then
      continue
    fi
    visited="${visited}${src_abs}"$'\n'

    # Depth limit (0 = unlimited)
    if [[ "$DEPTH" -gt 0 && "$depth_val" -ge "$DEPTH" ]]; then
      continue
    fi

    local next_depth=$(( depth_val + 1 ))

    local imports
    imports="$(extract_imports "$src_abs")"

    while IFS= read -r imp; do
      [[ -z "$imp" ]] && continue

      local resolved
      resolved="$(resolve_import "$src_abs" "$imp")"

      if [[ -z "$resolved" ]]; then
        # Non-local import (package name) — keep as external node label
        add_node "$imp"
        add_edge "$(rel "$src_abs")" "$imp"
        continue
      fi

      # Discard resolved paths outside PATH_DIR
      if [[ "$resolved" != "${PATH_DIR}"/* ]]; then
        continue
      fi

      local rel_resolved
      rel_resolved="$(rel "$resolved")"
      add_node "$rel_resolved"
      add_edge "$(rel "$src_abs")" "$rel_resolved"

      # Enqueue for traversal if not yet visited
      if ! printf '%s' "$visited" | grep -qxF "$resolved"; then
        queue="${queue}${next_depth}:${resolved}"$'\n'
      fi
    done <<< "$imports"

  done <<< "$queue"
}

# ---------------------------------------------------------------------------
# Sanitize a string for use as a Mermaid node id
# ---------------------------------------------------------------------------
mermaid_id() {
  echo "$1" | tr -cs 'a-zA-Z0-9' '_' | sed 's/^_*//;s/_*$//'
}

# ---------------------------------------------------------------------------
# Output functions
# ---------------------------------------------------------------------------
output_mermaid() {
  echo "graph TD"

  if [[ "$EDGE_COUNT" -eq 0 ]]; then
    # No edges — list isolated nodes
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      local nid
      nid="$(mermaid_id "$node")"
      printf '  %s["%s"]\n' "$nid" "$node"
    done <<< "$NODE_SET"
    return
  fi

  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local from to from_id to_id
    from="$(get_edge_from $i)"
    to="$(get_edge_to $i)"
    from_id="$(mermaid_id "$from")"
    to_id="$(mermaid_id "$to")"
    printf '  %s["%s"] --> %s["%s"]\n' "$from_id" "$from" "$to_id" "$to"
  done
}

output_dot() {
  echo 'digraph dependencies {'

  if [[ "$EDGE_COUNT" -eq 0 ]]; then
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      printf '  "%s"\n' "$node"
    done <<< "$NODE_SET"
    echo '}'
    return
  fi

  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local from to
    from="$(get_edge_from $i)"
    to="$(get_edge_to $i)"
    printf '  "%s" -> "%s"\n' "$from" "$to"
  done
  echo '}'
}

output_json() {
  # Build nodes array
  local nodes_json='['
  local first=true
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    # Escape backslashes and double-quotes
    local escaped
    escaped="$(printf '%s' "$node" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    if $first; then
      nodes_json+="\"${escaped}\""
      first=false
    else
      nodes_json+=", \"${escaped}\""
    fi
  done <<< "$NODE_SET"
  nodes_json+=']'

  # Build edges array
  local edges_json='['
  local efirst=true
  local i
  for (( i=0; i<EDGE_COUNT; i++ )); do
    local from to ef et
    from="$(get_edge_from $i)"
    to="$(get_edge_to $i)"
    ef="$(printf '%s' "$from" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    et="$(printf '%s' "$to"   | sed 's/\\/\\\\/g; s/"/\\"/g')"
    local edge="{\"from\": \"${ef}\", \"to\": \"${et}\"}"
    if $efirst; then
      edges_json+="$edge"
      efirst=false
    else
      edges_json+=", $edge"
    fi
  done
  edges_json+=']'

  printf '{\n  "nodes": %s,\n  "edges": %s\n}\n' "$nodes_json" "$edges_json"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  build_graph

  case "$FORMAT" in
    mermaid) output_mermaid ;;
    dot)     output_dot ;;
    json)    output_json ;;
  esac
}

main
