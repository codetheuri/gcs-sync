#!/bin/bash

# Installation script for gcssync service
# Usage: sudo ./install.sh
# Installs dependencies, sets up scripts, config, and systemd service
# Resilient to Google Cloud SDK configurations and authentication issues

set -e

# Default installation paths
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/gcs"
SERVICE_DIR="/etc/systemd/system"
LOG_DIR="/var/log/gcssync"
SCRIPT_NAME="sync_to_gcs.sh"
SERVICE_NAME="gcssync.service"
CONFIG_NAME="config.conf"
KEYRING_DIR="/usr/share/keyrings"
GCS_KEYRING="$KEYRING_DIR/cloud.google.gpg"
REPO_FILE="/etc/apt/sources.list.d/google-cloud-sdk.list"
DEFAULT_CREDENTIALS="/etc/gcs/gcs-cloud.json"

echo "Installing gcssync service..."

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
touch "$LOG_DIR/gcssync.log"
chown www-data:www-data "$LOG_DIR/gcssync.log"
chmod 664 "$LOG_DIR/gcssync.log"

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
        cp "$USER_CREDENTIALS_PATH" "$CONFIG_DIR/gcs-cloud.json"
        chown www-data:www-data "$CONFIG_DIR/gcs-cloud.json"
        chmod 600 "$CONFIG_DIR/gcs-cloud.json"
    else
        echo "Error: $USER_CREDENTIALS_PATH is not a valid service account JSON key"
        exit 1
    fi
else
    echo "Error: Credentials file $USER_CREDENTIALS_PATH not found"
    exit 1
fi

# Extract project ID
PROJECT_ID=$(grep project_id "$CONFIG_DIR/gcs-cloud.json" | cut -d'"' -f4)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Could not extract project_id from $CONFIG_DIR/gcs-cloud.json"
    exit 1
fi

# Test credentials as www-data
echo "Testing credentials as www-data..."
if ! sudo -u www-data bash -c "export GOOGLE_APPLICATION_CREDENTIALS=$CONFIG_DIR/gcs-cloud.json && export BOTO_CONFIG=/var/www/.gsutil/gsutil.cfg && export CLOUDSDK_CORE_PROJECT=$PROJECT_ID && /usr/bin/gsutil -o Credentials:gs_service_key_file=$CONFIG_DIR/gcs-cloud.json ls 2>/tmp/gcssync-test.log"; then
    echo "Error: Authentication test failed for www-data. Check credentials and bucket permissions."
    echo "Debug output in /tmp/gcssync-test.log"
    cat /tmp/gcssync-test.log
    echo "Run 'sudo -u www-data bash -c \"export GOOGLE_APPLICATION_CREDENTIALS=$CONFIG_DIR/gcs-cloud.json && export BOTO_CONFIG=/var/www/.gsutil/gsutil.cfg && export CLOUDSDK_CORE_PROJECT=$PROJECT_ID && /usr/bin/gsutil -o Credentials:gs_service_key_file=$CONFIG_DIR/gcs-cloud.json ls\"' to debug."
    exit 1
fi

# Install sync_to_gcs.sh
cat << 'EOF' > "$INSTALL_DIR/$SCRIPT_NAME"
#!/bin/bash

# Syncs multiple local folders to Google Cloud Storage (GCS) as a system service
# Usage: sync_to_gcs.sh --local-path <path1> --gcs-bucket <bucket1> [--local-path <path2> --gcs-bucket <bucket2> ...] [--interval <seconds>] [--delete]
# Config: /etc/gcs/config.conf for credentials and defaults

set -e

# Default values
CONFIG_FILE="/etc/gcs/config.conf"
LOG_FILE="/var/log/gcssync/gcssync.log"
GSUTIL="/usr/bin/gsutil"
INTERVAL=0
DELETE=false
PATH_PAIRS=()

# Load config file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Config file $CONFIG_FILE not found" >> "$LOG_FILE"
    exit 1
fi

# Extract project ID
PROJECT_ID=$(grep project_id "$CREDENTIALS_PATH" | cut -d'"' -f4)
if [ -z "$PROJECT_ID" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Could not extract project_id from $CREDENTIALS_PATH" >> "$LOG_FILE"
    exit 1
fi

# Function to display usage
usage() {
    echo "Usage: $0 --local-path <path1> --gcs-bucket <bucket1> [--local-path <path2> --gcs-bucket <bucket2> ...] [--interval <seconds>] [--delete]"
    echo "  --local-path    : Local folder to sync (must be paired with --gcs-bucket)"
    echo "  --gcs-bucket    : GCS bucket path (e.g., gs://my-bucket/path)"
    echo "  --interval      : Sync interval in seconds (default: 0, run once)"
    echo "  --delete        : Delete files in GCS not in local path (use with caution)"
    exit 1
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --local-path) LOCAL_PATH="$2"; shift ;;
        --gcs-bucket) GCS_BUCKET="$2"; PATH_PAIRS+=("$LOCAL_PATH:$GCS_BUCKET"); shift ;;
        --interval) INTERVAL="$2"; shift ;;
        --delete) DELETE=true ;;
        *) echo "$(date '+%Y-%m-%d %H:%M:%S') - Unknown parameter: $1" >> "$LOG_FILE"; usage ;;
    esac
    shift
