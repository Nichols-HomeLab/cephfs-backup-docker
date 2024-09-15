#!/bin/bash

# Add cron job with schedule from the CRON_SCHEDULE environment variable
echo "$CRON_SCHEDULE /usr/local/bin/cephfs-snapshot.sh >> /var/log/cron.log 2>&1" > /etc/crontabs/root

# Start cron daemon in the foreground
crond -f -l 2
