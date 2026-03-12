# CephFS Snapshot Docker Container

This Docker container creates snapshots of your CephFS mount and backs them up to a remote directory. It also handles log file management and supports both simple max-count retention or time-based retention (hourly/daily/monthly/yearly).

## Features
- Snapshot creation for CephFS mount points.
- Customizable backup and logging directories.
- Automatic old snapshot removal after exceeding a defined threshold or by time-based retention.
- Remote backup copies preserve contents and symlinks without attempting to preserve owner/group metadata on the destination.
- Optional ntfy notifications for success and failure.

## Environment Variables
The following environment variables can be set to customize the behavior of the container:

- `CEPHFS_MOUNT` (default: `/mnt/cephfs`): The mount point of the CephFS filesystem.
- `SNAPSHOT_DIR` (default: `/$CEPHFS_MOUNT/.snap`): Directory where snapshots will be stored.
- `LOG_FILE` (default: `$CEPHFS_MOUNT/cephfs_snapshot.log`): Path to the log file.
- `MAX_SNAPSHOTS` (default: `7`): The maximum number of snapshots to keep (used only if no time-based retention variables are set).
- `REMOTE_DIR` (default: `/mnt/unraid/Backup/cephfs/`): Remote directory where snapshots and logs will be copied. Daily backups are stored in `REMOTE_DIR/YYYY-MM-DD/` and contain the snapshot contents (no extra nested snapshot directory).
- `RETENTION_HOURLY` (default: unset): Keep the most recent N hourly snapshots (one per hour).
- `RETENTION_DAILY` (default: unset): Keep the most recent N daily snapshots (one per day).
- `RETENTION_MONTHLY` (default: unset): Keep the most recent N monthly snapshots (one per month).
- `RETENTION_YEARLY` (default: unset): Keep the most recent N yearly snapshots (one per year).
- `NTFY_URL` (default: unset): Base URL for ntfy (e.g. `https://ntfy.sh`).
- `NTFY_TOPIC` (default: unset): ntfy topic name to publish to.
- `BACKUP_SCHEDULE` (default: unset): Set to `daily` to run continuously and take one snapshot per day at `DAILY_TIME`.
- `DAILY_TIME` (default: `00:00`): Time of day for daily backups (24h `HH:MM`).

If any of the `RETENTION_*` values are set, time-based retention is used and `MAX_SNAPSHOTS` is ignored. Retention keeps the newest snapshot per hour/day/month/year up to the specified counts (e.g., `RETENTION_DAILY=30` and `RETENTION_MONTHLY=12` keeps the last 30 days and one per month for 12 months). The same retention policy is also applied to the remote `REMOTE_DIR` daily folders.

## Build and Run Instructions

### Option 1: Pull from Gitea/Docker Hub
Prebuilt image on alpine linux, hosted on docker hub and gitea

1. Pull from Docker Hub
```bash
docker pull blackops010/cephfs-snapshot-docker:latest
```

#### 2. Pull from Gitea Docker Registry
```bash
docker pull git.nicholstech.org/david/cephfs-backup-docker:latest
```
#### 3. Run the Docker Container
After pulling the image, you can run the container using the following command:

```bash
docker run --name cephfs-snapshot \
    -v /mnt/cephfs:/mnt/cephfs \
    blackops010/cephfs-snapshot-docker:latest
```

For Gitea:
```bash
docker run --name cephfs-snapshot \
    -v /mnt/cephfs:/mnt/cephfs \
    git.nicholstech.org/david/cephfs-backup-docker:latest
```
Running with Docker Compose
You can also use Docker Compose to manage the container. To do so, create a docker-compose.yml file with the following content:

```yaml
services:
  cephfs-snapshot:
    image: blackops010/cephfs-snapshot-docker
    container_name: cephfs-snapshot
    environment:
      - CEPHFS_MOUNT=/mnt/cephfs
      - SNAPSHOT_DIR=/mnt/cephfs/.snap
      - RETENTION_DAILY=30
      - RETENTION_MONTHLY=12
      - BACKUP_SCHEDULE=daily
      - DAILY_TIME=00:00
      - NTFY_URL=https://ntfy.sh
      - NTFY_TOPIC=backup
      - REMOTE_DIR=/mnt/unraid/Backup/cephfs
    volumes:
      - /mnt/cephfs:/mnt/cephfs  # CephFS mount on the host
      - /mnt/unraid:/mnt/unraid  # Unraid or backup destination on the host
    restart: unless-stopped
```
If pulling from Gitea or Docker Hub, make sure to change the image field to reflect the correct registry:
For Docker Hub: blackops010/cephfs-snapshot-docker:latest
For Gitea: git.nicholstech.org/david/cephfs-backup-docker:latest

#### 5. Start with Docker Compose
To build and start the container using Docker Compose, run:

```bash
docker-compose up -d
```
This will build the image (if necessary) and run the container in detached mode.

### Option 2: Build from Source

You can build the Docker image locally using the source code from this repository.

#### 1. Build the Docker Image

To build the Docker image, run the following command from the directory containing the `Dockerfile` and `cephfs-snapshot.sh`:

#### 2. Run the Docker Container
You can run the container with default values by running the following command:

```bash
docker run --name cephfs-snapshot \
    -v /mnt/cephfs:/mnt/cephfs \
    cephfs-snapshot-docker
```

#### 3. Run with Custom Environment Variables
To override the default environment variables, use the -e flags during the docker run command:

```bash
docker run --name cephfs-snapshot \
    -v /mnt/cephfs:/mnt/cephfs \
    -e CEPHFS_MOUNT=/custom/cephfs_mount \
    -e SNAPSHOT_DIR=/custom/cephfs_mount/.snap \
    -e RETENTION_DAILY=30 \
    -e RETENTION_MONTHLY=12 \
    -e BACKUP_SCHEDULE=daily \
    -e DAILY_TIME=00:00 \
    -e NTFY_URL=https://ntfy.sh \
    -e NTFY_TOPIC=cephfs-backups \
    -e REMOTE_DIR=/mnt/unraid/custom_backup \
    cephfs-snapshot-docker
```
