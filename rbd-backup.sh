#!/bin/bash
set -euo pipefail

RBD_POOL="${RBD_POOL:-}"
RBD_IMAGES="${RBD_IMAGES:-}"
RBD_EXPORT_ROOT="${RBD_EXPORT_ROOT:-/mnt/unraid/Backup/rbd}"
RBD_LOG_FILE="${RBD_LOG_FILE:-/var/log/rbd-backup.log}"
RBD_CEPH_ID="${RBD_CEPH_ID:-}"
RBD_KEYRING="${RBD_KEYRING:-}"
RBD_CONF="${RBD_CONF:-}"
RBD_RETENTION_DAILY="${RBD_RETENTION_DAILY:-30}"
RBD_RETENTION_MONTHLY="${RBD_RETENTION_MONTHLY:-12}"
RBD_RETENTION_DAILY_DIFFS="${RBD_RETENTION_DAILY_DIFFS:-30}"
RBD_RETENTION_WEEKLY_FULLS="${RBD_RETENTION_WEEKLY_FULLS:-8}"
RBD_RETENTION_MONTHLY_FULLS="${RBD_RETENTION_MONTHLY_FULLS:-12}"
RBD_WEEKLY_FULL_DAY="${RBD_WEEKLY_FULL_DAY:-7}"
RBD_MONTHLY_FULL_DAY="${RBD_MONTHLY_FULL_DAY:-1}"
RBD_DAILY_SNAPSHOT_PREFIX="${RBD_DAILY_SNAPSHOT_PREFIX:-daily}"
RBD_MONTHLY_SNAPSHOT_PREFIX="${RBD_MONTHLY_SNAPSHOT_PREFIX:-monthly}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-}"
DAILY_TIME="${DAILY_TIME:-00:00}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
RBD_PRE_BACKUP_HOOK="${RBD_PRE_BACKUP_HOOK:-}"
RBD_POST_BACKUP_HOOK="${RBD_POST_BACKUP_HOOK:-}"

mkdir -p "$(dirname "$RBD_LOG_FILE")"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$RBD_LOG_FILE" >/dev/null
}

notify_ntfy() {
    local title="$1"
    local message="$2"

    if [ -n "$NTFY_URL" ] && [ -n "$NTFY_TOPIC" ]; then
        if ! curl -fsS -X POST "$NTFY_URL/$NTFY_TOPIC" -H "Title: $title" -d "$message" >/dev/null 2>&1; then
            log_message "Error: Failed to send ntfy notification"
        fi
    fi
}

fail() {
    local message="$1"
    log_message "Error: $message"
    notify_ntfy "RBD backup FAILED" "$message"
    exit 1
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "Required command not found: $command_name"
    fi
}

validate_integer() {
    local label="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        fail "Invalid $label value: $value (must be a non-negative integer)"
    fi
}

run_hook() {
    local phase="$1"
    local hook="$2"

    if [ -n "$hook" ]; then
        log_message "Running ${phase} hook"
        if ! bash -lc "$hook"; then
            fail "${phase} hook failed"
        fi
    fi
}

rbd_cmd() {
    local args=()

    if [ -n "$RBD_CONF" ]; then
        args+=("--conf" "$RBD_CONF")
    fi

    if [ -n "$RBD_CEPH_ID" ]; then
        args+=("--id" "$RBD_CEPH_ID")
    fi

    if [ -n "$RBD_KEYRING" ]; then
        args+=("--keyring" "$RBD_KEYRING")
    fi

    rbd "${args[@]}" "$@"
}

list_snapshots() {
    local image="$1"
    rbd_cmd snap ls "${RBD_POOL}/${image}" --format json | jq -r '.[].name'
}

snapshot_exists() {
    local image="$1"
    local snapshot_name="$2"

    list_snapshots "$image" | grep -Fxq "$snapshot_name"
}

create_snapshot_if_missing() {
    local image="$1"
    local snapshot_name="$2"

    if snapshot_exists "$image" "$snapshot_name"; then
        log_message "Snapshot already exists: ${RBD_POOL}/${image}@${snapshot_name}"
        return
    fi

    log_message "Creating snapshot ${RBD_POOL}/${image}@${snapshot_name}"
    rbd_cmd snap create "${RBD_POOL}/${image}@${snapshot_name}"
}

write_checksum() {
    local file_path="$1"
    sha256sum "$file_path" > "${file_path}.sha256"
}

export_full() {
    local image="$1"
    local snapshot_name="$2"
    local output_path="$3"

    mkdir -p "$(dirname "$output_path")"
    log_message "Exporting full image ${RBD_POOL}/${image}@${snapshot_name} -> $output_path"
    rbd_cmd export --export-format 1 "${RBD_POOL}/${image}@${snapshot_name}" "$output_path"
    write_checksum "$output_path"
}

