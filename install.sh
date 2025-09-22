#!/bin/bash

# Installation script for gcs-sync service
# Usage: sudo ./gcs-sync-install.sh
# Installs dependencies, sets up scripts, config, and systemd service
# Resilient to existing Google Cloud SDK configurations and authentication issues

set -e

# Default installation paths
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/gcs-sync"
SERVICE_DIR="/etc/systemd/system"
LOG_DIR="/var/log/gcs-sync"
SCRIPT_NAME="sync_to_gcs.sh"
SERVICE_NAME="gcs-sync.service"
CONFIG_NAME="config.conf"
KEYRING_DIR="/usr/share/keyrings"
GCS_KEYRING="$KEYRING_DIR/cloud.google.gpg"
REPO_FILE="/etc/apt/sources.list.d/google-cloud-sdk.list"
DEFAULT_CREDENTIALS="/etc/gcs/crackit-cloud.json"

echo "Installing gcs-sync service..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Install dependencies
echo "Installing dependencies (curl, apt-transport-https, ca-certificates, gnupg)..."
apt-get update
apt-get install -y curl apt-transport-https ca-certificates gnupg

# Clean up existing Google Cloud SDK repository and keys
echo "Cleaning up existing Google Cloud SDK repository configurations..."
rm -f "$REPO_FILE"
rm -f /etc/apt/keyrings/google-cloud-sdk.gpg
find /etc/apt/sources.list.d/ -type f -exec sed -i '/packages.cloud.google.com/d' {} +
find /etc/apt/sources.list -type f -exec sed -i '/packages.cloud.google.com/d' {} +

# Add Google Cloud SDK repository
if [ ! -f "$GCS_KEYRING" ]; then
    mkdir -p "$KEYRING_DIR"
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor > "$GCS_KEYRING"
    chmod 644 "$GCS_KEYRING"
fi
echo "deb [signed-by=$GCS_KEYRING] https://packages.cloud.google.com/apt cloud-sdk main" | tee "$REPO_FILE"

# Update and install Google Cloud SDK
apt-get update
if ! command -v gsutil &> /dev/null || ! command -v gcloud &> /dev/null; then
    echo "Installing google-cloud-sdk..."
    apt-get install -y google-cloud-sdk
else
    echo "Google Cloud SDK already installed, skipping installation."
fi

# Create directories
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
chown www-data:www-data "$LOG_DIR"
chmod 755 "$LOG_DIR"
touch "$LOG_DIR/gcs-sync.log"
chown www-data:www-data "$LOG_DIR/gcs-sync.log"
chmod 664 "$LOG_DIR/gcs-sync.log"

# Create writable directories for www-data
mkdir -p /var/www/.config/gcloud
mkdir -p /var/www/.cache/google-cloud-sdk
mkdir -p /var/www/.gsutil
chown -R www-data:www-data /var/www/.config /var/www/.cache /var/www/.gsutil
chmod -R 700 /var/www/.config /var/www/.cache /var/www/.gsutil

# Create gsutil config file
sudo -u www-data bash -c 'echo "[Boto]" > /var/www/.gsutil/gsutil.cfg && echo "state_dir = /var/www/.gsutil" >> /var/www/.gsutil/gsutil.cfg'
chown www-data:www-data /var/www/.gsutil/gsutil.cfg
chmod 600 /var/www/.gsutil/gsutil.cfg

# Prompt for credentials file and validate
echo "Please provide the path to your GCS service account JSON key (default: $DEFAULT_CREDENTIALS):"
read -r USER_CREDENTIALS_PATH
USER_CREDENTIALS_PATH=${USER_CREDENTIALS_PATH:-$DEFAULT_CREDENTIALS}
if [ -f "$USER_CREDENTIALS_PATH" ]; then
    if grep -q '"type": "service_account"' "$USER_CREDENTIALS_PATH"; then
        cp "$USER_CREDENTIALS_PATH" "$CONFIG_DIR/crackit-cloud.json"
        chown www-data:www-data "$CONFIG_DIR/crackit-cloud.json"
        chmod 600 "$CONFIG_DIR/crackit-cloud.json"
    else
        echo "Error: $USER_CREDENTIALS_PATH is not a valid service account JSON key"
        exit 1
    fi
else
    echo "Error: Credentials file $USER_CREDENTIALS_PATH not found"
    exit 1
fi

# Test credentials as www-data
echo "Testing credentials as www-data..."
if ! sudo -u www-data bash -c "export GOOGLE_APPLICATION_CREDENTIALS=$CONFIG_DIR/crackit-cloud.json && export BOTO_CONFIG=/var/www/.gsutil/gsutil.cfg && /usr/bin/gsutil -o Credentials:gs_service_key_file=$CONFIG_DIR/crackit-cloud.json ls gs://crackit-technologies/playground/theuri/sync 2>/tmp/gcs-sync-test.log"; then
    echo "Error: Authentication test failed for www-data. Check credentials and bucket permissions."
    echo "Debug output in /tmp/gcs-sync-test.log"
    cat /tmp/gcs-sync-test.log
    echo "Run 'sudo -u www-data bash -c \"export GOOGLE_APPLICATION_CREDENTIALS=$CONFIG_DIR/crackit-cloud.json && export BOTO_CONFIG=/var/www/.gsutil/gsutil.cfg && /usr/bin/gsutil -o Credentials:gs_service_key_file=$CONFIG_DIR/crackit-cloud.json ls gs://crackit-technologies/playground/theuri/sync\"' to debug."
    exit 1
fi

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
export BOTO_CONFIG="/var/www/.gsutil/gsutil.cfg"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Using credentials: $CREDENTIALS_PATH" >> "$LOG_FILE"

# Test authentication
if ! "$GSUTIL" -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" ls "$GCS_BUCKET" >/dev/null 2>>"$LOG_FILE"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Authentication failed - cannot list bucket $GCS_BUCKET" >> "$LOG_FILE"
    exit 1
fi

# Function to perform sync
sync_folder() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync from $LOCAL_PATH to $GCS_BUCKET" >> "$LOG_FILE"
    if [ "$DELETE" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Deleting files in $GCS_BUCKET not in $LOCAL_PATH" >> "$LOG_FILE"
        "$GSUTIL" -m -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" rsync -r -d "$LOCAL_PATH" "$GCS_BUCKET" >> "$LOG_FILE" 2>&1
    else
        "$GSUTIL" -m -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" rsync -r "$LOCAL_PATH" "$GCS_BUCKET" >> "$LOG_FILE" 2>&1
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

# Install systemd service with updated paths
cat << EOF > "$SERVICE_DIR/$SERVICE_NAME"
[Unit]
Description=Google Cloud Storage Sync Service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/html/cloud
ExecStart=/usr/local/bin/sync_to_gcs.sh --local-path /var/www/html/cloud/test --gcs-bucket gs://crackit-technologies/playground/theuri/sync
Restart=always
RestartSec=10
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="GOOGLE_APPLICATION_CREDENTIALS=/etc/gcs-sync/crackit-cloud.json"
Environment="BOTO_CONFIG=/var/www/.gsutil/gsutil.cfg"
ProtectHome=false
ProtectSystem=false
PrivateTmp=false

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