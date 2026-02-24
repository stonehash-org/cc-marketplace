#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"
source "$SCRIPT_DIR/shared-lib.sh"

SEARCH_PATH=""
FORMAT="text"

usage() {
  cat <<EOF
Usage: $(basename "$0") --path DIR [--format text|json]

Validate source files: detect syntax errors and broken imports.

Options:
  --path DIR      Directory to scan (required)
  --format FMT    Output format: text or json (default: text)
  -h, --help      Show this help

Examples:
  $(basename "$0") --path ./src
  $(basename "$0") --path ./src --format json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   SEARCH_PATH="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SEARCH_PATH" ]; then
  echo "Error: --path is required" >&2
  usage
fi

if [ ! -d "$SEARCH_PATH" ]; then
  echo "Error: '$SEARCH_PATH' is not a directory" >&2
  exit 1
fi

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json'" >&2
  exit 1
fi

EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs" "py" "java" "kt" "kts")

# JS/TS extensions to try when resolving imports
JS_EXTENSIONS=("ts" "tsx" "js" "jsx" "mjs" "cjs")
JS_INDEX_EXTENSIONS=("ts" "js" "tsx" "jsx")

# ── File discovery ────────────────────────────────────────────────────────────

glob_args=()
for ext in "${EXTENSIONS[@]}"; do
  glob_args+=(--glob "*.${ext}")
done

ALL_FILES=$(rg --files "${glob_args[@]}" "$SEARCH_PATH" 2>/dev/null || true)

if [ -z "$ALL_FILES" ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"path":"%s","syntaxErrors":[],"brokenImports":[],"status":"PASS","errorCount":0,"brokenImportCount":0}\n' \
      "$SEARCH_PATH"
  else
    echo "=== Validation Report ==="
    echo ""
    echo "No source files found in '$SEARCH_PATH'."
    echo ""
    echo "STATUS: PASS (0 syntax errors, 0 broken imports)"
  fi
  exit 0
fi

# ── 1. Syntax Error Detection ────────────────────────────────────────────────

# Each entry: file|line|col|type|detail
declare -a SYNTAX_ERRORS=()

while IFS= read -r file; do
  [ -z "$file" ] && continue

  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  # Run tree-sitter parse and capture the S-expression output
  parse_output=$(tree-sitter parse "$file" 2>&1 || true)
  [ -z "$parse_output" ] && continue

  # Look for ERROR or MISSING nodes in the S-expression
  # Format: (ERROR [row, col] - [row, col]) or (MISSING "x" [row, col] - [row, col])
  # Use regex variables for bash 3.2 compatibility
  re_error='\(ERROR[[:space:]]+\[([0-9]+), ([0-9]+)\]'
  re_missing_named='\(MISSING "([^"]*)" \[([0-9]+), ([0-9]+)\]'
  re_missing_bare='\(MISSING[[:space:]]+\[([0-9]+), ([0-9]+)\]'

  while IFS= read -r line; do
    if [[ "$line" =~ $re_error ]]; then
      row="${BASH_REMATCH[1]}"
      col="${BASH_REMATCH[2]}"
      one_based_line=$(( row + 1 ))
      one_based_col=$(( col + 1 ))
      SYNTAX_ERRORS+=("${file}|${one_based_line}|${one_based_col}|ERROR|ERROR node")
    elif [[ "$line" =~ $re_missing_named ]]; then
      expected="${BASH_REMATCH[1]}"
      row="${BASH_REMATCH[2]}"
      col="${BASH_REMATCH[3]}"
      one_based_line=$(( row + 1 ))
      one_based_col=$(( col + 1 ))
      SYNTAX_ERRORS+=("${file}|${one_based_line}|${one_based_col}|MISSING|MISSING node (expected '${expected}')")
    elif [[ "$line" =~ $re_missing_bare ]]; then
      row="${BASH_REMATCH[1]}"
      col="${BASH_REMATCH[2]}"
      one_based_line=$(( row + 1 ))
      one_based_col=$(( col + 1 ))
      SYNTAX_ERRORS+=("${file}|${one_based_line}|${one_based_col}|MISSING|MISSING node")
    fi
  done <<< "$parse_output"
