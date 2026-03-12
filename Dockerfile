# Use a lightweight base image
FROM alpine:latest

# Install necessary packages for CephFS
RUN apk add --no-cache bash sudo curl

# Set default environment variables
ENV CEPHFS_MOUNT="/mnt/cephfs"
ENV SNAPSHOT_DIR="/mnt/cephfs/.snap"
ENV LOG_FILE="/mnt/cephfs/cephfs_snapshot.log"
ENV MAX_SNAPSHOTS="7"
ENV REMOTE_DIR="/mnt/unraid/Backup/cephfs"
ENV RETENTION_HOURLY=""
ENV RETENTION_DAILY=""
ENV RETENTION_MONTHLY=""
ENV RETENTION_YEARLY=""
ENV NTFY_URL=""
ENV NTFY_TOPIC=""
ENV BACKUP_SCHEDULE=""
ENV DAILY_TIME="00:00"

# Copy the snapshot script
COPY cephfs-snapshot.sh /usr/local/bin/cephfs-snapshot.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/cephfs-snapshot.sh

# Set the default command to run the script
ENTRYPOINT ["/usr/local/bin/cephfs-snapshot.sh"]
