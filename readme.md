# GCS Sync Service

This service syncs a local folder to a Google Cloud Storage (GCS) bucket using `gsutil`, with support for scheduled syncs and systemd integration.

## Features

- Installs dependencies (`gsutil`, `gcloud`)
- Sets up config and credentials
- Installs a sync script to `/usr/local/bin/sync_to_gcs.sh`
- Creates a systemd service for continuous syncing
- Supports interval-based or one-time sync
- Logs sync activity to `/var/log/gcs-sync/gcs-sync.log`

## Installation

Run the installer as root:

```sh
sudo ./gcs-sync-install.sh
```

### Steps Performed

1. Installs required packages (`gsutil`, `gcloud`)
2. Creates directories:
    - `/usr/local/bin`
    - `/etc/gcs-sync`
    - `/var/log/gcs-sync`
3. Installs the sync script: `/usr/local/bin/sync_to_gcs.sh`
4. Prompts for your GCS service account JSON key and stores it at `/etc/gcs-sync/crackit-cloud.json`
5. Creates config file: `/etc/gcs-sync/config.conf`
6. Sets up systemd service: `/etc/systemd/system/gcs-sync.service`
7. Enables the service

## Usage

The sync script can be run manually:

```sh
sync_to_gcs.sh --local-path <local-folder> --gcs-bucket <gs://bucket> [--interval <seconds>] [--delete]
```

- `--local-path`: Path to local folder to sync
- `--gcs-bucket`: GCS bucket path (e.g., `gs://my-bucket/`)
- `--interval`: Sync interval in seconds (default: 0, run once)
- `--delete`: Delete files in GCS not in local path (use with caution)

## Systemd Service

- Service file: `/etc/systemd/system/gcs-sync.service`
- Default syncs `/var/www/html/client/forms` to `gs://crackit-technologies`

### Commands

Start the service:

```sh
sudo systemctl start gcs-sync.service
```

Check status:

```sh
sudo systemctl status gcs-sync.service
```

Stop the service:

```sh
sudo systemctl stop gcs-sync.service
```

## Configuration

- Credentials: `/etc/gcs-sync/crackit-cloud.json`
- Config: `/etc/gcs-sync/config.conf`
- Logs: `/var/log/gcs-sync/gcs-sync.log`
- Edit `/etc/systemd/system/gcs-sync.service` to change sync settings.

## Notes

- Requires root privileges for installation.
- Make sure your GCS service account JSON key is available.
- Edit config files as needed for custom paths or buckets.
