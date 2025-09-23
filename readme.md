# GCS Sync Tool

A tool to sync multiple local folders to a Google Cloud Storage (GCS) bucket as a systemd service.

## Installation
1. Clone the repository.
2. Place your GCS service account JSON key at `/etc/gcs/gcs-cloud.json`.
3. Run `sudo ./install.sh` and follow prompts.
4. Edit `/etc/systemd/system/gcssync.service` to specify multiple `--local-path` arguments and the `--gcs-bucket` path.

## Usage
- Start: `sudo systemctl start gcssync`
- Status: `sudo systemctl status gcssync`
- Logs: `tail -f /var/log/gcssync/gcssync.log`
- Sync multiple folders: Add `--local-path` for each folder in `ExecStart`.

## Notes
- Bucket paths are auto-created if they don’t exist.
- Use `--delete` cautiously to avoid data loss.
- Bucket versioning should be enabled for recovery.