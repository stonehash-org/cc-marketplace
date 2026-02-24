#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
FEEDBACK_DIR="$PLUGIN_DIR/agent-feedbacks"

SCRIPT_NAME=""
STATUS=""
MESSAGE=""
ERROR_OUTPUT=""
USED_HELP=false
RETRY_COUNT=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --script NAME --status success|fail [options]

Submit agent feedback after using a plugin script.

Options:
  --script NAME       Script name that was used (required)
  --status STATUS     success or fail (required)
  --message MSG       Description of what happened
  --error MSG         Error output from the script
  --used-help         Flag: agent had to check --help before succeeding
  --retries N         Number of retry attempts before success (default: 0)
  -h, --help          Show this help

Example:
  $(basename "$0") --script rename-symbol.sh --status success --message "Renamed userId to accountId, 72 changes"
  $(basename "$0") --script rename-symbol.sh --status fail --error "Unknown option: --from" --used-help --retries 1
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --script)    SCRIPT_NAME="$2"; shift 2 ;;
    --status)    STATUS="$2"; shift 2 ;;
    --message)   MESSAGE="$2"; shift 2 ;;
    --error)     ERROR_OUTPUT="$2"; shift 2 ;;
    --used-help) USED_HELP=true; shift ;;
    --retries)   RETRY_COUNT="$2"; shift 2 ;;
    -h|--help)   usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$SCRIPT_NAME" ] || [ -z "$STATUS" ]; then
  echo "Error: --script and --status are required" >&2
  exit 1
fi

case "$STATUS" in
  success|fail) ;;
  *) echo "Error: --status must be 'success' or 'fail'" >&2; exit 1 ;;
esac

mkdir -p "$FEEDBACK_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_PREFIX=$(date -u +"%Y-%m-%d")

FEEDBACK_FILE="$FEEDBACK_DIR/${DATE_PREFIX}.jsonl"

jq -n -c \
  --arg ts "$TIMESTAMP" \
  --arg script "$SCRIPT_NAME" \
  --arg status "$STATUS" \
  --arg message "$MESSAGE" \
  --arg error "$ERROR_OUTPUT" \
  --argjson used_help "$USED_HELP" \
  --argjson retries "$RETRY_COUNT" \
  '{
    timestamp: $ts,
    script: $script,
    status: $status,
    message: (if $message == "" then null else $message end),
    error: (if $error == "" then null else $error end),
    usedHelp: $used_help,
    retries: $retries
  }' >> "$FEEDBACK_FILE"

echo "Feedback recorded: $SCRIPT_NAME ($STATUS)"
