# Use a lightweight base image
FROM alpine:latest

# Install necessary packages for CephFS
RUN apk add --no-cache bash sudo

# Set default environment variables
ENV CEPHFS_MOUNT="/mnt/cephfs"
ENV SNAPSHOT_DIR="/mnt/cephfs/.snap"
ENV LOG_FILE="/mnt/cephfs/cephfs_snapshot.log"
ENV MAX_SNAPSHOTS="7"
ENV REMOTE_DIR="/mnt/unraid/Backup/cephfs"

# Copy the snapshot script
COPY cephfs-snapshot.sh /usr/local/bin/cephfs-snapshot.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/cephfs-snapshot.sh

# Set the default command to run the script
ENTRYPOINT ["/usr/local/bin/cephfs-snapshot.sh"]
