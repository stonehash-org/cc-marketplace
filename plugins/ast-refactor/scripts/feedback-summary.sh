#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
FEEDBACK_DIR="$PLUGIN_DIR/agent-feedbacks"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--days N] [--script NAME] [--format text|json]

Summarize agent feedback.

Options:
  --days N          Show last N days (default: all)
  --script NAME     Filter by script name
  --format FMT      Output format: text or json (default: text)
  -h, --help        Show this help
EOF
  exit 0
}

DAYS=""
FILTER_SCRIPT=""
FORMAT="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)    DAYS="$2"; shift 2 ;;
    --script)  FILTER_SCRIPT="$2"; shift 2 ;;
    --format)  FORMAT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$FEEDBACK_DIR" ] || [ -z "$(ls "$FEEDBACK_DIR"/*.jsonl 2>/dev/null)" ]; then
  if [ "$FORMAT" = "json" ]; then
    echo '{"total":0,"success":0,"fail":0,"scripts":[]}'
  else
    echo "No feedback data found."
  fi
  exit 0
fi

# Collect all JSONL lines
ALL_LINES=""
for f in "$FEEDBACK_DIR"/*.jsonl; do
  ALL_LINES+="$(cat "$f")"$'\n'
done

# Filter by days if specified
if [ -n "$DAYS" ]; then
  if [[ "$OSTYPE" == darwin* ]]; then
    CUTOFF=$(date -u -v-"${DAYS}d" +"%Y-%m-%d")
  else
    CUTOFF=$(date -u -d "${DAYS} days ago" +"%Y-%m-%d")
  fi
  ALL_LINES=$(echo "$ALL_LINES" | jq -c --arg cutoff "$CUTOFF" 'select(.timestamp >= $cutoff)' 2>/dev/null || true)
fi

# Filter by script if specified
if [ -n "$FILTER_SCRIPT" ]; then
  ALL_LINES=$(echo "$ALL_LINES" | jq -c --arg s "$FILTER_SCRIPT" 'select(.script == $s)' 2>/dev/null || true)
fi

[ -z "$ALL_LINES" ] && {
  if [ "$FORMAT" = "json" ]; then
    echo '{"total":0,"success":0,"fail":0,"scripts":[]}'
  else
    echo "No matching feedback found."
  fi
  exit 0
}

if [ "$FORMAT" = "json" ]; then
  echo "$ALL_LINES" | jq -s '
    {
      total: length,
      success: [.[] | select(.status == "success")] | length,
      fail: [.[] | select(.status == "fail")] | length,
      helpNeeded: [.[] | select(.usedHelp == true)] | length,
      totalRetries: [.[] | .retries] | add,
      byScript: (group_by(.script) | map({
        script: .[0].script,
        total: length,
        success: [.[] | select(.status == "success")] | length,
        fail: [.[] | select(.status == "fail")] | length,
        helpNeeded: [.[] | select(.usedHelp == true)] | length
      }) | sort_by(-.fail))
    }'
else
  TOTAL=$(echo "$ALL_LINES" | grep -c '.' || echo 0)
  SUCCESS=$(echo "$ALL_LINES" | jq -r 'select(.status=="success")' 2>/dev/null | grep -c '"status"' || echo 0)
  FAIL=$(echo "$ALL_LINES" | jq -r 'select(.status=="fail")' 2>/dev/null | grep -c '"status"' || echo 0)
  HELP_NEEDED=$(echo "$ALL_LINES" | jq -r 'select(.usedHelp==true)' 2>/dev/null | grep -c '"usedHelp"' || echo 0)

  echo "=== Agent Feedback Summary ==="
  echo ""
  echo "Total: $TOTAL  Success: $SUCCESS  Fail: $FAIL  Help needed: $HELP_NEEDED"
  echo ""
  echo "--- By Script ---"
  echo "$ALL_LINES" | jq -r '.script' 2>/dev/null | sort | uniq -c | sort -rn | while read -r count name; do
    fail_count=$(echo "$ALL_LINES" | jq -r --arg s "$name" 'select(.script==$s and .status=="fail") | .script' 2>/dev/null | wc -l | tr -d ' ')
    echo "  $name: $count uses, $fail_count failures"
  done
  echo ""

  # Show recent errors
  ERRORS=$(echo "$ALL_LINES" | jq -r 'select(.status=="fail") | "\(.timestamp) \(.script): \(.error // .message // "no details")"' 2>/dev/null || true)
  if [ -n "$ERRORS" ]; then
    echo "--- Recent Errors ---"
    echo "$ERRORS" | tail -10
  fi
fi
