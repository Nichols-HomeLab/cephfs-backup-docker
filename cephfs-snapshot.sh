#!/bin/bash

# Logging function (logs to both file and stdout based on log level)
log_message() {
    local level=$1
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $2"

    case "$LOG_LEVEL" in
        debug)
            echo "$message"  # Always log to stdout in debug
            ;;
        verbose)
            if [ "$level" != "debug" ]; then
                echo "$message"
            fi
            ;;
        info)
            if [ "$level" == "info" ]; then
                echo "$message"
            fi
            ;;
    esac

    # Write to log file regardless of level
    echo "$message" >> "$LOG_FILE"
}

# SMTP notification function to send the log file
send_smtp_notification() {
    SUBJECT=$1
    BODY=$2
    STATUS=$3

    if [ "$STATUS" == "fail" ]; then
        SUBJECT="CephFS Snapshot Failed"
    elif [ "$STATUS" == "success" ]; then
        SUBJECT="CephFS Snapshot Success"
    fi

    log_message "info" "Sending SMTP notification with subject: $SUBJECT"
    # Use msmtp and mailx to send the log file as an attachment
    echo "$BODY" | mailx -s "$SUBJECT" -a "$LOG_FILE" "$SMTP_RECIPIENT"
}

# Send test notification if requested
send_test_notification() {
    log_message "info" "Sending test notification via SMTP"
    echo "CEPHFS DOCKER TEST" | mailx -s "CEPHFS DOCKER TEST" "$SMTP_RECIPIENT"
    log_message "info" "Test notification sent."
}

# Load environment variables with defaults
CEPHFS_MOUNT="${CEPHFS_MOUNT:-/mnt/cephfs}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$CEPHFS_MOUNT/.snap}"
LOG_FILE="${LOG_FILE:-$CEPHFS_MOUNT/cephfs_snapshot.log}"
LOG_LEVEL="${LOG_LEVEL:-info}"  # Set default log level to info
MAX_SNAPSHOTS="${MAX_SNAPSHOTS:-7}"
REMOTE_DIR="${REMOTE_DIR:-/mnt/unraid/Backup/cephfs/}"
REMOTE_LOG_FILE="$REMOTE_DIR/cephfs_snapshot_$(date +%Y%m%d).log"

# SMTP configuration
SMTP_SERVER="${SMTP_SERVER:-smtp.example.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-user@example.com}"
SMTP_PASSWORD="${SMTP_PASSWORD:-password}"
SMTP_FROM="${SMTP_FROM:-no-reply@example.com}"
SMTP_RECIPIENT="${SMTP_RECIPIENT:-admin@example.com}"
SMTP_TLS="${SMTP_TLS:-on}"
SMTP_TLS_VERIFY="${SMTP_TLS_VERIFY:-on}"
SEND_TEST_NOTIFICATION="${SEND_TEST_NOTIFICATION:-false}"

# Test notification logic
if [ "$SEND_TEST_NOTIFICATION" == "true" ]; then
    send_test_notification
    log_message "info" "SMTP test sent"
    exit 0
fi

log_message "info" "Script execution started."

# Function to copy snapshot to the remote directory
copy_snapshot_to_remote() {
    SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT_NAME"
    if cp -r "$SNAPSHOT_PATH" "$REMOTE_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "info" "Snapshot copied to remote: $REMOTE_DIR"
    else
        log_message "error" "Error: Failed to copy snapshot to remote"
        send_smtp_notification "CephFS Snapshot Error" "Failed to copy snapshot to $REMOTE_DIR." "fail"
        exit 1
    fi
}

# Function to copy log to the remote directory
copy_log_to_remote() {
    if cp "$LOG_FILE" "$REMOTE_LOG_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "info" "Log copied to remote: $REMOTE_LOG_FILE"
    else
        log_message "error" "Error: Failed to copy log to remote"
        send_smtp_notification "CephFS Snapshot Error" "Failed to copy log to $REMOTE_DIR." "fail"
        exit 1
    fi
}

# Check if the remote directory exists, if not, create it
log_message "info" "Checking if remote directory exists."
if [ ! -d "$REMOTE_DIR" ]; then
    log_message "verbose" "Remote directory does not exist. Creating it."
    mkdir -p "$REMOTE_DIR"
    if [ $? -ne 0 ]; then
        log_message "error" "Error: Failed to create remote directory $REMOTE_DIR"
        send_smtp_notification "CephFS Snapshot Error" "Failed to create remote directory $REMOTE_DIR." "fail"
        exit 1
    fi
    log_message "info" "Created remote directory: $REMOTE_DIR"
fi

# Check if CephFS is mounted
log_message "info" "Checking if CephFS is mounted at $CEPHFS_MOUNT."
if ! mountpoint -q "$CEPHFS_MOUNT"; then
    log_message "error" "Error: CephFS is not mounted at $CEPHFS_MOUNT"
    send_smtp_notification "CephFS Snapshot Error" "CephFS is not mounted at $CEPHFS_MOUNT." "fail"
    exit 1
fi

# Create a unique snapshot name
log_message "info" "Creating a unique snapshot name."
SNAPSHOT_NAME=$(date +%Y%m%d-%Hh%M)
COUNTER=1
while [ -d "$SNAPSHOT_DIR/$SNAPSHOT_NAME" ]; do
    SNAPSHOT_NAME=$(date +%Y%m%d-%Hh%M)_$COUNTER
    COUNTER=$((COUNTER + 1))
done

# Create snapshot directory
log_message "info" "Creating snapshot directory: $SNAPSHOT_NAME"
if mkdir "$SNAPSHOT_DIR/$SNAPSHOT_NAME"; then
    log_message "info" "Snapshot created: $SNAPSHOT_NAME"
else
    log_message "error" "Error: Failed to create snapshot $SNAPSHOT_NAME"
    send_smtp_notification "CephFS Snapshot Error" "Failed to create snapshot $SNAPSHOT_NAME." "fail"
    exit 1
fi

# Copy the snapshot to the remote directory
copy_snapshot_to_remote

# Copy the log file to the remote directory with a date in the filename
copy_log_to_remote

# List all snapshots and sort them
log_message "info" "Listing all snapshots in $SNAPSHOT_DIR."
SNAPSHOTS=($(ls -1 "$SNAPSHOT_DIR" | sort))

# Remove old snapshots if we have more than MAX_SNAPSHOTS
log_message "info" "Checking if any snapshots need to be removed."
while [ ${#SNAPSHOTS[@]} -gt $MAX_SNAPSHOTS ]; do
    OLDEST=${SNAPSHOTS[0]}
    if rmdir "$SNAPSHOT_DIR/$OLDEST"; then
        log_message "info" "Removed old snapshot: $OLDEST"
    else
        log_message "error" "Error: Failed to remove old snapshot $OLDEST"
        send_smtp_notification "CephFS Snapshot Error" "Failed to remove old snapshot $OLDEST." "fail"
    fi
    SNAPSHOTS=(${SNAPSHOTS[@]:1})  # Remove the first element from the array
done

log_message "info" "Snapshot process completed successfully."
send_smtp_notification "CephFS Snapshot Success" "Snapshot process completed successfully." "success"
