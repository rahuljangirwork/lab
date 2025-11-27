#!/bin/bash
set -e

#================================================================================
#         RustDesk + Tailscale Private Server Management Script
#================================================================================
# This script automates the setup, destruction, and management of a self-hosted
# RustDesk server that is only accessible over a private Tailscale network.
#================================================================================

# --- Configuration ---
CONTAINER_NAME_HBBS='rustdesk-server-hbbs'
CONTAINER_NAME_HBBR='rustdesk-server-hbbr'
DOCKER_IMAGE='rustdesk/rustdesk-server:latest'
DATA_DIR='/var/lib/rustdesk-data'

# --- Helper Functions ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "\n${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "\n${YELLOW}[WARNING] $1${NC}"; }
success() { echo -e "\n${GREEN}[SUCCESS] $1${NC}"; }

# --- Core Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo."
        exit 1
    fi
}

setup() {
    print_status "Starting RustDesk + Tailscale Setup..."
    
    # Step 1: Install Dependencies
    print_status "[1/4] Installing Dependencies..."
    apt-get update >/dev/null
    apt-get install -y curl ca-certificates >/dev/null
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh >/dev/null
    fi
    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
    fi
    success "Dependencies are installed."

    # Step 2: Configure Tailscale
    print_status "[2/4] Configuring Tailscale..."
    if ! tailscale status | grep -q "Logged in"; then
        print_warning "You need to log in to Tailscale to continue."
        tailscale up
    fi
    local TAILSCALE_IP=$(tailscale ip -4)
    [ -z "$TAILSCALE_IP" ] && print_error "Could not get Tailscale IP." && exit 1
    success "This server's private Tailscale IP is: $TAILSCALE_IP"

    # Step 3: Run RustDesk Containers
    print_status "[3/4] Deploying RustDesk Server Containers..."
    mkdir -p $DATA_DIR
    
    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME_HBBS)" ]; then
        print_warning "Removing existing RustDesk containers..."
        docker stop $CONTAINER_NAME_HBBS $CONTAINER_NAME_HBBR &>/dev/null || true
        docker rm $CONTAINER_NAME_HBBS $CONTAINER_NAME_HBBR &>/dev/null || true
    fi

    print_status "Starting hbbs (ID/Rendezvous Server)..."
    docker run -d --name $CONTAINER_NAME_HBBS \
        --network=host -v $DATA_DIR:/data \
        -e RELAY="$TAILSCALE_IP:21117" \
        --restart unless-stopped \
        $DOCKER_IMAGE hbbs -r "$TAILSCALE_IP:21117" >/dev/null

    print_status "Starting hbbr (Relay Server)..."
    docker run -d --name $CONTAINER_NAME_HBBR \
        --network=host -v $DATA_DIR:/data \
        --restart unless-stopped \
        $DOCKER_IMAGE hbbr >/dev/null
    success "RustDesk containers started."

    # Step 4: Display Information
    print_status "[4/4] Finalizing Setup..."
    status
}

destroy() {
    print_warning "This will permanently stop and remove the RustDesk containers and delete all configuration data from $DATA_DIR."
    read -p "Are you sure? [y/N] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then print_status "Destroy cancelled."; return; fi
    
    print_status "Stopping containers..."
    docker stop $CONTAINER_NAME_HBBS $CONTAINER_NAME_HBBR &>/dev/null || true
    print_status "Removing containers..."
    docker rm $CONTAINER_NAME_HBBS $CONTAINER_NAME_HBBR &>/dev/null || true
    print_status "Deleting data directory: $DATA_DIR..."
    rm -rf $DATA_DIR
    success "RustDesk server has been destroyed."
}

status() {
    print_status "--- RustDesk Server Status ---"
    if ! command -v docker &>/dev/null || ! docker ps -a --format '{{.Names}}' | grep -q "$CONTAINER_NAME_HBBS"; then
        print_warning "RustDesk server is not installed. Please run Setup."
        return
    fi

    docker ps --filter "name=rustdesk-server"

    local tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "Not Available")
    
    print_status "Waiting for public key to be generated (up to 30s)..."
    local counter=0
    while [ ! -f "$DATA_DIR/id_ed25519.pub" ]; do
        if [ $counter -ge 30 ]; then break; fi
        sleep 1; counter=$((counter+1))
    done
    local public_key=$(cat $DATA_DIR/id_ed25519.pub 2>/dev/null || echo "Not found. Please check logs or wait longer.")

    echo ""
    echo "============================================================="
    echo -e "${GREEN}      RustDesk on Tailscale - Configuration Details${NC}"
    echo "============================================================="
    echo -e "\n${YELLOW}🔧 Configure Your RustDesk Clients with this information:${NC}"
    echo "   ID Server:    $tailscale_ip"
    echo "   Relay Server: $tailscale_ip"
    echo "   Public Key:   $public_key"
    echo ""
}

show_menu() {
    clear
    echo "==================================================="
    echo "  RustDesk + Tailscale Server Management"
    echo "==================================================="
    echo " 1. Setup / Re-deploy Server"
    echo -e " 2. ${RED}Destroy Server and Data${NC}"
    echo " -------------------------------------------------"
    echo " 3. Start Server"
    echo " 4. Stop Server"
    echo " 5. Show Status and Credentials"
    echo " 6. View Server Logs"
    echo " -------------------------------------------------"
    echo -e " 0. ${YELLOW}Quit${NC}"
    echo "==================================================="
}

main() {
    check_root
    while true; do
        show_menu
        read -p "Enter your choice [0-6]: " choice
        case "$choice" in
            1) setup ;;
            2) destroy ;;
            3) print_status "Starting containers..."; docker start $CONTAINER_NAME_HBBS $CONTAINER_NAME_HBBR ;;
            4) print_status "Stopping containers..."; docker stop $CONTAINER_NAME_HBBS $CONTAINER_NAME_HBBR ;;
            5) status ;;
            6) print_status "Following logs for hbbs (ID Server). Press Ctrl+C to stop."; docker logs -f $CONTAINER_NAME_HBBS ;;
            0) break ;;
            *) print_error "Invalid option." ;;
        esac
        echo; read -p "Press Enter to return to the menu..."
    done
    print_status "Exiting."
}

main
