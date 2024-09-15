# Use a lightweight base image
FROM alpine:latest

# Install necessary packages for CephFS, cron, and mailx/msmtp
RUN apk add --no-cache bash sudo busybox-suid msmtp mailx

# Set default environment variables
ENV CEPHFS_MOUNT="/mnt/cephfs"
ENV SNAPSHOT_DIR="/mnt/cephfs/.snap"
ENV LOG_FILE="/mnt/cephfs/cephfs_snapshot.log"
ENV MAX_SNAPSHOTS="7"
ENV REMOTE_DIR="/mnt/unraid/Backup/cephfs"
ENV CRON_SCHEDULE="0 2 * * *"
ENV SMTP_SERVER="smtp.example.com"
ENV SMTP_PORT="587"
ENV SMTP_USER="user@example.com"
ENV SMTP_PASSWORD="password"
ENV SMTP_FROM="no-reply@example.com"
ENV SMTP_RECIPIENT="admin@example.com"
ENV SMTP_TLS="on"
ENV SMTP_TLS_VERIFY="off"
ENV LOG_LEVEL="info"

# Copy the snapshot script
COPY cephfs-snapshot.sh /usr/local/bin/cephfs-snapshot.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/cephfs-snapshot.sh

# Copy the start-cron script
COPY start-cron.sh /usr/local/bin/start-cron.sh

# Ensure the start-cron script is executable
RUN chmod +x /usr/local/bin/start-cron.sh

# Run the start-cron script
ENTRYPOINT ["/usr/local/bin/start-cron.sh"]
