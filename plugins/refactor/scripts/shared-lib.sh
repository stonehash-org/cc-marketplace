#!/usr/bin/env bash
# Shared library for refactor plugin scripts
# Usage: source "$(dirname "$0")/shared-lib.sh"

# Resolve plugin paths
SHARED_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_PLUGIN_DIR="$(dirname "$SHARED_SCRIPT_DIR")"
SHARED_QUERIES_DIR="$SHARED_PLUGIN_DIR/queries"

# Supported extensions
REFACTOR_EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# Map file extension to language
detect_language() {
  local file="$1"
  case "$file" in
    *.ts|*.tsx)             echo "typescript" ;;
    *.js|*.jsx|*.mjs|*.cjs) echo "typescript" ;;
    *.py)                   echo "python" ;;
    *.java)                 echo "java" ;;
    *.kt|*.kts)             echo "kotlin" ;;
    *)                      echo "" ;;
  esac
}

# Get query file path for a language
get_query_file() {
  local lang="$1"
  local query_name="${2:-symbols}"
  echo "$SHARED_QUERIES_DIR/$lang/${query_name}.scm"
}

# Run tree-sitter query and parse output into structured format
# Output: tab-separated lines: capture_name\trow\tcol\ttext
run_query() {
  local query_file="$1"
  local source_file="$2"

  [ ! -f "$query_file" ] && return 1

  local ts_output
  ts_output=$(tree-sitter query "$query_file" "$source_file" 2>/dev/null || true)
  [ -z "$ts_output" ] && return 1

  while IFS= read -r line; do
    local capture="" row="" col="" text=""
    # tree-sitter 0.26+ format: "capture: N - symbol.name, start: (row, col), end: (row, col), text: `text`"
    local re_v026='capture: [0-9]+ - ([a-z_.]+), start: \(([0-9]+), ([0-9]+)\).* text: `([^`]*)`'
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
    printf '%s\t%s\t%s\t%s\n' "$capture" "$row" "$col" "$text"
  done <<< "$ts_output"
}

# Find all source files in a directory
find_source_files() {
  local dir="$1"
  local ext_globs=""
  for ext in "${REFACTOR_EXTENSIONS[@]}"; do
    ext_globs+="--glob '*.${ext}' "
  done
  eval "rg --files $dir $ext_globs 2>/dev/null" | sort
}

# Check if a capture is a string or comment (should be excluded)
is_excludable() {
  local capture="$1"
  [[ "$capture" == string.* ]] || [[ "$capture" == comment.* ]]
}

# Load .refactorrc config if present
load_config() {
  local search_dir="${1:-.}"
  local config_file="$search_dir/.refactorrc"
  if [ -f "$config_file" ] && command -v jq &>/dev/null; then
    # Export config values as REFACTOR_* env vars
    local excludes
    excludes=$(jq -r '.exclude[]? // empty' "$config_file" 2>/dev/null | tr '\n' '|')
    [ -n "$excludes" ] && export REFACTOR_EXCLUDE_PATTERN="${excludes%|}"

    local backup
    backup=$(jq -r '.backup // empty' "$config_file" 2>/dev/null)
    [ "$backup" = "true" ] && export REFACTOR_BACKUP=true

    local git_int
    git_int=$(jq -r '.git_integration // empty' "$config_file" 2>/dev/null)
    [ "$git_int" = "true" ] && export REFACTOR_GIT=true

    local validate
    validate=$(jq -r '.validate_after_rename // empty' "$config_file" 2>/dev/null)
    [ "$validate" = "true" ] && export REFACTOR_VALIDATE=true

    local langs
    langs=$(jq -r '.languages[]? // empty' "$config_file" 2>/dev/null | tr '\n' '|')
    [ -n "$langs" ] && export REFACTOR_LANGUAGES="${langs%|}"

    # Custom extensions per language
    local custom_exts
    custom_exts=$(jq -r '.extensions | to_entries[]? | "\(.key):\(.value | join(","))"' "$config_file" 2>/dev/null || true)
    [ -n "$custom_exts" ] && export REFACTOR_CUSTOM_EXTENSIONS="$custom_exts"
  fi
}

# Apply config values as defaults (call after parsing script args)
apply_config_defaults() {
  # If --git not explicitly set but config says git_integration=true
  if [ "${GIT_MODE:-}" = "false" ] && [ "${REFACTOR_GIT:-}" = "true" ]; then
    GIT_MODE=true
  fi
  # If backup not explicitly set but config says backup=true
  if [ "${BACKUP_MODE:-}" = "false" ] && [ "${REFACTOR_BACKUP:-}" = "true" ]; then
    BACKUP_MODE=true
  fi
}

# Get line content from a file (1-indexed)
get_line() {
  local file="$1"
  local line_num="$2"
  sed -n "${line_num}p" "$file"
}

# Classify a symbol type from source line context
classify_symbol() {
  local lang="$1"
  local line_content="$2"

  case "$lang" in
    typescript)
      if echo "$line_content" | grep -qE '^\s*(export\s+)?(async\s+)?function\s'; then
        echo "function"
      elif echo "$line_content" | grep -qE '=>'; then
        echo "function"
      elif echo "$line_content" | grep -qE '^\s*(export\s+)?(abstract\s+)?class\s'; then
        echo "class"
      elif echo "$line_content" | grep -qE '^\s*(export\s+)?interface\s'; then
        echo "interface"
      else
        echo "variable"
      fi
      ;;
    python)
      if echo "$line_content" | grep -qE '^\s*(async\s+)?def\s'; then
        echo "function"
      elif echo "$line_content" | grep -qE '^\s*class\s'; then
        echo "class"
      else
        echo "variable"
      fi
      ;;
    java)
      if echo "$line_content" | grep -qE '^\s*(public|private|protected|static|abstract|final|synchronized|native).*\('; then
        echo "function"
      elif echo "$line_content" | grep -qE '^\s*(public|private|protected|abstract|final)?\s*(class|interface|enum)\s'; then
        echo "class"
      else
        echo "variable"
      fi
      ;;
    kotlin)
      if echo "$line_content" | grep -qE '^\s*(override\s+)?(suspend\s+)?(fun)\s'; then
        echo "function"
      elif echo "$line_content" | grep -qE '^\s*(open\s+|data\s+|sealed\s+|abstract\s+|inner\s+)*(class|interface|object)\s'; then
        echo "class"
      else
        echo "variable"
      fi
      ;;
    *)
      echo "unknown"
      ;;
  esac
}