done <<< "$ALL_FILES"

# ── 2. Broken Import Detection ───────────────────────────────────────────────

# Each entry: file|line|importPath
declare -a BROKEN_IMPORTS=()

# Resolve a relative JS/TS import path to an existing file
# Returns 0 if resolved, 1 if not found
resolve_js_import() {
  local base_dir="$1"
  local import_path="$2"

  # Direct file match (already has extension)
  if [ -f "${base_dir}/${import_path}" ]; then
    return 0
  fi

  # Try each extension
  for ext in "${JS_EXTENSIONS[@]}"; do
    if [ -f "${base_dir}/${import_path}.${ext}" ]; then
      return 0
    fi
  done

  # Try index files in directory
  for ext in "${JS_INDEX_EXTENSIONS[@]}"; do
    if [ -f "${base_dir}/${import_path}/index.${ext}" ]; then
      return 0
    fi
  done

  return 1
}

# Resolve a Python relative import
resolve_py_import() {
  local base_dir="$1"
  local module_path="$2"

  # Convert dots to slashes for the module path
  local fs_path="${module_path//./\/}"

  if [ -f "${base_dir}/${fs_path}.py" ]; then
    return 0
  fi

  if [ -f "${base_dir}/${fs_path}/__init__.py" ]; then
    return 0
  fi

  return 1
}

# Resolve a Java import
resolve_java_import() {
  local search_root="$1"
  local import_path="$2"

  # Convert dots to slashes: com.example.Foo -> com/example/Foo.java
  local fs_path="${import_path//./\/}.java"

  # Search from the project root and common source directories
  if [ -f "${search_root}/${fs_path}" ]; then
    return 0
  fi

  # Try common Java source layouts
  local dir
  for dir in "src/main/java" "src" "java"; do
    if [ -f "${search_root}/${dir}/${fs_path}" ]; then
      return 0
    fi
  done

  return 1
}

