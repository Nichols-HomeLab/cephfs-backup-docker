# CephFS And RBD Backup Docker Container

This repository contains two backup entrypoints built into the same image:

- `cephfs-snapshot.sh`: creates snapshots of a mounted CephFS path and copies them to a remote directory.
- `rbd-backup.sh`: creates Ceph RBD snapshots and exports them to a NAS as weekly full raw images, daily incremental diffs, and monthly full raw images.

Both scripts support scheduled daily execution and optional ntfy notifications.

## Features
- CephFS snapshot creation for mounted CephFS paths.
- RBD snapshot creation plus raw export and diff export workflows for block images.
- Customizable backup and logging directories.
- Automatic old snapshot and backup pruning based on retention settings.
- Optional ntfy notifications for success and failure.

## CephFS Environment Variables
The following environment variables control `cephfs-snapshot.sh`:

- `CEPHFS_MOUNT` (default: `/mnt/cephfs`): The mount point of the CephFS filesystem.
- `SNAPSHOT_DIR` (default: `/$CEPHFS_MOUNT/.snap`): Directory where snapshots will be stored.
- `LOG_FILE` (default: `$CEPHFS_MOUNT/cephfs_snapshot.log`): Path to the log file.
- `MAX_SNAPSHOTS` (default: `7`): The maximum number of snapshots to keep (used only if no time-based retention variables are set).
- `REMOTE_DIR` (default: `/backup/Lab/cephfs`): Remote directory where snapshots and logs will be copied. Daily backups are stored in `REMOTE_DIR/YYYY-MM-DD/` and contain the snapshot contents (no extra nested snapshot directory).
- `RETENTION_HOURLY` (default: unset): Keep the most recent N hourly snapshots (one per hour).
- `RETENTION_DAILY` (default: unset): Keep the most recent N daily snapshots (one per day).
- `RETENTION_MONTHLY` (default: unset): Keep the most recent N monthly snapshots (one per month).
- `RETENTION_YEARLY` (default: unset): Keep the most recent N yearly snapshots (one per year).
- `NTFY_URL` (default: unset): Base URL for ntfy (e.g. `https://ntfy.sh`).
- `NTFY_TOPIC` (default: unset): ntfy topic name to publish to.
- `BACKUP_SCHEDULE` (default: unset): Set to `daily` to run continuously and take one snapshot per day at `DAILY_TIME`.
- `DAILY_TIME` (default: `00:00`): Time of day for daily backups (24h `HH:MM`).

If any of the `RETENTION_*` values are set, time-based retention is used and `MAX_SNAPSHOTS` is ignored. Retention keeps the newest snapshot per hour/day/month/year up to the specified counts (e.g., `RETENTION_DAILY=30` and `RETENTION_MONTHLY=12` keeps the last 30 days and one per month for 12 months). The same retention policy is also applied to the remote `REMOTE_DIR` daily folders.

## RBD Environment Variables
The following environment variables control `rbd-backup.sh`:

- `RBD_POOL` (required): Ceph pool containing the RBD images to back up.
- `RBD_IMAGES` (default: unset): Optional comma-separated image list. If unset, every image returned by `rbd ls $RBD_POOL` is backed up.
- `RBD_EXPORT_ROOT` (default: `/backup/Lab/rbd`): Root directory on the NAS for RBD exports.
- `RBD_LOG_FILE` (default: `/var/log/rbd-backup.log`): Log file path inside the container.
- `RBD_CEPH_ID` (default: unset): Optional Ceph client ID passed to `rbd --id`. Use `docker` if you want the limited `client.docker` user from your cluster config.
- `RBD_KEYRING` (default: unset): Optional Ceph keyring path passed to `rbd --keyring`.
- `RBD_CONF` (default: unset): Optional Ceph config path passed to `rbd --conf`.
- `RBD_RETENTION_DAILY` (default: `30`): Number of daily Ceph snapshots to keep per image.
- `RBD_RETENTION_MONTHLY` (default: `12`): Number of monthly Ceph snapshots to keep per image.
- `RBD_RETENTION_DAILY_DIFFS` (default: `30`): Number of daily `rbd export-diff` files to keep per image.
- `RBD_RETENTION_WEEKLY_FULLS` (default: `8`): Number of weekly full raw exports to keep per image.
- `RBD_RETENTION_MONTHLY_FULLS` (default: `12`): Number of monthly full raw exports to keep per image.
- `RBD_WEEKLY_FULL_DAY` (default: `7`): ISO weekday for weekly full exports (`1` = Monday, `7` = Sunday).
- `RBD_MONTHLY_FULL_DAY` (default: `1`): Day of month for monthly full exports. Limited to `1-28` to avoid short-month edge cases.
- `RBD_DAILY_SNAPSHOT_PREFIX` (default: `daily`): Prefix for daily Ceph snapshots.
- `RBD_MONTHLY_SNAPSHOT_PREFIX` (default: `monthly`): Prefix for monthly Ceph snapshots.
- `RBD_PRE_BACKUP_HOOK` (default: unset): Optional shell command run before the backup starts. Use this to quiesce applications.
- `RBD_POST_BACKUP_HOOK` (default: unset): Optional shell command run after the backup completes.
- `BACKUP_SCHEDULE` (default: unset): Set to `daily` to run continuously and execute once per day at `DAILY_TIME`.
- `DAILY_TIME` (default: `00:00`): Time of day for scheduled runs (24h `HH:MM`).
- `NTFY_URL` and `NTFY_TOPIC`: Optional ntfy destination for success/failure notifications.