export_diff() {
    local image="$1"
    local from_snapshot="$2"
    local to_snapshot="$3"
    local output_path="$4"

    mkdir -p "$(dirname "$output_path")"
    log_message "Exporting diff ${RBD_POOL}/${image}@${from_snapshot} -> ${RBD_POOL}/${image}@${to_snapshot} -> $output_path"
    rbd_cmd export-diff --from-snap "$from_snapshot" "${RBD_POOL}/${image}@${to_snapshot}" "$output_path"
    write_checksum "$output_path"
}

remove_with_checksum() {
    local file_path="$1"

    rm -f -- "$file_path" "${file_path}.sha256"
}

prune_files() {
    local directory="$1"
    local pattern="$2"
    local keep_count="$3"

    mkdir -p "$directory"

    mapfile -t files < <(find "$directory" -maxdepth 1 -type f -name "$pattern" | sort)

    if [ "${#files[@]}" -le "$keep_count" ]; then
        return
    fi

    for file_path in "${files[@]:0:${#files[@]}-keep_count}"; do
        log_message "Removing old backup file $file_path"
        remove_with_checksum "$file_path"
    done
}

prune_snapshots() {
    local image="$1"
    local prefix="$2"
    local keep_count="$3"

    mapfile -t snapshots < <(list_snapshots "$image" | grep "^${prefix}-" | sort || true)

    if [ "${#snapshots[@]}" -le "$keep_count" ]; then
        return
    fi

    for snapshot_name in "${snapshots[@]:0:${#snapshots[@]}-keep_count}"; do
        log_message "Removing old snapshot ${RBD_POOL}/${image}@${snapshot_name}"
        rbd_cmd snap rm "${RBD_POOL}/${image}@${snapshot_name}"
    done
}

image_has_any_full_backup() {
    local image_root="$1"
    find "$image_root/full" -type f -name '*.raw' | grep -q .
}

get_images() {
    if [ -n "$RBD_IMAGES" ]; then
        echo "$RBD_IMAGES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'
        return
    fi

    rbd_cmd ls "$RBD_POOL"
}

seconds_until_next_daily() {
    local today
    local now_ts
    local target_ts
    local next_ts

    today="$(date +%Y-%m-%d)"
    now_ts="$(date +%s)"
    target_ts="$(date -d "${today} ${DAILY_TIME}" +%s 2>/dev/null || true)"

    if [ -z "$target_ts" ]; then
        fail "Invalid DAILY_TIME value: $DAILY_TIME (expected HH:MM)"
    fi

    if [ "$target_ts" -le "$now_ts" ]; then
        next_ts="$(date -d "tomorrow ${DAILY_TIME}" +%s 2>/dev/null || true)"
    else
        next_ts="$target_ts"
    fi

    if [ -z "$next_ts" ]; then
        fail "Unable to calculate next run time"
    fi

    echo $((next_ts - now_ts))
}