# Check if an import path is external (not relative)
is_external_import() {
  local lang="$1"
  local import_path="$2"

  case "$lang" in
    typescript)
      # Relative imports start with . or /
      if [[ "$import_path" == .* ]] || [[ "$import_path" == /* ]]; then
        return 1  # not external
      fi
      return 0  # external
      ;;
    python)
      # Relative imports start with a dot
      if [[ "$import_path" == .* ]]; then
        return 1  # not external
      fi
      return 0  # external
      ;;
    java)
      # All Java imports are package-based; skip standard library and common packages
      if [[ "$import_path" == java.* ]] || [[ "$import_path" == javax.* ]] || \
         [[ "$import_path" == org.* ]] || [[ "$import_path" == com.google.* ]] || \
         [[ "$import_path" == com.sun.* ]]; then
        return 0  # external
      fi
      return 1  # treat as internal (attempt resolution)
      ;;
  esac
  return 0
}

while IFS= read -r file; do
  [ -z "$file" ] && continue

  lang=$(detect_language "$file")
  [ -z "$lang" ] && continue

  file_dir=$(dirname "$file")

  case "$lang" in
    typescript)
      # Match: import ... from 'path'  |  import 'path'  |  require('path')
      # Use ripgrep to find import/require lines with line numbers
      import_lines=$(rg -n "^[[:space:]]*(import\b|.*require\s*\()" "$file" 2>/dev/null || true)
      [ -z "$import_lines" ] && continue

      while IFS= read -r match_line; do
        [ -z "$match_line" ] && continue

        # Extract line number (before first colon)
        line_num="${match_line%%:*}"
        line_content="${match_line#*:}"

        # Extract the import path from quotes
        import_path=""
        if [[ "$line_content" =~ from[[:space:]]+[\'\"]([^\'\"]+)[\'\"] ]]; then
          import_path="${BASH_REMATCH[1]}"
        elif [[ "$line_content" =~ require\([[:space:]]*[\'\"]([^\'\"]+)[\'\"] ]]; then
          import_path="${BASH_REMATCH[1]}"
        elif [[ "$line_content" =~ import[[:space:]]+[\'\"]([^\'\"]+)[\'\"] ]]; then
          import_path="${BASH_REMATCH[1]}"
        fi

        [ -z "$import_path" ] && continue

        # Skip external packages
        if is_external_import "$lang" "$import_path"; then
          continue
        fi

        # Resolve relative import
        if ! resolve_js_import "$file_dir" "$import_path"; then
          BROKEN_IMPORTS+=("${file}|${line_num}|${import_path}")
        fi
      done <<< "$import_lines"
      ;;

    python)
      # Match: from .module import x  |  from . import x
      import_lines=$(rg -n "^[[:space:]]*(from[[:space:]]+\.[[:space:][:alnum:]_.]*[[:space:]]+import)" "$file" 2>/dev/null || true)
      [ -z "$import_lines" ] && continue

      while IFS= read -r match_line; do
        [ -z "$match_line" ] && continue

        line_num="${match_line%%:*}"
        line_content="${match_line#*:}"

        # Extract the relative module path
        # from .module import x  -> .module
        # from ..module import x -> ..module
        # from . import x        -> .
        if [[ "$line_content" =~ from[[:space:]]+(\.+[[:alnum:]_]*)[[:space:]]+import ]]; then
          raw_path="${BASH_REMATCH[1]}"

          # Count leading dots for parent directory levels
          dots="${raw_path%%[^.]*}"
          dot_count=${#dots}
          module_part="${raw_path#$dots}"

          # Build the base directory (go up dot_count - 1 levels)
          resolve_dir="$file_dir"
          i=1
          while [ "$i" -lt "$dot_count" ]; do
            resolve_dir=$(dirname "$resolve_dir")
            i=$(( i + 1 ))
          done

          # If there is a module part, try to resolve it
          if [ -n "$module_part" ]; then
            if ! resolve_py_import "$resolve_dir" "$module_part"; then
              BROKEN_IMPORTS+=("${file}|${line_num}|${raw_path}")
            fi
          fi
        fi
      done <<< "$import_lines"
      ;;

    java)
      # Match: import com.example.Foo;
      import_lines=$(rg -n "^[[:space:]]*import[[:space:]]+(static[[:space:]]+)?([a-zA-Z][a-zA-Z0-9_.]+)\s*;" "$file" 2>/dev/null || true)
      [ -z "$import_lines" ] && continue

      while IFS= read -r match_line; do
        [ -z "$match_line" ] && continue

        line_num="${match_line%%:*}"
        line_content="${match_line#*:}"

        # Extract import path
        if [[ "$line_content" =~ import[[:space:]]+(static[[:space:]]+)?([a-zA-Z][a-zA-Z0-9_.]+) ]]; then
          import_path="${BASH_REMATCH[2]}"

          # Skip wildcard imports
          [[ "$import_path" == *".*" ]] && continue

          # Skip external packages
          if is_external_import "$lang" "$import_path"; then
            continue
          fi

          # Resolve from project root
          if ! resolve_java_import "$SEARCH_PATH" "$import_path"; then
            BROKEN_IMPORTS+=("${file}|${line_num}|${import_path}")
          fi
        fi
      done <<< "$import_lines"
      ;;
  esac
done <<< "$ALL_FILES"

# ── Output ────────────────────────────────────────────────────────────────────

error_count=${#SYNTAX_ERRORS[@]}
broken_count=${#BROKEN_IMPORTS[@]}

if [ $(( error_count + broken_count )) -eq 0 ]; then
  status="PASS"
else
  status="FAIL"
fi

if [ "$FORMAT" = "json" ]; then
  # Build JSON output
  if command -v jq &>/dev/null; then
    # Build syntax errors array
    se_json="["
    first=true
    for entry in "${SYNTAX_ERRORS[@]+"${SYNTAX_ERRORS[@]}"}"; do
      [ -z "$entry" ] && continue
      IFS='|' read -r f ln col typ detail <<< "$entry"
      obj=$(jq -n \
        --arg file "$f" \
        --argjson line "$ln" \
        --argjson col "$col" \
        --arg type "$typ" \
        '{file: $file, line: $line, col: $col, type: $type}')
      if $first; then
        se_json="${se_json}${obj}"
        first=false
      else
        se_json="${se_json},${obj}"
      fi
    done
    se_json="${se_json}]"

    # Build broken imports array
    bi_json="["
    first=true
    for entry in "${BROKEN_IMPORTS[@]+"${BROKEN_IMPORTS[@]}"}"; do
      [ -z "$entry" ] && continue
      IFS='|' read -r f ln imp <<< "$entry"
      obj=$(jq -n \
        --arg file "$f" \
        --argjson line "$ln" \
        --arg importPath "$imp" \
        '{file: $file, line: $line, importPath: $importPath}')
      if $first; then
        bi_json="${bi_json}${obj}"
        first=false
      else
        bi_json="${bi_json},${obj}"
      fi
    done
    bi_json="${bi_json}]"

    # Combine into final object
    jq -n \
      --arg path "$SEARCH_PATH" \
      --argjson syntaxErrors "$se_json" \
      --argjson brokenImports "$bi_json" \
      --arg status "$status" \
      --argjson errorCount "$error_count" \
      --argjson brokenImportCount "$broken_count" \
      '{
        path: $path,
        syntaxErrors: $syntaxErrors,
        brokenImports: $brokenImports,
        status: $status,
        errorCount: $errorCount,
        brokenImportCount: $brokenImportCount
      }'
  else
    # Fallback: manual JSON
    printf '{\n'
    printf '  "path": "%s",\n' "$SEARCH_PATH"
    printf '  "syntaxErrors": ['
    first=true
    for entry in "${SYNTAX_ERRORS[@]+"${SYNTAX_ERRORS[@]}"}"; do
      [ -z "$entry" ] && continue
      IFS='|' read -r f ln col typ detail <<< "$entry"
      f_escaped="${f//\"/\\\"}"
      $first || printf ','
      printf '\n    {"file":"%s","line":%s,"col":%s,"type":"%s"}' \
        "$f_escaped" "$ln" "$col" "$typ"
      first=false
    done
    printf '\n  ],\n'
    printf '  "brokenImports": ['
    first=true
    for entry in "${BROKEN_IMPORTS[@]+"${BROKEN_IMPORTS[@]}"}"; do
      [ -z "$entry" ] && continue
      IFS='|' read -r f ln imp <<< "$entry"
      f_escaped="${f//\"/\\\"}"
      imp_escaped="${imp//\"/\\\"}"
      $first || printf ','
      printf '\n    {"file":"%s","line":%s,"importPath":"%s"}' \
        "$f_escaped" "$ln" "$imp_escaped"
      first=false
    done
    printf '\n  ],\n'
    printf '  "status": "%s",\n' "$status"
    printf '  "errorCount": %s,\n' "$error_count"
    printf '  "brokenImportCount": %s\n' "$broken_count"
    printf '}\n'
  fi
else
  echo "=== Validation Report ==="
  echo ""

  if [ "$error_count" -gt 0 ]; then
    echo "SYNTAX ERRORS (${error_count}):"
    for entry in "${SYNTAX_ERRORS[@]}"; do
      IFS='|' read -r f ln col typ detail <<< "$entry"
      printf '  %s:%s:%s  %s\n' "$f" "$ln" "$col" "$detail"
    done
    echo ""
  fi

  if [ "$broken_count" -gt 0 ]; then
    echo "BROKEN IMPORTS (${broken_count}):"
    for entry in "${BROKEN_IMPORTS[@]}"; do
      IFS='|' read -r f ln imp <<< "$entry"
      src_line=$(get_line "$f" "$ln" 2>/dev/null || true)
      src_trimmed="${src_line#"${src_line%%[![:space:]]*}"}"
      printf "  %s:%s  %s — file not found\n" "$f" "$ln" "$src_trimmed"
    done
    echo ""
  fi

  if [ "$status" = "PASS" ]; then
    echo "STATUS: PASS (0 syntax errors, 0 broken imports)"
  else
    echo "STATUS: FAIL (${error_count} syntax error$([ "$error_count" -ne 1 ] && echo 's' || true), ${broken_count} broken import$([ "$broken_count" -ne 1 ] && echo 's' || true))"
  fi
fi
