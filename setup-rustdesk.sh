#!/bin/bash
set -e

#================================================================================
#         RustDesk + Tailscale Private Server Installation Script
#================================================================================
# This script automates the setup of a self-hosted RustDesk server that is
# only accessible over a private Tailscale network.
#
# It installs Docker, Tailscale, and runs the RustDesk server in a container.
# No router or firewall configuration is required.
#================================================================================

# --- Configuration ---
CONTAINER_NAME='rustdesk-server'
# We use a popular community-maintained, all-in-one RustDesk server image.
DOCKER_IMAGE='rustdesk/rustdesk-server:latest'
DATA_DIR='/var/lib/rustdesk-data'

# --- Helper Functions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "\n${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "\n${YELLOW}[WARNING] $1${NC}"; }

# --- Main Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root or with sudo."
        exit 1
    fi
}

install_dependencies() {
    print_status "Updating package list and installing prerequisites..."
    apt-get update
    apt-get install -y curl ca-certificates

    # Install Docker if not present
    if ! command -v docker &> /dev/null; then
        print_status "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        print_status "Docker installed successfully."
    else
        print_status "Docker is already installed."
    fi

    # Install Tailscale if not present
    if ! command -v tailscale &> /dev/null; then
        print_status "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        print_status "Tailscale installed successfully."
    else
        print_status "Tailscale is already installed."
    fi
}

configure_tailscale() {
    print_status "Configuring Tailscale..."
    
    # Check if already logged in
    if tailscale status | grep -q "Logged in"; then
        print_status "Already logged into Tailscale."
    else
        echo -e "${YELLOW}"
        echo "---------------------------------------------------------------------"
        echo "You need to log in to Tailscale."
        echo "A URL will be printed below. Please copy it and open it in a browser"
        echo "on any device to authenticate and add this server to your network."
        echo "---------------------------------------------------------------------"
        echo -e "${NC}"
        read -p "Press Enter to continue..."
        tailscale up
    fi

    # Get the Tailscale IP
    TAILSCALE_IP=$(tailscale ip -4)
    if [ -z "$TAILSCALE_IP" ]; then
        print_error "Could not get Tailscale IP. Please ensure you are logged in and the client is running."
        exit 1
    fi
    print_status "This server's private Tailscale IP is: $TAILSCALE_IP"
}

run_rustdesk_container() {
    local tailscale_ip=$1
    print_status "Setting up RustDesk container..."

    # Create data directory
    mkdir -p $DATA_DIR
    
    # Stop and remove any existing container
    if [ "$(docker ps -a -q -f name=$CONTAINER_NAME)" ]; then
        print_status "Removing existing RustDesk container..."
        docker stop $CONTAINER_NAME >/dev/null
        docker rm $CONTAINER_NAME >/dev/null
    fi

    print_status "Starting RustDesk container..."
    # We use --network=host so the container directly uses the LXC's network,
    # including the Tailscale interface. This is the simplest and most reliable method.
    docker run -d --name $CONTAINER_NAME \
        --network=host \
        -v $DATA_DIR:/data \
        -e RELAY="$tailscale_ip:21117" \
        --restart unless-stopped \
        $DOCKER_IMAGE hbbs -r "$tailscale_ip:21117" && \
    docker run -d --name ${CONTAINER_NAME}-hbbr \
        --network=host \
        -v $DATA_DIR:/data \
        --restart unless-stopped \
        $DOCKER_IMAGE hbbr

    if [ $? -eq 0 ]; then
        print_status "RustDesk containers started successfully."
    else
        print_error "Failed to start RustDesk containers."
        exit 1
    fi
}

display_final_info() {
    local tailscale_ip=$1
    print_status "Waiting for services to initialize..."
    sleep 10

    local public_key=$(cat $DATA_DIR/id_ed25519.pub 2>/dev/null || echo "Not found yet. Check again in a minute.")

    echo ""
    echo "============================================================="
    echo -e "${GREEN}  RustDesk on Tailscale - Setup Complete!${NC}"
    echo "============================================================="
    echo ""
    echo -e "${YELLOW}Your private RustDesk server is running and accessible ONLY"
    echo -e "over your private Tailscale network.${NC}"
    echo ""
    echo -e "${YELLOW}🔧 Configure Your RustDesk Clients (PC, Mac, Android, etc):${NC}"
    echo "   1. Open RustDesk and go to 'ID/Relay Server' settings."
    echo "   2. Enter the following information:"
    echo ""
    echo "      ID Server:    $tailscale_ip"
    echo "      Relay Server: $tailscale_ip"
    echo "      Public Key:   $public_key"
    echo ""
    echo -e "${YELLOW}💡 How it works:${NC}"
    echo "   - Install Tailscale on any device you want to use for remote access."
    echo "   - As long as that device is logged into Tailscale, it will be"
    echo "     able to connect to your private RustDesk server."
    echo ""
    echo -e "${GREEN}✅ Your setup is complete and secure.${NC}"
    echo ""
}

# --- Main Execution ---
main() {
    check_root
    install_dependencies
    configure_tailscale
    # Pass the Tailscale IP to the run and display functions
    run_rustdesk_container "$TAILSCALE_IP"
    display_final_info "$TAILSCALE_IP"
}

# Run the main function
main
