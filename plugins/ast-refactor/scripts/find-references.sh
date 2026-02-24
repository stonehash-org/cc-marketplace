#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

SYMBOL=""
SEARCH_PATH="."
FORMAT="text"

usage() {
  cat <<EOF
Usage: $(basename "$0") --symbol NAME [--path DIR] [--format text|json]

Find all references to a symbol using tree-sitter AST analysis.
Distinguishes definitions, references, imports, and parameters.

Options:
  --symbol NAME   Symbol name to search for (required)
  --path DIR      Directory to search in (default: .)
  --format FMT    Output format: text or json (default: text)
  -h, --help      Show this help

Example:
  $(basename "$0") --symbol userId --path ./src
  $(basename "$0") --symbol MyClass --path . --format json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --symbol) SYMBOL="$2"; shift 2 ;;
    --path)   SEARCH_PATH="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SYMBOL" ]; then
  echo "Error: --symbol is required" >&2
  usage
fi

detect_language() {
  local file="$1"
  case "$file" in
    *.ts|*.tsx)   echo "typescript" ;;
    *.js|*.jsx|*.mjs|*.cjs) echo "typescript" ;;
    *.py)         echo "python" ;;
    *.java)       echo "java" ;;
    *.kt|*.kts)       echo "kotlin" ;;
    *)            echo "" ;;
  esac
}

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

CANDIDATES=$(eval rg -l --fixed-strings '"$SYMBOL"' '"$SEARCH_PATH"' \
  $(printf -- "--glob '*.%s' " "${EXTENSIONS[@]}") 2>/dev/null || true)

if [ -z "$CANDIDATES" ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '{"symbol":"'"$SYMBOL"'","total":0,"definitions":[],"references":[],"imports":[]}'
  else
    echo "No references found for '$SYMBOL'"
  fi
  exit 0
fi

DEFINITIONS=()
REFERENCES=()
IMPORTS=()
PARAMETERS=()
TOTAL=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  query_file="$QUERIES_DIR/$lang/symbols.scm"
  [ ! -f "$query_file" ] && continue

  ts_output=$(tree-sitter query "$query_file" "$file" 2>/dev/null || true)
  [ -z "$ts_output" ] && continue

  while IFS= read -r line; do
    re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
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
    elif [[ "$line" =~ capture:\ ([a-z_.]+),\ text:\ \"([^\"]*)\",\ row:\ ([0-9]+),\ col:\ ([0-9]+) ]]; then
      capture="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
      row="${BASH_REMATCH[3]}"
      col="${BASH_REMATCH[4]}"
    else
      continue
    fi

    [ "$text" != "$SYMBOL" ] && continue
    [[ "$capture" == string.* ]] && continue
    [[ "$capture" == comment.* ]] && continue

    entry="$file:$((row + 1)):$((col + 1))"
    TOTAL=$((TOTAL + 1))

    case "$capture" in
      symbol.definition)
        DEFINITIONS+=("$entry")
        ;;
      symbol.import|symbol.export)
        IMPORTS+=("$entry")
        ;;
      symbol.parameter)
        PARAMETERS+=("$entry")
        ;;
      symbol.reference|symbol.type_reference)
        REFERENCES+=("$entry")
        ;;
    esac
  done <<< "$ts_output"
done <<< "$CANDIDATES"

if [ "$FORMAT" = "json" ]; then
  defs_json=$(printf '%s\n' "${DEFINITIONS[@]+"${DEFINITIONS[@]}"}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
  refs_json=$(printf '%s\n' "${REFERENCES[@]+"${REFERENCES[@]}"}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
  imps_json=$(printf '%s\n' "${IMPORTS[@]+"${IMPORTS[@]}"}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")
  params_json=$(printf '%s\n' "${PARAMETERS[@]+"${PARAMETERS[@]}"}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg sym "$SYMBOL" \
    --argjson total "$TOTAL" \
    --argjson defs "$defs_json" \
    --argjson refs "$refs_json" \
    --argjson imps "$imps_json" \
    --argjson params "$params_json" \
    '{symbol: $sym, total: $total, definitions: $defs, references: $refs, imports: $imps, parameters: $params}'
else
  echo "=== References for '$SYMBOL' (total: $TOTAL) ==="
  echo ""
  if [ ${#DEFINITIONS[@]} -gt 0 ]; then
    echo "DEFINITIONS (${#DEFINITIONS[@]}):"
    printf "  %s\n" "${DEFINITIONS[@]}"
    echo ""
  fi
  if [ ${#IMPORTS[@]} -gt 0 ]; then
    echo "IMPORTS (${#IMPORTS[@]}):"
    printf "  %s\n" "${IMPORTS[@]}"
    echo ""
  fi
  if [ ${#PARAMETERS[@]} -gt 0 ]; then
    echo "PARAMETERS (${#PARAMETERS[@]}):"
    printf "  %s\n" "${PARAMETERS[@]}"
    echo ""
  fi
  if [ ${#REFERENCES[@]} -gt 0 ]; then
    echo "REFERENCES (${#REFERENCES[@]}):"
    printf "  %s\n" "${REFERENCES[@]}"
    echo ""
  fi
fi
