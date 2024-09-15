#!/bin/bash

# Configuration
CEPHFS_MOUNT="/mnt/cephfs"
SNAPSHOT_DIR="$CEPHFS_MOUNT/.snap"
LOG_FILE="/mnt/cephfs/cephfs_snapshot_cleanup.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Check if CephFS is mounted
if ! mountpoint -q "$CEPHFS_MOUNT"; then
    log_message "Error: CephFS is not mounted at $CEPHFS_MOUNT"
    exit 1
fi

# Check if snapshot directory exists
if [ ! -d "$SNAPSHOT_DIR" ]; then
    log_message "Error: Snapshot directory does not exist at $SNAPSHOT_DIR"
    exit 1
fi

# List all snapshots
SNAPSHOTS=($(ls -1 "$SNAPSHOT_DIR"))

if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
    log_message "No snapshots found to delete."
else
    # Loop through snapshots and delete each one
    for SNAPSHOT in "${SNAPSHOTS[@]}"; do
        SNAPSHOT_PATH="$SNAPSHOT_DIR/$SNAPSHOT"
        if rmdir "$SNAPSHOT_PATH"; then
            log_message "Deleted snapshot: $SNAPSHOT"
        else
            log_message "Error: Failed to delete snapshot $SNAPSHOT"
        fi
    done
fi

log_message "Snapshot cleanup process completed."
