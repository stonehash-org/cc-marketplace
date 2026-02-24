#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

MAP_FILE=""
SEARCH_PATH="."
DRY_RUN=false
FORMAT="text"

usage() {
  cat <<EOF
Usage: $(basename "$0") --map rename-map.json --path DIR [--dry-run] [--format text|json]

Batch rename symbols using a JSON mapping file.
Automatically detects dependency order and handles circular renames.

Options:
  --map FILE      JSON file with rename mappings (required)
  --path DIR      Project root directory (default: .)
  --dry-run       Show what would change without modifying files
  --format FMT    Output format: text or json (default: text)
  -h, --help      Show this help

Map file format:
  {
    "renames": [
      {"old": "userId", "new": "accountId"},
      {"old": "getUserData", "new": "fetchAccountData"}
    ]
  }

Example:
  $(basename "$0") --map rename-map.json --path ./src --dry-run
  $(basename "$0") --map rename-map.json --path ./src --format json
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --map)     MAP_FILE="$2";    shift 2 ;;
    --path)    SEARCH_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;     shift   ;;
    --format)  FORMAT="$2";      shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -z "$MAP_FILE" ]; then
  echo "Error: --map is required" >&2
  exit 1
fi

if [ ! -f "$MAP_FILE" ]; then
  echo "Error: map file not found: $MAP_FILE" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed" >&2
  exit 1
fi

case "$FORMAT" in
  text|json) ;;
  *)
    echo "Error: --format must be text or json" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Parse the JSON mapping file
# ---------------------------------------------------------------------------
RENAME_COUNT=$(jq '.renames | length' "$MAP_FILE")

if [ "$RENAME_COUNT" -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '{"mappings":0,"results":[],"totalChanges":0,"totalFiles":0,"circularRenames":0,"dryRun":'"$( [ "$DRY_RUN" = true ] && echo "true" || echo "false" )"'}'
  else
    echo "No renames specified in map file."
  fi
  exit 0
fi

# Read all renames into parallel arrays (bash 3.2 compatible)
ALL_OLD=()
ALL_NEW=()
i=0
while [ $i -lt "$RENAME_COUNT" ]; do
  old_name=$(jq -r ".renames[$i].old" "$MAP_FILE")
  new_name=$(jq -r ".renames[$i].new" "$MAP_FILE")
  ALL_OLD+=("$old_name")
  ALL_NEW+=("$new_name")
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Dependency order detection and topological sort
#
# Build a dependency graph: rename i depends on rename j if
# ALL_NEW[i] == ALL_OLD[j] (i.e., i's new name is j's old name,
# meaning j must be renamed first so i doesn't clobber it).
#
# We detect cycles and handle them with temp-name strategy.
# ---------------------------------------------------------------------------

# DEPENDS[i] = index j that i depends on, or -1 if none
DEPENDS=()
i=0
while [ $i -lt "$RENAME_COUNT" ]; do
  dep=-1
  j=0
  while [ $j -lt "$RENAME_COUNT" ]; do
    if [ $i -ne $j ] && [ "${ALL_NEW[$i]}" = "${ALL_OLD[$j]}" ]; then
      dep=$j
      break
    fi
    j=$((j + 1))
  done
  DEPENDS+=("$dep")
  i=$((i + 1))
done

# Detect cycles: follow dependency chains; if we revisit a node, it's a cycle.
# CYCLE_GROUP[i] = cycle id (>= 0) if in a cycle, -1 otherwise
CYCLE_GROUP=()
i=0
while [ $i -lt "$RENAME_COUNT" ]; do
  CYCLE_GROUP+=("-1")
  i=$((i + 1))
done

NEXT_CYCLE_ID=0
CIRCULAR_RENAME_COUNT=0

# For each node, follow the chain to detect cycles
i=0
while [ $i -lt "$RENAME_COUNT" ]; do
  if [ "${CYCLE_GROUP[$i]}" -ne -1 ]; then
    i=$((i + 1))
    continue
  fi

  # Walk the chain from i, collecting visited nodes
  VISITED_CHAIN=()
  VISITED_SET=""
  current=$i
  found_cycle=false

  while [ "$current" -ne -1 ]; do
    # Check if current is already in our chain (cycle detected)
    case " $VISITED_SET " in
      *" $current "*)
        found_cycle=true
        break
        ;;
    esac
    # Check if current already has a cycle group assigned
    if [ "${CYCLE_GROUP[$current]}" -ne -1 ]; then
      break
    fi
    VISITED_CHAIN+=("$current")
    VISITED_SET="$VISITED_SET $current"
    current="${DEPENDS[$current]}"
  done

  if [ "$found_cycle" = true ]; then
    # Mark all nodes in the cycle with the same cycle ID
    cycle_start=$current
    marking=false
    for node in "${VISITED_CHAIN[@]}"; do
      if [ "$node" -eq "$cycle_start" ]; then
        marking=true
      fi
      if [ "$marking" = true ]; then
        CYCLE_GROUP[$node]=$NEXT_CYCLE_ID
      fi
    done
    NEXT_CYCLE_ID=$((NEXT_CYCLE_ID + 1))
    CIRCULAR_RENAME_COUNT=$((CIRCULAR_RENAME_COUNT + 1))
  fi

  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Build ordered rename operations
