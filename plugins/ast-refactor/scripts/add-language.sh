#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

LANG=""
GRAMMAR_URL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --lang LANGUAGE [--grammar-url URL]

Add a new language to the refactoring tool.
Installs the tree-sitter grammar and creates a template query file.

Options:
  --lang LANGUAGE      Language name (e.g., rust, go, ruby) (required)
  --grammar-url URL    Custom grammar repo URL (optional, auto-detected for common languages)
  -h, --help           Show this help

Known languages (auto-detected grammar URLs):
  rust, go, ruby, c, cpp, csharp, swift, kotlin, php, scala

Example:
  $(basename "$0") --lang rust
  $(basename "$0") --lang custom-lang --grammar-url https://github.com/user/tree-sitter-custom
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)        LANG="$2"; shift 2 ;;
    --grammar-url) GRAMMAR_URL="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -z "$LANG" ] && { echo "Error: --lang is required" >&2; exit 1; }

if [ -z "$GRAMMAR_URL" ]; then
  case "$LANG" in
    rust)    GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-rust" ;;
    go)      GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-go" ;;
    ruby)    GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-ruby" ;;
    c)       GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-c" ;;
    cpp)     GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-cpp" ;;
    csharp)  GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-c-sharp" ;;
    swift)   GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-swift" ;;
    kotlin)  GRAMMAR_URL="https://github.com/fwcd/tree-sitter-kotlin" ;;
    php)     GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-php" ;;
    scala)   GRAMMAR_URL="https://github.com/tree-sitter/tree-sitter-scala" ;;
    *)
      echo "Error: Unknown language '$LANG'. Provide --grammar-url" >&2
      exit 1
      ;;
  esac
fi

TS_DIR="${HOME}/.tree-sitter"
PARSERS_DIR="${TS_DIR}/parsers"
GRAMMAR_NAME="tree-sitter-${LANG}"
TARGET="$PARSERS_DIR/$GRAMMAR_NAME"

mkdir -p "$PARSERS_DIR"

if [ -d "$TARGET" ]; then
  echo "Grammar $GRAMMAR_NAME already installed at $TARGET"
else
  echo "Installing grammar: $GRAMMAR_NAME..."
  git clone --depth 1 "$GRAMMAR_URL" "$TARGET"
  echo "Grammar installed."
fi

QUERY_DIR="$QUERIES_DIR/$LANG"
QUERY_FILE="$QUERY_DIR/symbols.scm"

mkdir -p "$QUERY_DIR"

if [ -f "$QUERY_FILE" ]; then
  echo "Query file already exists: $QUERY_FILE"
else
  cat > "$QUERY_FILE" <<'QUERY'
; Symbol queries for LANGUAGE
; Customize these patterns for your language's AST structure.
; Run `tree-sitter parse <file>` to see the AST and identify node types.

; Variable/constant definitions
; (variable_declarator name: (identifier) @symbol.definition)

; Function definitions
; (function_definition name: (identifier) @symbol.definition)

; Class/type definitions
; (class_definition name: (identifier) @symbol.definition)

; Parameter names
; (parameter name: (identifier) @symbol.parameter)

; Import statements
; (import_declaration (identifier) @symbol.import)

; All identifier references (general)
(identifier) @symbol.reference

; String literals (EXCLUDE from renaming)
(string_literal) @string.content

; Comments (EXCLUDE from renaming)
(comment) @comment.content
QUERY

  sed -i '' "s/LANGUAGE/$LANG/g" "$QUERY_FILE"
  echo "Created template query: $QUERY_FILE"
  echo ""
  echo "NEXT STEPS:"
  echo "  1. Run: tree-sitter parse <sample-file> to see AST node types"
  echo "  2. Edit $QUERY_FILE to add language-specific patterns"
  echo "  3. Test with: find-references.sh --symbol <name> --path <dir>"
fi

LANGS_FILE="$PLUGIN_DIR/skills/ast-refactor/references/supported-languages.md"
if [ -f "$LANGS_FILE" ]; then
  if ! grep -q "| $LANG " "$LANGS_FILE"; then
    echo "| $LANG | \`*.${LANG}\` | \`queries/${LANG}/symbols.scm\` | template |" >> "$LANGS_FILE"
    echo "Updated supported-languages.md"
  fi
fi

echo ""
echo "Language '$LANG' added successfully."
