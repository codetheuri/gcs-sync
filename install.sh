```bash
#!/bin/bash

# Installation script for gcs-sync service
# Usage: sudo ./gcs-sync-install.sh
# Installs dependencies, sets up scripts, config, and systemd service

set -e

# Default installation paths
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/gcs-sync"
SERVICE_DIR="/etc/systemd/system"
LOG_DIR="/var/log/gcs-sync"
SCRIPT_NAME="sync_to_gcs.sh"
SERVICE_NAME="gcs-sync.service"
CONFIG_NAME="config.conf"

echo "Installing gcs-sync service..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Install dependencies
echo "Installing dependencies (gsutil, gcloud)..."
apt-get update
apt-get install -y curl apt-transport-https ca-certificates gnupg
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
apt-get update
apt-get install -y google-cloud-sdk

# Create directories
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
chown www-data:www-data "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Install sync_to_gcs.sh
cat << 'EOF' > "$INSTALL_DIR/$SCRIPT_NAME"
#!/bin/bash

# Syncs a local folder to Google Cloud Storage (GCS) as a system service
# Usage: sync_to_gcs.sh --local-path <path> --gcs-bucket <bucket> [--interval <seconds>] [--delete]
# Config: /etc/gcs-sync/config.conf for credentials and defaults

set -e

# Default values
CONFIG_FILE="/etc/gcs-sync/config.conf"
LOG_FILE="/var/log/gcs-sync/gcs-sync.log"
GSUTIL="/usr/bin/gsutil"
INTERVAL=0
DELETE=false

# Load config file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Config file $CONFIG_FILE not found" >> "$LOG_FILE"
    exit 1
fi

# Function to display usage
usage() {
    echo "Usage: $0 --local-path <path> --gcs-bucket <bucket> [--interval <seconds>] [--delete]"
    echo "  --local-path    : Path to local folder to sync"
    echo "  --gcs-bucket    : GCS bucket path (e.g., gs://my-bucket/)"
    echo "  --interval      : Sync interval in seconds (default: 0, run once)"
    echo "  --delete        : Delete files in GCS not in local path (use with caution)"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --local-path) LOCAL_PATH="$2"; shift ;;
        --gcs-bucket) GCS_BUCKET="$2"; shift ;;
        --interval) INTERVAL="$2"; shift ;;
        --delete) DELETE=true ;;
        *) echo "$(date '+%Y-%m-%d %H:%M:%S') - Unknown parameter: $1" >> "$LOG_FILE"; usage ;;
    esac
    shift
done

# Validate required parameters
if [ -z "$LOCAL_PATH" ] || [ -z "$GCS_BUCKET" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: --local-path and --gcs-bucket are required" >> "$LOG_FILE"
    usage
fi

# Validate local path
if [ ! -d "$LOCAL_PATH" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Local path $LOCAL_PATH does not exist" >> "$LOG_FILE"
    exit 1
fi

# Validate gsutil
if ! command -v "$GSUTIL" &> /dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: gsutil not found at $GSUTIL" >> "$LOG_FILE"
    exit 1
fi

# Validate credentials
if [ -z "$CREDENTIALS_PATH" ] || [ ! -f "$CREDENTIALS_PATH" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Credentials file $CREDENTIALS_PATH not found" >> "$LOG_FILE"
    exit 1
fi

# Set Google Cloud credentials
export GOOGLE_APPLICATION_CREDENTIALS="$CREDENTIALS_PATH"
gcloud auth activate-service-account --key-file="$CREDENTIALS_PATH" --quiet || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Warning: gcloud auth failed, falling back to env var" >> "$LOG_FILE"
}

# Test authentication
if ! "$GSUTIL" ls gs://$(basename "$GCS_BUCKET") >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Authentication failed - cannot list bucket" >> "$LOG_FILE"
    exit 1
fi

# Function to perform sync
sync_folder() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync from $LOCAL_PATH to $GCS_BUCKET" >> "$LOG_FILE"
    if [ "$DELETE" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Deleting files in $GCS_BUCKET not in $LOCAL_PATH" >> "$LOG_FILE"
        "$GSUTIL" -m rsync -r -d "$LOCAL_PATH" "$GCS_BUCKET" >> "$LOG_FILE" 2>&1
    else
        "$GSUTIL" -m rsync -r "$LOCAL_PATH" "$GCS_BUCKET" >> "$LOG_FILE" 2>&1
    fi
    if [ $? -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully" >> "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync failed" >> "$LOG_FILE"
        exit 1
    fi
}

# Run sync
if [ "$INTERVAL" -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting continuous sync every $INTERVAL seconds" >> "$LOG_FILE"
    while true; do
        sync_folder
        sleep "$INTERVAL"
    done
else
    sync_folder
fi
EOF

# Set permissions
chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"

# Install config file
cat << EOF > "$CONFIG_DIR/$CONFIG_NAME"
# GCS Sync Configuration
CREDENTIALS_PATH="/etc/gcs-sync/crackit-cloud.json"
# Add more defaults here if needed
EOF

# Prompt for credentials file
echo "Please provide the path to your GCS service account JSON key (e.g., /path/to/crackit-cloud.json):"
read -r USER_CREDENTIALS_PATH
if [ -f "$USER_CREDENTIALS_PATH" ]; then
    cp "$USER_CREDENTIALS_PATH" "$CONFIG_DIR/crackit-cloud.json"
    chown www-data:www-data "$CONFIG_DIR/crackit-cloud.json"
    chmod 600 "$CONFIG_DIR/crackit-cloud.json"
else
    echo "Error: Credentials file $USER_CREDENTIALS_PATH not found"
    exit 1
fi

# Install systemd service
cat << EOF > "$SERVICE_DIR/$SERVICE_NAME"
[Unit]
Description=Google Cloud Storage Sync Service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/local/bin/sync_to_gcs.sh --local-path /var/www/html/client/forms --gcs-bucket gs://crackit-technologies
Restart=always
RestartSec=10
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

# Set permissions
chmod 644 "$SERVICE_DIR/$SERVICE_NAME"

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"

echo "gcs-sync installed successfully!"
echo "To start the service: sudo systemctl start $SERVICE_NAME"
echo "To check status: sudo systemctl status $SERVICE_NAME"
echo "To stop the service: sudo systemctl stop $SERVICE_NAME"
echo "Edit /etc/gcs-sync/config.conf for credentials and /etc/systemd/system/$SERVICE_NAME for sync settings."