# Entries: "old|new" pairs, one per line
# For cycles, we inject temp-name intermediaries.
# For non-cycle nodes, topological sort: process dependencies first.
# ---------------------------------------------------------------------------
ORDERED_OPS=""  # newline-separated "old|new" pairs
PROCESSED=""    # space-separated indices already emitted

# Emit a single non-cycle rename (recursively emit its dependency first)
emit_rename() {
  local idx=$1
  case " $PROCESSED " in
    *" $idx "*) return ;;
  esac

  local dep="${DEPENDS[$idx]}"
  # If dependency exists and is not in a cycle, emit it first
  if [ "$dep" -ne -1 ] && [ "${CYCLE_GROUP[$dep]}" -eq -1 ]; then
    emit_rename "$dep"
  fi

  ORDERED_OPS="${ORDERED_OPS}${ALL_OLD[$idx]}|${ALL_NEW[$idx]}"$'\n'
  PROCESSED="$PROCESSED $idx"
}

# First, handle all non-cycle renames in dependency order
i=0
while [ $i -lt "$RENAME_COUNT" ]; do
  if [ "${CYCLE_GROUP[$i]}" -eq -1 ]; then
    emit_rename "$i"
  fi
  i=$((i + 1))
done

# Handle cycle groups with temp names
cycle_id=0
while [ $cycle_id -lt "$NEXT_CYCLE_ID" ]; do
  # Collect members of this cycle
  CYCLE_MEMBERS=()
  i=0
  while [ $i -lt "$RENAME_COUNT" ]; do
    if [ "${CYCLE_GROUP[$i]}" -eq "$cycle_id" ]; then
      CYCLE_MEMBERS+=("$i")
    fi
    i=$((i + 1))
  done

  # Step 1: Rename all cycle members to temp names
  for idx in "${CYCLE_MEMBERS[@]}"; do
    ORDERED_OPS="${ORDERED_OPS}${ALL_OLD[$idx]}|__temp_${ALL_OLD[$idx]}"$'\n'
  done

  # Step 2: Rename temp names to final names
  for idx in "${CYCLE_MEMBERS[@]}"; do
    ORDERED_OPS="${ORDERED_OPS}__temp_${ALL_OLD[$idx]}|${ALL_NEW[$idx]}"$'\n'
  done

  PROCESSED="$PROCESSED $(printf '%s ' "${CYCLE_MEMBERS[@]}")"
  cycle_id=$((cycle_id + 1))
done

# Remove trailing blank line
ORDERED_OPS=$(printf '%s' "$ORDERED_OPS" | sed '/^$/d')

# ---------------------------------------------------------------------------
# Execute renames sequentially, collecting results
# ---------------------------------------------------------------------------
TOTAL_CHANGES=0
TOTAL_FILES=0
RESULTS_JSON="[]"
STEP=0
RESULT_ENTRIES=()

# Track per-original-rename aggregated results
# We map temp operations back to the original rename for reporting
declare -a ORIG_CHANGES
declare -a ORIG_FILES
i=0
while [ $i -lt "$RENAME_COUNT" ]; do
  ORIG_CHANGES+=("0")
  ORIG_FILES+=("0")
  i=$((i + 1))
