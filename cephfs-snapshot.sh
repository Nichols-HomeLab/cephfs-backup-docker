#!/bin/bash

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Send ntfy notification if configured
notify_ntfy() {
    local title="$1"
    local message="$2"
    if [ -n "$NTFY_URL" ] && [ -n "$NTFY_TOPIC" ]; then
        if ! curl -fsS -X POST "$NTFY_URL/$NTFY_TOPIC" -H "Title: $title" -d "$message" >/dev/null 2>&1; then
            log_message "Error: Failed to send ntfy notification"
        fi
    fi
}

# Exit with error, log, and notify
fail() {
    local message="$1"
    log_message "Error: $message"
    notify_ntfy "CephFS snapshot FAILED" "$message"
    exit 1
}

# Load environment variables with defaults
CEPHFS_MOUNT="${CEPHFS_MOUNT:-/mnt/cephfs}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$CEPHFS_MOUNT/.snap}"
LOG_FILE="${LOG_FILE:-$CEPHFS_MOUNT/cephfs_snapshot.log}"
MAX_SNAPSHOTS="${MAX_SNAPSHOTS:-7}"
REMOTE_DIR="${REMOTE_DIR:-/mnt/unraid/Backup/cephfs/}"
REMOTE_LOG_FILE="$REMOTE_DIR/cephfs_snapshot_$(date +%Y%m%d).log"
RETENTION_HOURLY="${RETENTION_HOURLY:-}"
RETENTION_DAILY="${RETENTION_DAILY:-}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-}"
RETENTION_YEARLY="${RETENTION_YEARLY:-}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-}"
DAILY_TIME="${DAILY_TIME:-00:00}"

log_message "Script execution started."

# Function to copy snapshot to the remote directory
copy_snapshot_to_remote() {
    local snapshot_path="$SNAPSHOT_DIR/$SNAPSHOT_NAME"
    local remote_day_dir="$REMOTE_DIR/$(date +%Y-%m-%d)"
    local remote_day_name
    remote_day_name="$(basename "$remote_day_dir")"

    if [ ! -d "$remote_day_dir" ]; then
        mkdir -p "$remote_day_dir" || {
            log_message "Error: Failed to create remote day directory $remote_day_dir"
            notify_ntfy "CephFS snapshot FAILED" "folder: $remote_day_name, error: failed to create remote day directory"
            transfer_status="failed"
            return
        }
    fi

    # Copy snapshot contents without preserving ownership, which commonly fails on NFS/CephFS-backed targets.
    if cp -dR "$snapshot_path/." "$remote_day_dir"; then
        log_message "Snapshot copied to remote: $remote_day_dir"
        transfer_status="synced"
    else
        log_message "Error: Failed to copy snapshot to remote"
        notify_ntfy "CephFS snapshot FAILED" "folder: $remote_day_name, error: failed to copy snapshot to remote"
        transfer_status="failed"
    fi
}

# Function to copy log to the remote directory
copy_log_to_remote() {
    if cp "$LOG_FILE" "$REMOTE_LOG_FILE"; then
        log_message "Log copied to remote: $REMOTE_LOG_FILE"
    else
        log_message "Error: Failed to copy log to remote"
        notify_ntfy "CephFS snapshot FAILED" "Failed to copy log to remote: $REMOTE_LOG_FILE"
    fi
}

