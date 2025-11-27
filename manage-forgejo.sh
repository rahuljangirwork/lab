#!/bin/bash
set -e

#================================================================================
#   All-in-One Forgejo (Docker) LXC Management Script for Proxmox
#================================================================================
# This script, run on the Proxmox host, manages the entire lifecycle of a
# self-hosted Forgejo Git service running via Docker in an LXC container.
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

# --- Forgejo Docker Settings ---
FORGEJO_VERSION="7.0.5" # You can update this to the latest version
DOCKER_IMAGE="codeberg.org/forgejo/forgejo:${FORGEJO_VERSION}"
DATA_DIR="/var/lib/forgejo-data" # Data directory inside the LXC
CONTAINER_NAME="forgejo"
### ===============================================

# --- Helper Functions ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "\n${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "\n${YELLOW}[WARNING] $1${NC}"; }
success() { echo -e "\n${GREEN}[SUCCESS] $1${NC}"; }

# --- Core Functions ---

setup() {
    print_status "Starting Full Setup for Forgejo (Docker) LXC ${CTID}..."

    # Step 1: Create LXC
    print_status "[1/4] Creating LXC ${CTID}..."
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

    # Step 2: Install Dependencies (Docker)
    print_status "[2/4] Installing Dependencies in LXC..."
    pct exec "${CTID}" -- apt-get update >/dev/null
    pct exec "${CTID}" -- apt-get install -y curl ca-certificates >/dev/null
    if ! pct exec "${CTID}" -- command -v docker &>/dev/null; then
        print_warning "Installing Docker..."
        pct exec "${CTID}" -- bash -c "curl -fsSL https://get.docker.com | sh" >/dev/null
    fi
    success "Dependencies installed."

    # Step 3: Deploy Docker Container
    print_status "[3/4] Deploying Forgejo Docker Container..."
    pct exec "${CTID}" -- mkdir -p "${DATA_DIR}"
    
    if pct exec "${CTID}" -- docker ps -a -q -f name=${CONTAINER_NAME} | grep -q .; then
        print_warning "Removing existing Forgejo container..."
        pct exec "${CTID}" -- docker stop ${CONTAINER_NAME} &>/dev/null || true
        pct exec "${CTID}" -- docker rm ${CONTAINER_NAME} &>/dev/null || true
    fi
    
    print_status "Pulling latest Forgejo image: ${DOCKER_IMAGE}"
    pct exec "${CTID}" -- docker pull ${DOCKER_IMAGE} >/dev/null
    
    pct exec "${CTID}" -- docker run -d --name ${CONTAINER_NAME} \
        -p 3000:3000 \
        -p 2222:22 \
        -v "${DATA_DIR}:/data" \
        --restart unless-stopped \
        ${DOCKER_IMAGE} >/dev/null
    success "Forgejo container started."

    # Step 4: Final Status
    print_status "[4/4] Finalizing Setup..."
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
    
    print_status "--- Forgejo Docker Container Status (inside LXC) ---"
    pct exec "${CTID}" -- docker ps --filter "name=${CONTAINER_NAME}"

    local ip_address=$(echo "${CT_IP}" | cut -d'/' -f1)
    echo ""
    echo "============================================================="
    echo -e "${GREEN}      Forgejo Setup Complete${NC}"
    echo "============================================================="
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo "   1. Open your browser and go to: http://${ip_address}:3000"
    echo "   2. Complete the web-based installation wizard."
    echo "      - Database Type: Select 'SQLite3'."
    echo "      - Server Domain: Use '${ip_address}'."
    echo "      - SSH Server Port: Use '2222'."
    echo "      - Base URL: Use 'http://${ip_address}:3000/'."
    echo "      - Configure your admin account."
    echo ""
    echo -e "${YELLOW}Git SSH URL for your repos will look like:${NC}"
    echo "   ssh://git@${ip_address}:2222/YourUser/YourRepo.git"
    echo ""
}

show_menu() {
    clear
    echo "==================================================="
    echo "   Forgejo (Docker) on Proxmox - LXC Management"
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
            6) print_status "Following logs for ${CONTAINER_NAME}. Press Ctrl+C to stop."; pct exec "${CTID}" -- docker logs -f ${CONTAINER_NAME} ;; 
            7) pct enter "${CTID}" ;;
            0) break ;;
            *) print_error "Invalid option." ;;
        esac
        echo; read -p "Press Enter to return to the menu..."
    done
    print_status "Exiting."
}

main