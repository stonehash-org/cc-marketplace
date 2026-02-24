#!/usr/bin/env bash
# undo.sh — Backup/rollback system for refactoring operations.
#
# Usage:
#   undo.sh --list              Show all available backups
#   undo.sh --last              Undo the most recent backup
#   undo.sh --id BACKUP_ID      Undo a specific backup by ID
#   undo.sh --clean [--days N]  Remove backups older than N days (default: 7)
#
# Library mode (for sourcing by other scripts):
#   source "$(dirname "$0")/undo.sh" --lib-mode
#   Then call: create_backup <operation_name> <file1> [file2 ...]
#              restore_backup <backup_id>
#              list_backups
#              clean_backups [days]

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BACKUP_DIR=".refactor-backup"

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

_log()  { printf '%s\n' "$*"; }
_info() { printf '[info]  %s\n' "$*"; }
_warn() { printf '[warn]  %s\n' "$*" >&2; }
_err()  { printf '[error] %s\n' "$*" >&2; }

_require_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        _err "No backup directory found at: ${BACKUP_DIR}"
        _err "No backups exist in the current working directory."
        exit 1
    fi
}

# Emit a compact ISO-8601-ish timestamp safe for directory names.
_timestamp() {
    date +"%Y%m%d-%H%M%S"
}

