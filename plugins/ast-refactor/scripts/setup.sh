#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PLUGIN_DIR/queries"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if ! command -v tree-sitter &>/dev/null; then
  info "tree-sitter CLI not found. Installing via Homebrew..."
  if command -v brew &>/dev/null; then
    brew install tree-sitter
  elif command -v npm &>/dev/null; then
    npm install -g tree-sitter-cli
  else
    error "Neither brew nor npm available. Install tree-sitter manually:"
    error "  brew install tree-sitter"
    error "  OR npm install -g tree-sitter-cli"
    exit 1
  fi
fi

TS_VERSION=$(tree-sitter --version 2>/dev/null || echo "unknown")
info "tree-sitter version: $TS_VERSION"

TS_DIR="${HOME}/.tree-sitter"
if [ ! -d "$TS_DIR" ]; then
  mkdir -p "$TS_DIR"
fi

LANGUAGES=("typescript" "python" "java")
GRAMMAR_REPOS=(
  "tree-sitter-typescript:https://github.com/tree-sitter/tree-sitter-typescript"
  "tree-sitter-python:https://github.com/tree-sitter/tree-sitter-python"
  "tree-sitter-java:https://github.com/tree-sitter/tree-sitter-java"
)

PARSERS_DIR="${TS_DIR}/parsers"
mkdir -p "$PARSERS_DIR"

for entry in "${GRAMMAR_REPOS[@]}"; do
  name="${entry%%:*}"
  url="${entry#*:}"
  target="$PARSERS_DIR/$name"
  if [ -d "$target" ]; then
    info "Grammar $name already exists"
  else
    info "Cloning $name..."
    git clone --depth 1 "$url" "$target"
  fi
done

for lang in "${LANGUAGES[@]}"; do
  query_file="$QUERIES_DIR/$lang/symbols.scm"
  if [ -f "$query_file" ]; then
    info "Query file for $lang: OK"
  else
    warn "Query file missing: $query_file"
  fi
done

info "Setup complete."
echo ""
echo "Supported languages: ${LANGUAGES[*]}"
echo "Parsers directory: $PARSERS_DIR"
echo "Queries directory: $QUERIES_DIR"