run_backup() {
    local daily_snapshot_name
    local monthly_snapshot_name
    local monthly_full_due
    local weekly_full_due
    local daily_diff_due
    local images_output
    local backup_summary

    validate_integer "RBD_RETENTION_DAILY" "$RBD_RETENTION_DAILY"
    validate_integer "RBD_RETENTION_MONTHLY" "$RBD_RETENTION_MONTHLY"
    validate_integer "RBD_RETENTION_DAILY_DIFFS" "$RBD_RETENTION_DAILY_DIFFS"
    validate_integer "RBD_RETENTION_WEEKLY_FULLS" "$RBD_RETENTION_WEEKLY_FULLS"
    validate_integer "RBD_RETENTION_MONTHLY_FULLS" "$RBD_RETENTION_MONTHLY_FULLS"
    validate_integer "RBD_WEEKLY_FULL_DAY" "$RBD_WEEKLY_FULL_DAY"
    validate_integer "RBD_MONTHLY_FULL_DAY" "$RBD_MONTHLY_FULL_DAY"

    if [ -z "$RBD_POOL" ]; then
        fail "RBD_POOL must be set"
    fi

    if [ "$RBD_WEEKLY_FULL_DAY" -lt 1 ] || [ "$RBD_WEEKLY_FULL_DAY" -gt 7 ]; then
        fail "RBD_WEEKLY_FULL_DAY must be between 1 and 7"
    fi

    if [ "$RBD_MONTHLY_FULL_DAY" -lt 1 ] || [ "$RBD_MONTHLY_FULL_DAY" -gt 28 ]; then
        fail "RBD_MONTHLY_FULL_DAY must be between 1 and 28"
    fi

    require_command rbd
    require_command jq
    require_command sha256sum

    mkdir -p "$RBD_EXPORT_ROOT"

    daily_snapshot_name="${RBD_DAILY_SNAPSHOT_PREFIX}-$(date +%F)"
    monthly_snapshot_name="${RBD_MONTHLY_SNAPSHOT_PREFIX}-$(date +%Y-%m)"
    monthly_full_due=false
    weekly_full_due=false
    daily_diff_due=true
    backup_summary=()

    if [ "$(date +%d)" = "$(printf '%02d' "$RBD_MONTHLY_FULL_DAY")" ]; then
        monthly_full_due=true
        daily_diff_due=false
    elif [ "$(date +%u)" = "$RBD_WEEKLY_FULL_DAY" ]; then
        weekly_full_due=true
        daily_diff_due=false
    fi

    run_hook "pre-backup" "$RBD_PRE_BACKUP_HOOK"

    if ! images_output="$(get_images)"; then
        fail "Unable to list RBD images from pool ${RBD_POOL}"
    fi

    while IFS= read -r image; do
        local image_root
        local previous_daily_snapshot
        local today_iso
        local month_iso
        local weekly_output
        local monthly_output
        local diff_output

        [ -n "$image" ] || continue

        image_root="${RBD_EXPORT_ROOT}/${RBD_POOL}/${image}"
        mkdir -p "$image_root/full/weekly" "$image_root/full/monthly" "$image_root/diff/daily"

        log_message "Starting backup for ${RBD_POOL}/${image}"

        create_snapshot_if_missing "$image" "$daily_snapshot_name"

        if [ "$monthly_full_due" = true ]; then
            create_snapshot_if_missing "$image" "$monthly_snapshot_name"
        fi

        mapfile -t previous_daily_snapshots < <(list_snapshots "$image" | grep "^${RBD_DAILY_SNAPSHOT_PREFIX}-" | grep -vx "$daily_snapshot_name" | sort || true)
        previous_daily_snapshot=""
        if [ "${#previous_daily_snapshots[@]}" -gt 0 ]; then
            previous_daily_snapshot="${previous_daily_snapshots[-1]}"
        fi

        today_iso="$(date +%F)"
        month_iso="$(date +%Y-%m)"
        weekly_output="${image_root}/full/weekly/${image}-${today_iso}.raw"
        monthly_output="${image_root}/full/monthly/${image}-${month_iso}.raw"
        diff_output="${image_root}/diff/daily/${image}-${today_iso}.rbdiff"

        if [ "$monthly_full_due" = true ]; then
            export_full "$image" "$monthly_snapshot_name" "$monthly_output"
            backup_summary+=("${image}:monthly-full")
        elif [ "$weekly_full_due" = true ]; then
            export_full "$image" "$daily_snapshot_name" "$weekly_output"
            backup_summary+=("${image}:weekly-full")
        elif ! image_has_any_full_backup "$image_root"; then
            export_full "$image" "$daily_snapshot_name" "$weekly_output"
            backup_summary+=("${image}:bootstrap-full")
        elif [ "$daily_diff_due" = true ] && [ -n "$previous_daily_snapshot" ]; then
            export_diff "$image" "$previous_daily_snapshot" "$daily_snapshot_name" "$diff_output"
            backup_summary+=("${image}:daily-diff")
        else
            export_full "$image" "$daily_snapshot_name" "$weekly_output"
            backup_summary+=("${image}:fallback-full")
        fi

        prune_snapshots "$image" "$RBD_DAILY_SNAPSHOT_PREFIX" "$RBD_RETENTION_DAILY"
        prune_snapshots "$image" "$RBD_MONTHLY_SNAPSHOT_PREFIX" "$RBD_RETENTION_MONTHLY"
        prune_files "${image_root}/diff/daily" '*.rbdiff' "$RBD_RETENTION_DAILY_DIFFS"
        prune_files "${image_root}/full/weekly" '*.raw' "$RBD_RETENTION_WEEKLY_FULLS"
        prune_files "${image_root}/full/monthly" '*.raw' "$RBD_RETENTION_MONTHLY_FULLS"

        log_message "Completed backup for ${RBD_POOL}/${image}"
    done <<< "$images_output"

    run_hook "post-backup" "$RBD_POST_BACKUP_HOOK"

    if [ "${#backup_summary[@]}" -eq 0 ]; then
        backup_summary=("no-images")
    fi

    notify_ntfy "RBD backup SUCCESS" "$(date +%F), operations: ${backup_summary[*]}"
    log_message "Backup run completed successfully"
}

if [ "$BACKUP_SCHEDULE" = "daily" ]; then
    while true; do
        run_backup
        sleep_for="$(seconds_until_next_daily)"
        log_message "Next run in ${sleep_for}s at ${DAILY_TIME}"
        sleep "$sleep_for"
    done
else
    run_backup
fi
