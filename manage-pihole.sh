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
COMPOSE_VERSION="v2.27.0"
### ===================================

# --- Helpers ---
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info() { echo -e "\n${C_BLUE}[INFO]${C_NC} $1"; }
warn() { echo -e "\n${C_YELLOW}[WARN]${C_NC} $1"; }
error() { echo -e "\n${C_RED}[ERROR]${C_NC} $1"; exit 1; }
success() { echo -e "\n${C_GREEN}[SUCCESS]${C_NC} $1"; }

# --- Core Functions ---
setup() {
    info "[1/6] Creating or reusing CT ${CTID}..."
    if pct status "$CTID" >/dev/null 2>&1; then
        warn "CT $CTID already exists. Skipping creation."
    else
        pct create "$CTID" "$TEMPLATE" --hostname "$CTNAME" --storage "$STORAGE" --rootfs "${STORAGE}:${DISK_GB}" \
          --cores "$CORES" --memory "$MEMORY" --swap 512 --onboot 1 --unprivileged 0 \
          --net0 name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW \
          --nameserver 8.8.8.8 --features nesting=1 >/dev/null
        pct start "$CTID"; sleep 5
    fi

    info "[2/6] Applying AppArmor Security Profile for Docker..."
    local conf_file="/etc/pve/lxc/${CTID}.conf"
    local reboot_needed=false
    if ! grep -q "lxc.apparmor.profile: unconfined" "$conf_file"; then
        warn "Applying unconfined AppArmor profile..."
        echo "lxc.apparmor.profile: unconfined" >> "$conf_file"
        reboot_needed=true
    fi

    if [ "$reboot_needed" = true ]; then
        warn "Rebooting CT $CTID to apply new security profile..."
        pct reboot "$CTID"
        warn "Waiting for container to come back online..."
        sleep 15
    else
        info "AppArmor profile already set."
    fi
    pct start "$CTID" &>/dev/null || true

    info "[3/6] Installing Docker + Compose..."
    pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
    pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates"
    if ! pct exec "$CTID" -- docker --version >/dev/null 2>&1; then
        info "Installing Docker..."
        pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh" >/dev/null
    fi
    if ! pct exec "$CTID" -- docker compose version >/dev/null 2>&1; then
        info "Installing Docker Compose plugin..."
        pct exec "$CTID" -- bash -c "
            set -e
            mkdir -p /usr/local/lib/docker/cli-plugins
            curl -SL https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
            chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        " >/dev/null
    fi
    success "Docker runtime is ready."

    info "[4/6] Preparing Pi-hole Configuration..."
    local admin_pass confirm_pass
    while true; do
        read -sp "Enter a password for the Pi-hole web admin panel: " admin_pass; echo
        read -sp "Confirm password: " confirm_pass; echo
        [ "${admin_pass}" == "${confirm_pass}" ] && [ -n "${admin_pass}" ] && break
        warn "Passwords do not match or are empty. Please try again."
    done

    pct exec "$CTID" -- mkdir -p "${COMPOSE_DIR}"
    
    local TEMP_COMPOSE_FILE="/tmp/docker-compose-pihole.yml"
    cat > "${TEMP_COMPOSE_FILE}" <<EOF
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

    pct push "$CTID" "${TEMP_COMPOSE_FILE}" "${COMPOSE_DIR}/docker-compose.yml"
    rm "${TEMP_COMPOSE_FILE}"
    success "Pi-hole docker-compose.yml created in container."

    info "[5/6] Deploying Pi-hole Container..."
    pct exec "$CTID" -- bash -c "cd $COMPOSE_DIR && docker compose up -d"

    info "[6/6] Finalizing setup..."
    sleep 10
    status
}

destroy() {
    if ! pct status "$CTID" >/dev/null 2>&1; then warn "CT $CTID does not exist."; return; fi
    warn "This will permanently stop and destroy the LXC container ${CTID} and all its data."
    read -p "Are you sure? [y/N] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then info "Destroy cancelled."; return; fi
    
    info "Stopping and destroying LXC ${CTID}..."
    pct stop "${CTID}" &>/dev/null || true
    pct destroy "${CTID}"
    success "LXC ${CTID} has been destroyed."
}

status() {
    if ! pct status "$CTID" >/dev/null 2>&1; then warn "CT $CTID does not exist."; return; fi
    info "--- LXC ${CTID} (${CTNAME}) Status ---"
    pct status "${CTID}"
    
    info "--- Pi-hole Docker Container Status (inside LXC) ---"
    pct exec "$CTID" -- docker ps --filter "name=pihole"

    local ip_address; ip_address=$(echo "$CT_IP" | cut -d'/' -f1)
    echo
    success "=== Pi-hole DNS Server is Ready ==="
    echo "Web Admin URL: http://${ip_address}:8080/admin/"
    echo "Password:      (the password you set during setup)"
    echo
    echo "Your new local DNS server IP is: ${ip_address}"
}

show_menu() {
    clear
    echo "==================================================="
    echo "      Pi-hole DNS Server - LXC Management"
    echo "==================================================="
    echo "  Manages LXC ${CTID} (${CTNAME})"
    echo "==================================================="
    echo " 1. Setup / Re-deploy Server"
    echo -e " 2. ${C_RED}Destroy Server LXC${C_NC}"
    echo " -------------------------------------------------"
    echo " 3. Start LXC"
    echo " 4. Stop LXC"
    echo " 5. Show Status and URL"
    echo " 6. Enter LXC Shell"
    echo " -------------------------------------------------"
    echo -e " 0. ${C_YELLOW}Quit${C_NC}"
    echo "==================================================="
}

main() {
    while true; do
        show_menu
        read -p "Enter your choice [0-6]: " choice
        case "${choice}" in
            1) setup ;;
            2) destroy ;;
            3) info "Starting LXC ${CTID}..."; pct start "${CTID}" ;;
            4) info "Stopping LXC ${CTID}..."; pct stop "${CTID}" ;;
            5) status ;;
            6) pct enter "${CTID}" ;;
            0) break ;;
            *) error "Invalid option." ;;
        esac
        echo; read -p "Press Enter to return to the menu..."
    done
    info "Exiting."
}

main
