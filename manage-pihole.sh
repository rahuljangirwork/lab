#!/usr/bin/env bash
set -euo pipefail

### ========== CONFIGURATION ==========
CTID="${CTID:-104}"
CTNAME="${CTNAME:-pihole-dns}"
CT_IP="${CT_IP:-192.168.0.104/24}"
CT_GW="${CT_GW:-192.168.0.1}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-1024}"
DISK_GB="${DISK_GB:-8}"

COMPOSE_DIR="/opt/pihole"
### ===================================

# --- Helpers ---
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info() { echo -e "${C_BLUE}[INFO]${C_NC} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_NC} $1"; exit 1; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_NC} $1"; }

setup() {
    info "[1/5] Creating or reusing CT ${CTID}..."
    if pct status "$CTID" >/dev/null 2>&1;
    then
        warn "CT $CTID already exists. Skipping creation."
    else
        pct create "$CTID" "$TEMPLATE" --hostname "$CTNAME" --storage "$STORAGE" --rootfs "${STORAGE}:${DISK_GB}" \
          --cores "$CORES" --memory "$MEMORY" --swap 512 --onboot 1 --unprivileged 0 \
          --net0 name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW --features nesting=1 >/dev/null
        pct start "$CTID"; sleep 5
    fi

    info "[2/5] Installing Docker + Compose..."
    pct exec "$CTID" -- apt-get update >/dev/null
    pct exec "$CTID" -- apt-get install -y curl ca-certificates >/dev/null
    if ! pct exec "$CTID" -- docker --version >/dev/null 2>&1;
    then
        pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh" >/dev/null
        pct exec "$CTID" -- apt-get install -y docker-compose-plugin >/dev/null
    fi

    info "[3/5] Preparing Pi-hole Configuration..."
    local admin_pass confirm_pass
    while true; do
        read -sp "Enter a password for the Pi-hole web admin panel: " admin_pass; echo
        read -sp "Confirm password: " confirm_pass; echo
        [ "${admin_pass}" == "${confirm_pass}" ] && [ -n "${admin_pass}" ] && break
        warn "Passwords do not match or are empty. Please try again."
    done

    pct exec "$CTID" -- mkdir -p "${COMPOSE_DIR}"
    
    # Create docker-compose.yml inside the container
    cat <<EOF | pct push "$CTID" - "${COMPOSE_DIR}/docker-compose.yml"
version: "3"
services:
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8080:80/tcp"
    environment:
      TZ: 'Asia/Kolkata'
      WEBPASSWORD: '${admin_pass}'
    volumes:
      - './etc-pihole:/etc/pihole'
      - './etc-dnsmasq.d:/etc/dnsmasq.d'
    cap_add:
      - NET_ADMIN
    restart: unless-stopped
EOF

    info "[4/5] Deploying Pi-hole Container..."
    pct exec "$CTID" -- bash -c "cd $COMPOSE_DIR && docker compose up -d" >/dev/null

    info "[5/5] Finalizing setup..."
    sleep 10 # Give Pi-hole a moment to start
    status
}

status() {
    if ! pct status "$CTID" >/dev/null 2>&1; then warn "CT $CTID does not exist."; return; fi
    local ip_address; ip_address=$(echo "$CT_IP" | cut -d'/' -f1)
    success "=== Pi-hole DNS Server is Ready ==="
    echo "The Pi-hole container is running on LXC ${CTID}."
    echo
    echo "Web Admin URL: http://${ip_address}:8080/admin/"
    echo "Password:      (the password you set during setup)"
    echo
    echo "Your new local DNS server IP is: ${ip_address}"
}

main() {
    echo "Pi-hole LXC Management Script"
    echo "-----------------------------"
    read -p "Press 1 to Setup Pi-hole, or any other key to exit: " choice
    if [ "$choice" == "1" ]; then
        setup
    else
        echo "Exiting."
    fi
}

main
