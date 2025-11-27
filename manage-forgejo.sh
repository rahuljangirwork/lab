#!/bin/bash
set -e

#================================================================================
#   All-in-One Forgejo LXC Management Script for Proxmox
#================================================================================
# This script, run on the Proxmox host, manages the entire lifecycle of a
# self-hosted Forgejo Git service running in an LXC container.
#================================================================================

### ========== CONFIGURATION ========== 
# --- LXC Settings ---
# IMPORTANT: Change these to match your environment
CTID="103"
CTNAME="forgejo-server"
CT_IP="192.168.0.103/24" # Set a static IP for your container
CT_GW="192.168.0.1"      # Set your network gateway
STORAGE="local-lvm"      # Storage pool for the new container
BRIDGE="vmbr0"           # Your Proxmox bridge
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst" # Make sure this template exists

# --- Resource Allocation (as per your request) ---
CORES="2"
MEMORY="2048" # 2GB RAM
DISK="20"     # 20GB disk space

# --- Forgejo Settings ---
FORGEJO_USER="forgejo"
FORGEJO_HOME="/var/lib/forgejo"
FORGEJO_CONFIG_DIR="/etc/forgejo"
FORGEJO_BINARY_URL="https://codeberg.org/forgejo/forgejo/releases/latest/download/forgejo-linux-amd64"
### ===============================================

# --- Helper Functions ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "\n${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "\n${YELLOW}[WARNING] $1${NC}"; }
success() { echo -e "\n${GREEN}[SUCCESS] $1${NC}"; }

# --- Core Functions ---

setup() {
    print_status "Starting Full Setup for Forgejo LXC ${CTID}..."

    # Step 1: Create LXC
    print_status "[1/5] Creating LXC ${CTID}..."
    if pct status "${CTID}" &>/dev/null; then
        print_warning "CT ${CTID} already exists. Skipping creation."
    else
        pct create "${CTID}" "${TEMPLATE}" --hostname "${CTNAME}" --storage "${STORAGE}" --rootfs "${STORAGE}:${DISK}" \
          --cores "${CORES}" --memory "${MEMORY}" --swap 512 --onboot 1 --unprivileged 0 \
          --net0 name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${CT_GW} \
          --features nesting=1,keyctl=1 >/dev/null
        pct start "${CTID}"
        print_warning "Waiting for LXC to boot..." && sleep 10
    fi

    # Step 2: Install Forgejo
    print_status "[2/5] Installing Forgejo inside the container..."
    pct exec "${CTID}" -- apt-get update >/dev/null
    pct exec "${CTID}" -- apt-get install -y wget git >/dev/null
    
    print_status "Downloading Forgejo binary..."
    pct exec "${CTID}" -- wget -O /usr/local/bin/forgejo "${FORGEJO_BINARY_URL}"
    pct exec "${CTID}" -- chmod +x /usr/local/bin/forgejo
    success "Forgejo binary installed."

    # Step 3: Create User and Directories
    print_status "[3/5] Setting up user and directories..."
    if ! pct exec "${CTID}" -- id -u ${FORGEJO_USER} &>/dev/null; then
        pct exec "${CTID}" -- adduser --system --group --disabled-password --home ${FORGEJO_HOME} ${FORGEJO_USER}
    else
        print_warning "User '${FORGEJO_USER}' already exists."
    fi
    pct exec "${CTID}" -- mkdir -p "${FORGEJO_HOME}" "${FORGEJO_CONFIG_DIR}"
    pct exec "${CTID}" -- chown -R "${FORGEJO_USER}:${FORGEJO_USER}" "${FORGEJO_HOME}" "${FORGEJO_CONFIG_DIR}"
    success "Forgejo user and directories configured."

    # Step 4: Create systemd Service
    print_status "[4/5] Creating systemd service..."
    cat <<EOF | pct exec "${CTID}" -- tee /etc/systemd/system/forgejo.service >/dev/null
[Unit]
Description=Forgejo
After=syslog.target
After=network.target

[Service]
Restart=always
Type=simple
User=${FORGEJO_USER}
Group=${FORGEJO_USER}
WorkingDirectory=${FORGEJO_HOME}
ExecStart=/usr/local/bin/forgejo web --config ${FORGEJO_CONFIG_DIR}/app.ini
Environment=USER=${FORGEJO_USER} HOME=${FORGEJO_HOME}
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    pct exec "${CTID}" -- systemctl daemon-reload
    pct exec "${CTID}" -- systemctl enable --now forgejo
    success "Forgejo service created and started."

    # Step 5: Final Status
    print_status "[5/5] Finalizing Setup..."
    sleep 5 # Give Forgejo a moment to start
    status
}

destroy() {
    if ! pct status "${CTID}" &>/dev/null; then print_warning "CT ${CTID} does not exist."; return; fi
    print_warning "This will permanently stop and destroy the LXC container ${CTID} and all its data."
    read -p "Are you sure? [y/N] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then print_status "Destroy cancelled."; return; fi
    
    print_status "Stopping and destroying LXC ${CTID}..."
    pct stop "${CTID}" &>/dev/null || true
    pct destroy "${CTID}"
    success "LXC ${CTID} has been destroyed."
}

status() {
    if ! pct status "${CTID}" &>/dev/null; then print_warning "CT ${CTID} does not exist."; return; fi
    print_status "--- LXC ${CTID} Status ---"
    pct status "${CTID}"
    
    print_status "--- Forgejo Service Status (inside LXC) ---"
    pct exec "${CTID}" -- systemctl status forgejo --no-pager || print_warning "Could not get Forgejo status."

    local ip_address=$(echo "${CT_IP}" | cut -d'/' -f1)
    echo ""
    echo "============================================================="
    echo -e "${GREEN}      Forgejo Setup Complete${NC}"
    echo "============================================================="
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo "   1. Open your browser and go to: http://${ip_address}:3000"
    echo "   2. Complete the web-based installation wizard."
    echo "      - Database Type: Select 'SQLite3'."
    echo "      - Configure your admin account and other settings."
    echo ""
}

show_menu() {
    clear
    echo "==================================================="
    echo "        Forgejo on Proxmox - LXC Management"
    echo "==================================================="
    echo "  Manages LXC ${CTID} (${CTNAME})"
    echo "==================================================="
    echo " 1. Setup / Re-deploy Server"
    echo -e " 2. ${RED}Destroy Server LXC${NC}"
    echo " -------------------------------------------------"
    echo " 3. Start LXC"
    echo " 4. Stop LXC"
    echo " 5. Show Status and URL"
    echo " 6. View Server Logs (inside LXC)"
    echo " 7. Enter LXC Shell"
    echo " -------------------------------------------------"
    echo -e " 0. ${YELLOW}Quit${NC}"
    echo "==================================================="
}

main() {
    while true; do
        show_menu
        read -p "Enter your choice [0-7]: " choice
        case "${choice}" in
            1) setup ;;
            2) destroy ;;
            3) print_status "Starting LXC ${CTID}..."; pct start "${CTID}" ;;
            4) print_status "Stopping LXC ${CTID}..."; pct stop "${CTID}" ;;
            5) status ;;
            6) print_status "Following logs for Forgejo. Press Ctrl+C to stop."; pct exec "${CTID}" -- journalctl -u forgejo -f ;; 
            7) pct enter "${CTID}" ;;
            0) break ;;
            *) print_error "Invalid option." ;;
        esac
        echo; read -p "Press Enter to return to the menu..."
    done
    print_status "Exiting."
}

main