prune_remote_backups() {
    local hourly_limit="${RETENTION_HOURLY:-0}"
    local daily_limit="${RETENTION_DAILY:-0}"
    local monthly_limit="${RETENTION_MONTHLY:-0}"
    local yearly_limit="${RETENTION_YEARLY:-0}"

    if [ -z "$RETENTION_HOURLY" ] && [ -z "$RETENTION_DAILY" ] && [ -z "$RETENTION_MONTHLY" ] && [ -z "$RETENTION_YEARLY" ]; then
        log_message "Remote retention skipped (no RETENTION_* set)."
        return
    fi

    log_message "Applying remote retention in $REMOTE_DIR."

    remote_snapshots=()
    keep_always=()

    while IFS= read -r -d '' dir; do
        base="$(basename "$dir")"
        if [[ "$base" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
            ts=$(date -d "${base} 00:00" +%s 2>/dev/null)
            if [ -n "$ts" ]; then
                remote_snapshots+=("$ts $base")
            else
                keep_always+=("$base")
            fi
        else
            keep_always+=("$base")
        fi
    done < <(find "$REMOTE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

    IFS=$'\n' sorted_lines=($(printf '%s\n' "${remote_snapshots[@]}" | sort -nr))
    unset IFS

    declare -A hourly_keys
    declare -A daily_keys
    declare -A monthly_keys
    declare -A yearly_keys

    hourly_count=0
    daily_count=0
    monthly_count=0
    yearly_count=0

    keep_list=("${keep_always[@]}")
    remove_list=()

    for line in "${sorted_lines[@]}"; do
        ts="${line%% *}"
        snap="${line#* }"
        keep=false

        key_hour="$(date -d "@$ts" +%Y%m%d%H 2>/dev/null)"
        key_day="$(date -d "@$ts" +%Y%m%d 2>/dev/null)"
        key_month="$(date -d "@$ts" +%Y%m 2>/dev/null)"
        key_year="$(date -d "@$ts" +%Y 2>/dev/null)"

        if [ "$hourly_limit" -gt 0 ] && [ -n "$key_hour" ]; then
            if [ -z "${hourly_keys[$key_hour]}" ] && [ "$hourly_count" -lt "$hourly_limit" ]; then
                hourly_keys["$key_hour"]=1
                hourly_count=$((hourly_count + 1))
                keep=true
            fi
        fi

        if [ "$daily_limit" -gt 0 ] && [ -n "$key_day" ]; then
            if [ -z "${daily_keys[$key_day]}" ] && [ "$daily_count" -lt "$daily_limit" ]; then
                daily_keys["$key_day"]=1
                daily_count=$((daily_count + 1))
                keep=true
            fi
        fi

        if [ "$monthly_limit" -gt 0 ] && [ -n "$key_month" ]; then
            if [ -z "${monthly_keys[$key_month]}" ] && [ "$monthly_count" -lt "$monthly_limit" ]; then
                monthly_keys["$key_month"]=1
                monthly_count=$((monthly_count + 1))
                keep=true
            fi
        fi

        if [ "$yearly_limit" -gt 0 ] && [ -n "$key_year" ]; then
            if [ -z "${yearly_keys[$key_year]}" ] && [ "$yearly_count" -lt "$yearly_limit" ]; then
                yearly_keys["$key_year"]=1
                yearly_count=$((yearly_count + 1))
                keep=true
            fi
        fi

        if [ "$keep" = true ]; then
            keep_list+=("$snap")
        else
            remove_list+=("$snap")
        fi
    done

    for snap in "${remove_list[@]}"; do
        if rm -rf "$REMOTE_DIR/$snap"; then
            log_message "Removed old remote backup: $snap"
        else
            log_message "Error: Failed to remove old remote backup $snap"
        fi
    done
}

run_snapshot() {
    deleted_snapshots=()
    transfer_status="unknown"
    remote_folder_name="$(date +%Y-%m-%d)"
    remote_folder_path="$REMOTE_DIR/$remote_folder_name"
    remote_folder_size="unknown"

    # Check if the remote directory exists, if not, create it
    log_message "Checking if remote directory exists."
    if [ ! -d "$REMOTE_DIR" ]; then
        mkdir -p "$REMOTE_DIR"
        if [ $? -ne 0 ]; then
            fail "Failed to create remote directory $REMOTE_DIR"
        fi
        log_message "Created remote directory: $REMOTE_DIR"
    fi

    # Check if CephFS is mounted
    log_message "Checking if CephFS is mounted at $CEPHFS_MOUNT."
    if ! mountpoint -q "$CEPHFS_MOUNT"; then
        fail "CephFS is not mounted at $CEPHFS_MOUNT"
    fi

    # Create a daily snapshot name
    log_message "Creating a snapshot name."
    SNAPSHOT_NAME=$(date +%Y-%m-%d)
    COUNTER=1
    while [ -d "$SNAPSHOT_DIR/$SNAPSHOT_NAME" ]; do
        SNAPSHOT_NAME="$(date +%Y-%m-%d)_$COUNTER"
        COUNTER=$((COUNTER + 1))
    done

    # Create snapshot directory
    log_message "Creating snapshot directory: $SNAPSHOT_NAME"
    if mkdir "$SNAPSHOT_DIR/$SNAPSHOT_NAME"; then
        log_message "Snapshot created: $SNAPSHOT_NAME"
    else
        fail "Failed to create snapshot $SNAPSHOT_NAME"
    fi

    # Copy the snapshot to the remote directory
    copy_snapshot_to_remote

    if [ -d "$remote_folder_path" ]; then
        remote_folder_size="$(du -sh "$remote_folder_path" 2>/dev/null | awk '{print $1}')"
        if [ -z "$remote_folder_size" ]; then
            remote_folder_size="unknown"
        fi
    fi

    # Copy the log file to the remote directory with a date in the filename
    copy_log_to_remote

    # Apply retention to remote backups as well
    prune_remote_backups

    # Validate retention values if set
    validate_retention_value() {
        local label="$1"
        local value="$2"
        if [ -n "$value" ] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
            fail "Invalid $label value: $value (must be a non-negative integer)"
        fi
    }

    validate_retention_value "RETENTION_HOURLY" "$RETENTION_HOURLY"
    validate_retention_value "RETENTION_DAILY" "$RETENTION_DAILY"
    validate_retention_value "RETENTION_MONTHLY" "$RETENTION_MONTHLY"
    validate_retention_value "RETENTION_YEARLY" "$RETENTION_YEARLY"

    # List all snapshots
    log_message "Listing all snapshots in $SNAPSHOT_DIR."
    SNAPSHOTS=($(ls -1 "$SNAPSHOT_DIR" | sort))

    use_retention=false
    if [ -n "$RETENTION_HOURLY" ] || [ -n "$RETENTION_DAILY" ] || [ -n "$RETENTION_MONTHLY" ] || [ -n "$RETENTION_YEARLY" ]; then
        use_retention=true
    fi

    if [ "$use_retention" = true ]; then
        hourly_limit="${RETENTION_HOURLY:-0}"
        daily_limit="${RETENTION_DAILY:-0}"
        monthly_limit="${RETENTION_MONTHLY:-0}"
        yearly_limit="${RETENTION_YEARLY:-0}"

        declare -A hourly_keys
        declare -A daily_keys
        declare -A monthly_keys
        declare -A yearly_keys

        hourly_count=0
        daily_count=0
        monthly_count=0
        yearly_count=0

        # Build a list of snapshots with timestamps for sorting newest to oldest
        snapshot_lines=()
        keep_always=()
        for snap in "${SNAPSHOTS[@]}"; do
            base="${snap%%_*}"
            if [[ "$base" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
                ymd="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
                ts=$(date -d "${ymd} 00:00" +%s 2>/dev/null)
                if [ -n "$ts" ]; then
                    snapshot_lines+=("$ts $snap")
                else
                    keep_always+=("$snap")
                fi
            elif [[ "$base" =~ ^([0-9]{8})-([0-9]{2})h([0-9]{2})$ ]]; then
                ymd="${BASH_REMATCH[1]}"
                hh="${BASH_REMATCH[2]}"
                mm="${BASH_REMATCH[3]}"
                ts=$(date -d "${ymd} ${hh}:${mm}" +%s 2>/dev/null)
                if [ -n "$ts" ]; then
                    snapshot_lines+=("$ts $snap")
                else
                    keep_always+=("$snap")
                fi
            else
                keep_always+=("$snap")
            fi
        done

        IFS=$'\n' sorted_lines=($(printf '%s\n' "${snapshot_lines[@]}" | sort -nr))
        unset IFS

        keep_list=("${keep_always[@]}")
        remove_list=()

        for line in "${sorted_lines[@]}"; do
            ts="${line%% *}"
            snap="${line#* }"
            keep=false

            key_hour="$(date -d "@$ts" +%Y%m%d%H 2>/dev/null)"
            key_day="$(date -d "@$ts" +%Y%m%d 2>/dev/null)"
            key_month="$(date -d "@$ts" +%Y%m 2>/dev/null)"
            key_year="$(date -d "@$ts" +%Y 2>/dev/null)"

            if [ "$hourly_limit" -gt 0 ] && [ -n "$key_hour" ]; then
                if [ -z "${hourly_keys[$key_hour]}" ] && [ "$hourly_count" -lt "$hourly_limit" ]; then
                    hourly_keys["$key_hour"]=1
                    hourly_count=$((hourly_count + 1))
                    keep=true
                fi
            fi

            if [ "$daily_limit" -gt 0 ] && [ -n "$key_day" ]; then
                if [ -z "${daily_keys[$key_day]}" ] && [ "$daily_count" -lt "$daily_limit" ]; then
                    daily_keys["$key_day"]=1
                    daily_count=$((daily_count + 1))
                    keep=true
                fi
            fi

            if [ "$monthly_limit" -gt 0 ] && [ -n "$key_month" ]; then
                if [ -z "${monthly_keys[$key_month]}" ] && [ "$monthly_count" -lt "$monthly_limit" ]; then
                    monthly_keys["$key_month"]=1
                    monthly_count=$((monthly_count + 1))
                    keep=true
                fi
            fi

            if [ "$yearly_limit" -gt 0 ] && [ -n "$key_year" ]; then
                if [ -z "${yearly_keys[$key_year]}" ] && [ "$yearly_count" -lt "$yearly_limit" ]; then
                    yearly_keys["$key_year"]=1
                    yearly_count=$((yearly_count + 1))
                    keep=true
                fi
            fi

            if [ "$keep" = true ]; then
                keep_list+=("$snap")
            else
                remove_list+=("$snap")
            fi
        done

        log_message "Retention policy enabled (hourly=$hourly_limit, daily=$daily_limit, monthly=$monthly_limit, yearly=$yearly_limit)."

        for snap in "${remove_list[@]}"; do
            if rmdir "$SNAPSHOT_DIR/$snap"; then
                log_message "Removed old snapshot: $snap"
                deleted_snapshots+=("$snap")
            else
                log_message "Error: Failed to remove old snapshot $snap"
            fi
        done
    else
        # Remove old snapshots if we have more than MAX_SNAPSHOTS
        log_message "Checking if any snapshots need to be removed."
        while [ ${#SNAPSHOTS[@]} -gt $MAX_SNAPSHOTS ]; do
            OLDEST=${SNAPSHOTS[0]}
            if rmdir "$SNAPSHOT_DIR/$OLDEST"; then
                log_message "Removed old snapshot: $OLDEST"
                deleted_snapshots+=("$OLDEST")
            else
                log_message "Error: Failed to remove old snapshot $OLDEST"
            fi
            SNAPSHOTS=(${SNAPSHOTS[@]:1})  # Remove the first element from the array
        done
    fi

    log_message "Snapshot process completed successfully."
    if [ ${#deleted_snapshots[@]} -gt 0 ]; then
        deleted_msg="deleted: ${deleted_snapshots[*]}"
    else
        deleted_msg="deleted: none"
    fi
    notify_ntfy "CephFS snapshot SUCCESS" "$(date +%Y-%m-%d), operation: snapshot, $deleted_msg, transfer: $transfer_status, folder: $remote_folder_name, size: $remote_folder_size"
}

seconds_until_next_daily() {
    local today
    local now_ts
    local target_ts
    local next_ts

    today="$(date +%Y-%m-%d)"
    now_ts="$(date +%s)"
    target_ts="$(date -d "${today} ${DAILY_TIME}" +%s 2>/dev/null)"

    if [ -z "$target_ts" ]; then
        fail "Invalid DAILY_TIME value: $DAILY_TIME (expected HH:MM)"
    fi

    if [ "$target_ts" -le "$now_ts" ]; then
        next_ts="$(date -d "tomorrow ${DAILY_TIME}" +%s 2>/dev/null)"
    else
        next_ts="$target_ts"
    fi

    echo $((next_ts - now_ts))
}

if [ "$BACKUP_SCHEDULE" = "daily" ]; then
    while true; do
        run_snapshot
        sleep_for="$(seconds_until_next_daily)"
        log_message "Next run in ${sleep_for}s at ${DAILY_TIME}."
        sleep "$sleep_for"
    done
else
    run_snapshot
fi