# Resolve a path relative to the current working directory, stripping any
# leading "./" so stored paths are clean.
_rel_path() {
    local p
    p=$(realpath --relative-to="$(pwd)" "$1" 2>/dev/null || python3 -c "
import os, sys
print(os.path.relpath(sys.argv[1]))
" "$1")
    echo "${p#./}"
}

# ---------------------------------------------------------------------------
# create_backup <operation_name> <file1> [file2 ...]
#
# Called by other refactoring scripts to snapshot files before they are
# modified.  Prints the backup_id (timestamp string) to stdout so callers
# can record it.
# ---------------------------------------------------------------------------
create_backup() {
    local operation="${1:?create_backup requires an operation name}"
    shift
    local files=("$@")

    if [[ ${#files[@]} -eq 0 ]]; then
        _warn "create_backup: no files supplied — nothing to back up."
        return 1
    fi

    local backup_id
    backup_id=$(_timestamp)
    local backup_path="${BACKUP_DIR}/${backup_id}"

    mkdir -p "$backup_path"

    # Build the JSON files array while copying each file.
    local files_json="["
    local first=1
    local action entry rel_path dest_dir

    for f in "${files[@]}"; do
        if [[ ! -e "$f" ]]; then
            action="missing"
            rel_path=$(_rel_path "$f")
        else
            action="modified"
            rel_path=$(_rel_path "$f")
            dest_dir="${backup_path}/$(dirname "$rel_path")"
            mkdir -p "$dest_dir"
            cp -p "$f" "${backup_path}/${rel_path}"
        fi

        # Escape double-quotes in paths (unlikely but safe).
        local escaped_path="${rel_path//\"/\\\"}"

        if [[ $first -eq 1 ]]; then
            first=0
        else
            files_json+=","
        fi
        files_json+="{\"path\":\"${escaped_path}\",\"action\":\"${action}\"}"
    done
    files_json+="]"

    # Write metadata.json
    local timestamp_iso
    timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    cat > "${backup_path}/metadata.json" <<EOF
{
  "id": "${backup_id}",
  "timestamp": "${timestamp_iso}",
  "operation": "${operation//\"/\\\"}",
  "files": ${files_json}
}
EOF

    _info "Backup created: ${backup_id}  (${#files[@]} file(s), operation: ${operation})"
    echo "$backup_id"
}

# ---------------------------------------------------------------------------
# restore_backup <backup_id>
#
# Reads the named backup's metadata.json and copies each saved file back to
# its original location.
# ---------------------------------------------------------------------------
restore_backup() {
    local backup_id="${1:?restore_backup requires a backup_id}"
    local backup_path="${BACKUP_DIR}/${backup_id}"

    if [[ ! -d "$backup_path" ]]; then
        _err "Backup not found: ${backup_id}"
        _err "Run --list to see available backups."
        exit 1
    fi

    local meta="${backup_path}/metadata.json"
    if [[ ! -f "$meta" ]]; then
        _err "metadata.json missing in backup ${backup_id} — cannot restore."
        exit 1
    fi

    _info "Restoring backup: ${backup_id}"

    # Parse paths from metadata.json using python3 (no jq dependency).
    local paths
    paths=$(python3 - "$meta" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
for f in data.get("files", []):
    print(f["path"], f["action"])
PYEOF
)

    local restored=0 skipped=0

    while IFS=" " read -r rel_path action; do
        [[ -z "$rel_path" ]] && continue

        local src="${backup_path}/${rel_path}"
        local dst="${rel_path}"

        if [[ "$action" == "missing" ]]; then
            _info "  skip  (was missing at backup time): ${rel_path}"
            (( skipped++ )) || true
            continue
        fi

        if [[ ! -f "$src" ]]; then
            _warn "  no saved copy found for: ${rel_path}"
            (( skipped++ )) || true
            continue
        fi

        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
        _info "  restored: ${rel_path}"
        (( restored++ )) || true
    done <<< "$paths"

    _info "Done. Restored: ${restored}, Skipped: ${skipped}."
}

# ---------------------------------------------------------------------------
# list_backups
#
# Prints a formatted table of all backups in BACKUP_DIR.
# ---------------------------------------------------------------------------
list_backups() {
    _require_backup_dir

    local entries=()
    while IFS= read -r -d '' d; do
        [[ -f "${d}/metadata.json" ]] && entries+=("$d")
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    if [[ ${#entries[@]} -eq 0 ]]; then
        _log "No backups found in ${BACKUP_DIR}/"
        return 0
    fi

    printf '%-20s  %-22s  %-30s  %s\n' "BACKUP ID" "TIMESTAMP" "OPERATION" "FILES"
    printf '%-20s  %-22s  %-30s  %s\n' "$(printf '%0.s-' {1..20})" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..30})" "-----"

    for d in "${entries[@]}"; do
        local meta="${d}/metadata.json"
        python3 - "$meta" <<'PYEOF'
import json, sys, os
data = json.load(open(sys.argv[1]))
bid       = data.get("id", "?")
ts        = data.get("timestamp", "?")
op        = data.get("operation", "?")
n_files   = len(data.get("files", []))
print(f"{bid:<20}  {ts:<22}  {op:<30}  {n_files}")
PYEOF
    done
}

# ---------------------------------------------------------------------------
# clean_backups [days]
#
# Removes backup directories older than <days> days (default 7).
# ---------------------------------------------------------------------------
clean_backups() {
    local days="${1:-7}"
    _require_backup_dir

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        _err "clean_backups: days must be a non-negative integer, got: ${days}"
        exit 1
    fi

    _info "Removing backups older than ${days} day(s) from ${BACKUP_DIR}/"

    local removed=0

    while IFS= read -r -d '' d; do
        local bid
        bid=$(basename "$d")
        _info "  removing: ${bid}"
        rm -rf "$d"
        (( removed++ )) || true
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
                 -not -newer <(date -d "-${days} days" +%Y%m%d 2>/dev/null || \
                               date -v "-${days}d" +%Y%m%d 2>/dev/null || \
                               true) \
                 -print0 2>/dev/null || true)

    # Fallback: use python3 for cross-platform date arithmetic.
    if [[ $removed -eq 0 ]]; then
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local bid
            bid=$(basename "$d")
            _info "  removing: ${bid}"
            rm -rf "$d"
            (( removed++ )) || true
        done < <(python3 - "$BACKUP_DIR" "$days" <<'PYEOF'
import os, sys, datetime
backup_dir = sys.argv[1]
max_age    = int(sys.argv[2])
cutoff     = datetime.datetime.now() - datetime.timedelta(days=max_age)

for entry in sorted(os.listdir(backup_dir)):
    full = os.path.join(backup_dir, entry)
    if not os.path.isdir(full):
        continue
    mtime = datetime.datetime.fromtimestamp(os.path.getmtime(full))
    if mtime < cutoff:
        print(full)
PYEOF
)
    fi

    _info "Removed ${removed} backup(s)."
}

# ---------------------------------------------------------------------------
# Main entry point — only runs when the script is executed directly.
# When --lib-mode is the first argument the script is being sourced; return
# immediately so the caller gains access to all defined functions.
# ---------------------------------------------------------------------------
main() {
    if [[ "${1:-}" == "--lib-mode" ]]; then
        return 0
    fi

    if [[ $# -eq 0 ]]; then
        _err "No arguments supplied."
        cat >&2 <<'USAGE'
Usage:
  undo.sh --list              Show all available backups
  undo.sh --last              Undo the most recent backup
  undo.sh --id BACKUP_ID      Undo a specific backup by ID
  undo.sh --clean [--days N]  Remove backups older than N days (default: 7)
USAGE
        exit 1
    fi

    local cmd="${1}"
    shift

    case "$cmd" in
        --list)
            list_backups
            ;;

        --last)
            _require_backup_dir
            local latest
            latest=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
                         -not -name '.*' | sort | tail -n 1)
            if [[ -z "$latest" ]]; then
                _err "No backups found in ${BACKUP_DIR}/"
                exit 1
            fi
            restore_backup "$(basename "$latest")"
            ;;

        --id)
            local target_id="${1:?--id requires a BACKUP_ID argument}"
            restore_backup "$target_id"
            ;;

        --clean)
            local clean_days=7
            if [[ "${1:-}" == "--days" ]]; then
                clean_days="${2:?--days requires a number}"
                shift 2
            fi
            clean_backups "$clean_days"
            ;;

        *)
            _err "Unknown argument: ${cmd}"
            exit 1
            ;;
    esac
}

main "$@"
