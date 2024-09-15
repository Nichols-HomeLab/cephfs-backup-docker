# CephFS Snapshot Docker Container

This Docker container creates snapshots of your CephFS mount and backs them up to a remote directory. It also handles log file management and keeps a fixed number of snapshots based on environment variables.

## Features
- Snapshot creation for CephFS mount points.
- Customizable backup and logging directories.
- Automatic old snapshot removal after exceeding a defined threshold.

## Environment Variables
The following environment variables can be set to customize the behavior of the container:

- `CEPHFS_MOUNT` (default: `/mnt/cephfs`): The mount point of the CephFS filesystem.
- `SNAPSHOT_DIR` (default: `/$CEPHFS_MOUNT/.snap`): Directory where snapshots will be stored.
- `LOG_FILE` (default: `$CEPHFS_MOUNT/cephfs_snapshot.log`): Path to the log file.
- `MAX_SNAPSHOTS` (default: `7`): The maximum number of snapshots to keep.
- `REMOTE_DIR` (default: `/mnt/unraid/Backup/cephfs/`): Remote directory where snapshots and logs will be copied.

## Build and Run Instructions

### 1. Build the Docker Image

To build the Docker image, run the following command from the directory containing the `Dockerfile` and `cephfs-snapshot.sh`:

```bash
docker build -t my-cephfs-snapshot-container .
```

### 2. Run the Docker Container

You can run the container with default values by running the following command:

```bash
docker run --name cephfs-snapshot my-cephfs-snapshot-container
```
### 3. Run with Custom Environment Variables
To override the default environment variables, use the -e flags during the docker run command:

```bash
docker run --name cephfs-snapshot \
    -e CEPHFS_MOUNT=/custom/cephfs_mount \
    -e SNAPSHOT_DIR=/custom/cephfs_mount/.snap \
    -e MAX_SNAPSHOTS=5 \
    -e REMOTE_DIR=/mnt/unraid/custom_backup \
    my-cephfs-snapshot-container
```

### 4. Running with Docker Compose
You can also use Docker Compose to manage the container. See the docker-compose.yml section below for more details.

Docker Compose
You can manage this container using Docker Compose. To do so, create a docker-compose.yml file with the following content:
```bash
services:
  cephfs-snapshot:
    image: my-cephfs-snapshot-container
    container_name: cephfs-snapshot
    environment:
      - CEPHFS_MOUNT=/mnt/cephfs
      - SNAPSHOT_DIR=/mnt/cephfs/.snap
      - MAX_SNAPSHOTS=7
      - REMOTE_DIR=/mnt/unraid/Backup/cephfs
    volumes:
      - /mnt/cephfs:/mnt/cephfs  # CephFS mount on the host
      - /mnt/unraid:/mnt/unraid  # Unraid or backup destination on the host
    restart: unless-stopped
```