The RBD backup layout on the NAS is:

```text
RBD_EXPORT_ROOT/
  <pool>/<image>/
    full/
      weekly/
        <image>-YYYY-MM-DD.raw
      monthly/
        <image>-YYYY-MM.raw
    diff/
      daily/
        <image>-YYYY-MM-DD.rbdiff
```

Each exported file also gets a `.sha256` checksum file.

The default retention now matches the CephFS service:

- Ceph snapshots: `30` daily and `12` monthly.
- NAS exports: `30` daily diffs, `8` weekly raw fulls, and `12` monthly raw fulls.

Restore flow:

1. For an in-cluster rollback, restore or clone from the retained Ceph snapshots.
2. For an off-cluster restore, import the most recent full raw export with `rbd import`.
3. If you need a day backed up as a diff, import the full first and then replay each diff in order with `rbd import-diff`.

## Build and Run Instructions

### Option 1: Build And Run With Docker Compose
The checked-in compose file now matches the live homelab setup:

- CephFS mounted on the host at `/mnt/cephfs`
- Ceph config and keyrings in `/etc/ceph`
- RBD images in pool `rbd`
- NAS backup target exported from `10.0.30.116:/mnt/user/Backup`

The services write to:

- CephFS backups: `/backup/Lab/cephfs`
- RBD backups: `/backup/Lab/rbd`

```yaml
services:
  cephfs-snapshot:
    build: .
    image: cephfs-backup-docker:local
    environment:
      - CEPHFS_MOUNT=/mnt/cephfs
      - SNAPSHOT_DIR=/mnt/cephfs/.snap
      - RETENTION_DAILY=30
      - RETENTION_MONTHLY=12
      - BACKUP_SCHEDULE=daily
      - DAILY_TIME=00:00
      - REMOTE_DIR=/backup/Lab/cephfs
    volumes:
      - /mnt/cephfs:/mnt/cephfs
      - unraid-backup:/backup

  rbd-backup:
    build: .
    image: cephfs-backup-docker:local
    entrypoint: ["/usr/local/bin/rbd-backup.sh"]
    environment:
      - RBD_POOL=rbd
      - RBD_CEPH_ID=docker
      - RBD_KEYRING=/etc/ceph/ceph.client.docker.keyring
      - RBD_CONF=/etc/ceph/ceph.conf
      - RBD_EXPORT_ROOT=/backup/Lab/rbd
      - RBD_RETENTION_DAILY=30
      - RBD_RETENTION_MONTHLY=12
      - RBD_RETENTION_DAILY_DIFFS=30
      - RBD_RETENTION_WEEKLY_FULLS=8
      - RBD_RETENTION_MONTHLY_FULLS=12
      - RBD_WEEKLY_FULL_DAY=7
      - RBD_MONTHLY_FULL_DAY=1
      - BACKUP_SCHEDULE=daily
      - DAILY_TIME=01:00
    volumes:
      - /etc/ceph:/etc/ceph:ro
      - unraid-backup:/backup

volumes:
  unraid-backup:
    driver: local
    driver_opts:
      type: nfs
      o: addr=10.0.30.116,rw,nfsvers=4.2,proto=tcp,hard,timeo=600,retrans=2
      device: :/mnt/user/Backup
```

Start the stack:

```bash
docker compose up -d --build
```

Stop it:

```bash
docker compose down
```

One-shot validation runs:

```bash
docker compose run --rm -e BACKUP_SCHEDULE= -e NTFY_URL= -e NTFY_TOPIC= cephfs-snapshot
docker compose run --rm -e BACKUP_SCHEDULE= -e NTFY_URL= -e NTFY_TOPIC= -e RBD_IMAGES=notifications-ntfy-etc rbd-backup
```

If your Ceph auth material lives outside `/etc/ceph`, mount the additional keyring path into the `rbd-backup` service as read-only.

### Option 2: Run A Single Service Manually
CephFS:

```bash
docker run --name cephfs-snapshot \
    -v /mnt/cephfs:/mnt/cephfs \
    -v cephfs-backup-docker_unraid-backup:/backup \
    -e REMOTE_DIR=/backup/Lab/cephfs \
    cephfs-backup-docker:local
```

RBD:

```bash
docker run --name rbd-backup \
    -v /etc/ceph:/etc/ceph:ro \
    -v cephfs-backup-docker_unraid-backup:/backup \
    -e RBD_POOL=rbd \
    -e RBD_CEPH_ID=docker \
    -e RBD_KEYRING=/etc/ceph/ceph.client.docker.keyring \
    -e RBD_CONF=/etc/ceph/ceph.conf \
    -e RBD_EXPORT_ROOT=/backup/Lab/rbd \
    --entrypoint /usr/local/bin/rbd-backup.sh \
    cephfs-backup-docker:local
```

### Build The Image

```bash
docker build -t cephfs-backup-docker:local .
```

### Launch File

The same live configuration is also saved at [`/home/ubuntu/ceph.yml`](/home/ubuntu/ceph.yml) so you can launch it directly with:

```bash
docker compose -f /home/ubuntu/ceph.yml up -d --build
```