done

if [ "$FORMAT" = "text" ]; then
  echo "=== Batch Rename ($RENAME_COUNT mappings) ==="
  echo ""
fi

while IFS= read -r op; do
  [ -z "$op" ] && continue
  old="${op%%|*}"
  new="${op##*|}"

  STEP=$((STEP + 1))

  # Build rename-symbol.sh command
  CMD_ARGS=(--symbol "$old" --new "$new" --path "$SEARCH_PATH" --format json)
  if [ "$DRY_RUN" = true ]; then
    CMD_ARGS+=(--dry-run)
  fi

  # Execute rename-symbol.sh and capture output
  result=$(bash "$SCRIPT_DIR/rename-symbol.sh" "${CMD_ARGS[@]}" 2>/dev/null || echo '{"totalChanges":0,"files":[]}')

  changes=$(echo "$result" | jq -r '.totalChanges // 0')
  file_count=$(echo "$result" | jq -r '.files | length // 0')

  # Find which original rename this operation belongs to
  orig_idx=-1
  i=0
  while [ $i -lt "$RENAME_COUNT" ]; do
    # Direct match
    if [ "$old" = "${ALL_OLD[$i]}" ] && [ "$new" = "${ALL_NEW[$i]}" ]; then
      orig_idx=$i
      break
    fi
    # Temp-to-final match (cycle step 2)
    if [ "$old" = "__temp_${ALL_OLD[$i]}" ] && [ "$new" = "${ALL_NEW[$i]}" ]; then
      orig_idx=$i
      break
    fi
    # Original-to-temp match (cycle step 1)
    if [ "$old" = "${ALL_OLD[$i]}" ] && [ "$new" = "__temp_${ALL_OLD[$i]}" ]; then
      orig_idx=$i
      break
    fi
    i=$((i + 1))
  done

  if [ "$orig_idx" -ge 0 ]; then
    prev_changes="${ORIG_CHANGES[$orig_idx]}"
    prev_files="${ORIG_FILES[$orig_idx]}"
    ORIG_CHANGES[$orig_idx]=$((prev_changes + changes))
    ORIG_FILES[$orig_idx]=$((prev_files + file_count))
  fi

  TOTAL_CHANGES=$((TOTAL_CHANGES + changes))
  TOTAL_FILES=$((TOTAL_FILES + file_count))
done <<< "$ORDERED_OPS"

# ---------------------------------------------------------------------------
# Output report
# ---------------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  # Build results array
  results_json="["
  i=0
  while [ $i -lt "$RENAME_COUNT" ]; do
    if [ $i -gt 0 ]; then
      results_json="${results_json},"
    fi
    results_json="${results_json}{\"old\":\"${ALL_OLD[$i]}\",\"new\":\"${ALL_NEW[$i]}\",\"changes\":${ORIG_CHANGES[$i]},\"files\":${ORIG_FILES[$i]}}"
    i=$((i + 1))
  done
  results_json="${results_json}]"

  dry_run_val="false"
  if [ "$DRY_RUN" = true ]; then
    dry_run_val="true"
  fi

  jq -n \
    --argjson mappings "$RENAME_COUNT" \
    --argjson results "$results_json" \
    --argjson totalChanges "$TOTAL_CHANGES" \
    --argjson totalFiles "$TOTAL_FILES" \
    --argjson circularRenames "$CIRCULAR_RENAME_COUNT" \
    --argjson dryRun "$dry_run_val" \
    '{mappings: $mappings, results: $results, totalChanges: $totalChanges, totalFiles: $totalFiles, circularRenames: $circularRenames, dryRun: $dryRun}'
else
  i=0
  while [ $i -lt "$RENAME_COUNT" ]; do
    step=$((i + 1))
    echo "[$step/$RENAME_COUNT] ${ALL_OLD[$i]} -> ${ALL_NEW[$i]}: ${ORIG_CHANGES[$i]} changes in ${ORIG_FILES[$i]} files"
    i=$((i + 1))
  done

  echo ""
  echo "Total: $TOTAL_CHANGES changes in $TOTAL_FILES files"
  echo "Circular renames: $CIRCULAR_RENAME_COUNT"
fi
