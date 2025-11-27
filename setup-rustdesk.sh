#!/bin/bash
set -e

#================================================================================
#   RustDesk API Server + Tailscale Private Deployment Management Script
#================================================================================
# This script automates the setup of a self-hosted RustDesk API server that
# is only accessible over a private Tailscale network.
#
# It is designed to be run inside the LXC container where the server will live.
#================================================================================

### ========== CONFIGURATION ==========
# The name for the main RustDesk Docker container.
CONTAINER_NAME='rustdesk-server'

# The Docker image to use. 'lejianwen/rustdesk-api:full-s6' provides an all-in-one
# server with a web UI.
DOCKER_IMAGE='lejianwen/rustdesk-api:full-s6'

# The directory on the LXC host where RustDesk will store its data and keys.
DATA_DIR='/var/lib/rustdesk-data'

# Set the password for the RustDesk web admin panel here.
# If you leave this blank (e.g., RUSTDESK_ADMIN_PASSWORD=""), the script will
# prompt you to enter a password when it runs.
RUSTDESK_ADMIN_PASSWORD=""
### ===================================

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
    print_status "Starting RustDesk API Server + Tailscale Setup..."
    
    # Step 1: Install Dependencies
    print_status "[1/5] Installing Dependencies..."
    apt-get update >/dev/null
    apt-get install -y curl ca-certificates >/dev/null
    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh >/dev/null; fi
    if ! command -v tailscale &> /dev/null; then curl -fsSL https://tailscale.com/install.sh | sh >/dev/null; fi
    success "Dependencies are installed."

    # Step 2: Configure Tailscale
    print_status "[2/5] Configuring Tailscale..."
    if ! tailscale status | grep -q "Logged in"; then
        print_warning "You need to log in to Tailscale to continue."
        tailscale up
    fi
    local TAILSCALE_IP=$(tailscale ip -4)
    [ -z "$TAILSCALE_IP" ] && print_error "Could not get Tailscale IP." && exit 1
    success "This server's private Tailscale IP is: $TAILSCALE_IP"

    # Step 3: Get User Input
    print_status "[3/5] Preparing Configuration..."
    local admin_pass="$RUSTDESK_ADMIN_PASSWORD"
    if [ -z "$admin_pass" ]; then
        print_warning "No admin password was set in the script's CONFIG block."
        local confirm_pass
        while true; do
            read -sp "Enter a password for the RustDesk web admin panel: " admin_pass; echo
            read -sp "Confirm password: " confirm_pass; echo
            [ "$admin_pass" == "$confirm_pass" ] && [ -n "$admin_pass" ] && break
            print_warning "Passwords do not match or are empty. Please try again."
        done
    else
        print_status "Using admin password from the script's configuration block."
    fi
    success "Password has been set."

    # Step 4: Run RustDesk Container
    print_status "[4/5] Deploying RustDesk API Server Container..."
    mkdir -p "$DATA_DIR/server" "$DATA_DIR/api"
    
    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        print_warning "Removing existing RustDesk container..."
        docker stop $CONTAINER_NAME &>/dev/null || true
        docker rm $CONTAINER_NAME &>/dev/null || true
    fi

    print_status "Pulling Docker image: $DOCKER_IMAGE..."
    docker pull $DOCKER_IMAGE >/dev/null

    print_status "Starting RustDesk container..."
    docker run -d --name $CONTAINER_NAME \
        --network=host \
        -v "$DATA_DIR/server:/data" \
        -v "$DATA_DIR/api:/app/data" \
        -e "RUSTDESK_API_RUSTDESK_ID_SERVER=$TAILSCALE_IP:21116" \
        -e "RUSTDESK_API_RUSTDESK_RELAY_SERVER=$TAILSCALE_IP:21117" \
        -e "RUSTDESK_API_RUSTDESK_API_SERVER=http://$TAILSCALE_IP:21114" \
        -e "RUSTDESK_API_RUSTDESK_ADMIN_PASSWD=$admin_pass" \
        --restart unless-stopped \
        $DOCKER_IMAGE >/dev/null
    success "RustDesk container started."

    # Step 5: Display Information
    print_status "[5/5] Finalizing Setup..."
    status
}

destroy() {
    print_warning "This will permanently stop and remove the RustDesk container and delete all configuration data from $DATA_DIR."
    read -p "Are you sure? [y/N] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then print_status "Destroy cancelled."; return; fi
    
    print_status "Stopping container..."
    docker stop $CONTAINER_NAME &>/dev/null || true
    print_status "Removing container..."
    docker rm $CONTAINER_NAME &>/dev/null || true
    print_status "Deleting data directory: $DATA_DIR..."
    rm -rf $DATA_DIR
    success "RustDesk server has been destroyed."
}

status() {
    print_status "--- RustDesk Server Status ---"
    if ! command -v docker &>/dev/null || ! docker ps -a --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
        print_warning "RustDesk server is not installed. Please run Setup."
        return
    fi

    docker ps --filter "name=$CONTAINER_NAME"

    local tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "Not Available")
    
    print_status "Waiting for public key to be generated (up to 30s)..."
    local counter=0
    while [ ! -f "$DATA_DIR/server/id_ed25519.pub" ]; do
        if [ $counter -ge 30 ]; then break; fi
        sleep 1; counter=$((counter+1))
    done
    local public_key=$(cat $DATA_DIR/server/id_ed25519.pub 2>/dev/null || echo "Not found. Check logs with option 6.")

    echo ""
    echo "============================================================="
    echo -e "${GREEN}      RustDesk on Tailscale - Configuration Details${NC}"
    echo "============================================================="
    echo -e "\n${YELLOW}🌐 Web Admin Panel:${NC}"
    echo "   URL:      http://$tailscale_ip:21114/_admin/"
    echo "   Username: admin"
    echo "   Password: (the password you set in the script or when prompted)"
    echo ""
    echo -e "${YELLOW}🔧 Configure Your RustDesk Clients with this information:${NC}"
    echo "   ID Server:    $tailscale_ip"
    echo "   Relay Server: $tailscale_ip"
    echo "   API Server:   http://$tailscale_ip:21114"
    echo "   Public Key:   $public_key"
    echo ""
}

show_menu() {
    clear
    echo "==================================================="
    echo "  RustDesk API Server + Tailscale Management"
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
            3) print_status "Starting container..."; docker start $CONTAINER_NAME ;; 
            4) print_status "Stopping container..."; docker stop $CONTAINER_NAME ;; 
            5) status ;; 
            6) print_status "Following logs. Press Ctrl+C to stop."; docker logs -f $CONTAINER_NAME ;; 
            0) break ;; 
            *) print_error "Invalid option." ;; 
        esac
        echo; read -p "Press Enter to return to the menu..."
    done
    print_status "Exiting."
}

main