done

# Validate required parameters
if [ ${#PATH_PAIRS[@]} -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: At least one --local-path and --gcs-bucket pair is required" >> "$LOG_FILE"
    usage
fi

# Validate local paths
for PAIR in "${PATH_PAIRS[@]}"; do
    LOCAL_PATH="${PAIR%%:*}"
    if [ ! -d "$LOCAL_PATH" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Local path $LOCAL_PATH does not exist" >> "$LOG_FILE"
        exit 1
    fi
done

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
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Using credentials: $CREDENTIALS_PATH" >> "$LOG_FILE"

# Function to perform sync for a single folder
sync_folder() {
    local LOCAL_PATH="$1"
    local GCS_BUCKET="$2"
    local FOLDER_NAME=$(basename "$LOCAL_PATH")
    local DEST_PATH="$GCS_BUCKET/$FOLDER_NAME"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync from $LOCAL_PATH to $DEST_PATH" >> "$LOG_FILE"
    
    # Test authentication and create bucket path if needed
    if ! "$GSUTIL" -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" ls "$GCS_BUCKET" >/dev/null 2>>"$LOG_FILE"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Bucket path $GCS_BUCKET does not exist, attempting to create..." >> "$LOG_FILE"
        DUMMY_FILE=$(mktemp)
        "$GSUTIL" -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" cp "$DUMMY_FILE" "$GCS_BUCKET/dummy.txt" >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            "$GSUTIL" -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" rm "$GCS_BUCKET/dummy.txt" >> "$LOG_FILE" 2>&1
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Bucket path $GCS_BUCKET created successfully" >> "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Failed to create bucket path $GCS_BUCKET" >> "$LOG_FILE"
            exit 1
        fi
    fi

    # Perform sync
    if [ "$DELETE" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Deleting files in $DEST_PATH not in $LOCAL_PATH" >> "$LOG_FILE"
        "$GSUTIL" -m -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" rsync -r -d "$LOCAL_PATH" "$DEST_PATH" >> "$LOG_FILE" 2>&1
    else
        "$GSUTIL" -m -o Credentials:gs_service_key_file="$CREDENTIALS_PATH" rsync -r "$LOCAL_PATH" "$DEST_PATH" >> "$LOG_FILE" 2>&1
    fi
    if [ $? -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully for $LOCAL_PATH to $DEST_PATH" >> "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync failed for $LOCAL_PATH to $DEST_PATH" >> "$LOG_FILE"
        exit 1
    fi
}

# Run sync for all path pairs
if [ "$INTERVAL" -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting continuous sync every $INTERVAL seconds" >> "$LOG_FILE"
    while true; do
        for PAIR in "${PATH_PAIRS[@]}"; do
            LOCAL_PATH="${PAIR%%:*}"
            GCS_BUCKET="${PAIR#*:}"
            sync_folder "$LOCAL_PATH" "$GCS_BUCKET"
        done
        sleep "$INTERVAL"
    done
else
    for PAIR in "${PATH_PAIRS[@]}"; do
        LOCAL_PATH="${PAIR%%:*}"
        GCS_BUCKET="${PAIR#*:}"
        sync_folder "$LOCAL_PATH" "$GCS_BUCKET"
    done
fi
EOF

# Set permissions
chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"

# Install config file
cat << EOF > "$CONFIG_DIR/$CONFIG_NAME"
# GCS Sync Configuration
CREDENTIALS_PATH="/etc/gcs/gcs-cloud.json"
PROJECT_ID="$PROJECT_ID"
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
ExecStart=/usr/local/bin/sync_to_gcs.sh --local-path /var/www/html/cloud/test --gcs-bucket gs://crackit-technologies/playground/theuri/sync/test --local-path /var/www/html/cloud/data --gcs-bucket gs://crackit-technologies/playground/theuri/sync/data
Restart=always
RestartSec=10
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="GOOGLE_APPLICATION_CREDENTIALS=/etc/gcs/gcs-cloud.json"
Environment="BOTO_CONFIG=/var/www/.gsutil/gsutil.cfg"
Environment="CLOUDSDK_CORE_PROJECT=$PROJECT_ID"
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

echo "gcssync installed successfully!"
echo "To start the service: sudo systemctl start $SERVICE_NAME"
echo "To check status: sudo systemctl status $SERVICE_NAME"
echo "To stop the service: sudo systemctl stop $SERVICE_NAME"
echo "Edit /etc/gcs/config.conf for credentials and /etc/systemd/system/$SERVICE_NAME for sync settings."
echo "To sync multiple folders to different buckets, edit ExecStart in /etc/systemd/system/$SERVICE_NAME with paired --local-path and --gcs-bucket arguments."