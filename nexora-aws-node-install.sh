#!/bin/bash

set -e

echo "==========================================="
echo "NEXORA - AWS PTERODACTYL NODE SETUP"
echo "==========================================="

# =========================================================
# 0. ROOT CHECK
# =========================================================

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This installer must be run as root."
    echo "Run: sudo bash nexora-aws-node-install.sh"
    exit 1
fi

# =========================================================
# 1. HOSTNAME
# =========================================================

echo
echo "Configuring hostname: nexora..."

hostnamectl set-hostname nexora

if ! grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]+nexora([[:space:]]|$)' /etc/hosts; then
    echo "127.0.1.1 nexora" >> /etc/hosts
fi

echo "Hostname: $(hostname)"

# =========================================================
# 2. CHECK OS
# =========================================================

echo
echo "Checking operating system..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "OS: $PRETTY_NAME"
else
    echo "ERROR: Cannot detect operating system."
    exit 1
fi

case "$ID" in
    ubuntu|debian)
        echo "Supported OS detected."
        ;;
    *)
        echo "ERROR: This script is designed for Ubuntu/Debian."
        echo "Detected: $ID"
        exit 1
        ;;
esac

# =========================================================
# 3. CHECK VIRTUALIZATION
# =========================================================

echo
echo "Checking virtualization..."

VIRT="$(systemd-detect-virt 2>/dev/null || true)"

if [[ "$VIRT" == "lxc" || "$VIRT" == "openvz" || "$VIRT" == "virtuozzo" ]]; then
    echo "ERROR: Unsupported virtualization detected: $VIRT"
    echo "Pterodactyl Wings may not work correctly in this environment."
    exit 1
fi

echo "Virtualization: ${VIRT:-none}"

# =========================================================
# 4. PACKAGE CLEANUP
# =========================================================

echo
echo "Refreshing package lists..."

apt-get update

# =========================================================
# 5. BASIC DEPENDENCIES
# =========================================================

echo
echo "Installing required packages..."

apt-get install -y \
    curl \
    ca-certificates \
    psmisc \
    ufw \
    jq \
    file

# =========================================================
# 6. DOCKER
# =========================================================

echo
echo "Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker from Ubuntu/Debian repositories..."
    apt-get install -y docker.io containerd
else
    echo "Docker is already installed."
fi

# =========================================================
# 7. START DOCKER
# =========================================================

echo
echo "Starting Docker..."

systemctl daemon-reload
systemctl enable --now docker

if ! systemctl is-active --quiet docker; then
    echo "ERROR: Docker failed to start."
    systemctl status docker --no-pager || true
    exit 1
fi

echo "Docker is running."
docker --version

# =========================================================
# 8. TEST DOCKER
# =========================================================

echo
echo "Testing Docker..."

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not responding correctly."
    exit 1
fi

echo "Docker engine test passed."

# =========================================================
# 9. PTERODACTYL DIRECTORIES
# =========================================================

echo
echo "Creating Pterodactyl directories..."

mkdir -p /etc/pterodactyl
mkdir -p /var/log/pterodactyl
mkdir -p /var/run/wings

chmod 755 /etc/pterodactyl
chmod 755 /var/log/pterodactyl

echo "Directories created."

# =========================================================
# 10. DETECT CPU ARCHITECTURE
# =========================================================

echo
echo "Detecting CPU architecture..."

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)
        WINGS_ARCH="amd64"
        ;;
    aarch64|arm64)
        WINGS_ARCH="arm64"
        ;;
    *)
        echo "ERROR: Unsupported CPU architecture: $ARCH"
        exit 1
        ;;
esac

echo "Architecture: $ARCH"
echo "Wings binary: $WINGS_ARCH"

# =========================================================
# 11. DOWNLOAD PTERODACTYL WINGS
# =========================================================

echo
echo "Downloading Pterodactyl Wings..."

WINGS_URL="https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
TEMP_WINGS="$(mktemp)"

cleanup() {
    rm -f "$TEMP_WINGS"
}
trap cleanup EXIT

curl -fL --retry 3 --retry-delay 2 -o "$TEMP_WINGS" "$WINGS_URL"

if [ ! -s "$TEMP_WINGS" ]; then
    echo "ERROR: Wings download is empty."
    exit 1
fi

install -m 755 "$TEMP_WINGS" /usr/local/bin/wings

# =========================================================
# 12. VERIFY WINGS
# =========================================================

echo
echo "Verifying Wings binary..."

if ! /usr/local/bin/wings --version; then
    echo "ERROR: Wings binary verification failed."
    file /usr/local/bin/wings
    exit 1
fi

echo "Wings installed successfully."

# =========================================================
# 13. CREATE SYSTEMD SERVICE
# =========================================================

echo
echo "Creating Wings systemd service..."

cat > /etc/systemd/system/wings.service <<'SERVICE'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 /etc/systemd/system/wings.service
systemctl daemon-reload

echo "Wings service created."

# =========================================================
# 14. FIREWALL RULES
# =========================================================

echo
echo "Adding local firewall rules..."

# SSH; preserve access if UFW is enabled later.
ufw allow 22/tcp

# Pterodactyl SFTP port.
ufw allow 2022/tcp

# Common Wings API port.
ufw allow 8080/tcp

# Optional HTTPS/proxy port used by some setups.
ufw allow 8443/tcp

echo "Firewall rules added."
echo "UFW has NOT been enabled automatically."
echo "Configure AWS Security Group rules separately."

# =========================================================
# 15. FINAL CHECKS
# =========================================================

echo
echo "==========================================="
echo "NEXORA AWS NODE BASE SETUP COMPLETE"
echo "==========================================="

echo
echo "Hostname:"
hostname

echo
echo "Docker:"
systemctl is-active docker

echo
echo "Wings:"
/usr/local/bin/wings --version

echo
echo "Virtualization:"
systemd-detect-virt 2>/dev/null || true

echo
echo "==========================================="
echo "NEXT STEP: CONFIGURE THE NODE IN YOUR PANEL"
echo "==========================================="

echo
echo "1. Open your Pterodactyl Panel."
echo "2. Create a node named: nexora"
echo "3. Copy the configuration generated by the Panel."
echo "4. Save it to: /etc/pterodactyl/config.yml"
echo "5. Test Wings with: wings --debug"
echo "6. After the debug test succeeds, run:"
echo "   systemctl enable --now wings"
echo "7. Check the service with:"
echo "   systemctl status wings --no-pager"
echo
echo "Do not start Wings until config.yml exists."
echo "Also open the required ports in the AWS Security Group."
echo "==========================================="
