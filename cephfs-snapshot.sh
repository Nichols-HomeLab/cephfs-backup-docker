#!/bin/bash

# Configuration
CEPHFS_MOUNT="/mnt/cephfs"
SNAPSHOT_DIR="$CEPHFS_MOUNT/.snap"
LOG_FILE="/mnt/cephfs/cephfs_snapshot.log"
MAX_SNAPSHOTS=7  # Keep a week's worth of snapshots
REMOTE_DIR="/mnt/unraid/Backup/cephfs/"
REMOTE_LOG_FILE="$REMOTE_DIR/cephfs_snapshot_$(date +%Y%m%d).log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to copy snapshot to remote dir
copy_snapshot_to_remote() {
    SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT_NAME"
    if cp -r "$SNAPSHOT_PATH" "$REMOTE_DIR"; then
        log_message "Snapshot copied to remote: $REMOTE_DIR"
    else
        log_message "Error: Failed to copy snapshot to remote"
    fi
}

# Function to copy log to remote dir
copy_log_to_remote() {
    if cp "$LOG_FILE" "$REMOTE_LOG_FILE"; then
        log_message "Log copied to remote: $REMOTE_LOG_FILE"
    else
        log_message "Error: Failed to copy log to remote"
    fi
}

# Ensure remote directory exists
if [ ! -d "$REMOTE_DIR" ]; then
    mkdir -p "$REMOTE_DIR"
    if [ $? -ne 0 ]; then
        log_message "Error: Failed to create remote directory $REMOTE_DIR"
        exit 1
    fi
fi

# Check if CephFS is mounted
if ! mountpoint -q "$CEPHFS_MOUNT"; then
    log_message "Error: CephFS is not mounted at $CEPHFS_MOUNT"
    exit 1
fi

# Create a unique snapshot name
SNAPSHOT_NAME=$(date +%Y%m%d-%Hh%M)
COUNTER=1
while [ -d "$SNAPSHOT_DIR/$SNAPSHOT_NAME" ]; do
    SNAPSHOT_NAME=$(date +%Y%m%d-%Hh%M)_$COUNTER
    COUNTER=$((COUNTER + 1))
done

if mkdir "$SNAPSHOT_DIR/$SNAPSHOT_NAME"; then
    log_message "Snapshot created: $SNAPSHOT_NAME"
else
    log_message "Error: Failed to create snapshot $SNAPSHOT_NAME"
    exit 1
fi

# Copy the snapshot to the remote directory
copy_snapshot_to_remote

# Copy the log file to the remote directory with a date in the filename
copy_log_to_remote

# List all snapshots and sort them
SNAPSHOTS=($(ls -1 "$SNAPSHOT_DIR" | sort))

# Remove old snapshots if we have more than MAX_SNAPSHOTS
while [ ${#SNAPSHOTS[@]} -gt $MAX_SNAPSHOTS ]; do
    OLDEST=${SNAPSHOTS[0]}
    if rmdir "$SNAPSHOT_DIR/$OLDEST"; then
        log_message "Removed old snapshot: $OLDEST"
    else
        log_message "Error: Failed to remove old snapshot $OLDEST"
    fi
    SNAPSHOTS=(${SNAPSHOTS[@]:1})  # Remove the first element from the array
done

log_message "Snapshot process completed successfully"
