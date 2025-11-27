#!/bin/bash
set -e

#================================================================================
#   All-in-One RustDesk + Tailscale LXC Management Script for Proxmox
#================================================================================
# This script, run on the Proxmox host, manages the entire lifecycle of a
# private RustDesk server running in an LXC container over Tailscale.
#================================================================================

### ========== CONFIGURATION for LXC 102 ==========
# --- LXC Settings ---
CTID="102"
CTNAME="rustdesk-server"
CT_IP="192.168.0.102/24"
CT_GW="192.168.0.1"
STORAGE="local-lvm"
BRIDGE="vmbr0"
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
CORES="1"
MEMORY="1024" # Recommended 1GB RAM for this container image
DISK="8"      # 8GB disk space

# --- RustDesk Settings ---
DOCKER_IMAGE='lejianwen/rustdesk-api:full-s6'
DATA_DIR='/var/lib/rustdesk-data'
### ===============================================

# --- Helper Functions ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "\n${GREEN}[INFO] $1${NC}"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}"; }
print_warning() { echo -e "\n${YELLOW}[WARNING] $1${NC}"; }
success() { echo -e "\n${GREEN}[SUCCESS] $1${NC}"; }

# --- Core Functions ---

setup() {
    print_status "Starting Full Setup for RustDesk LXC ${CTID}..."

    # Step 1: Create LXC
    print_status "[1/6] Creating LXC ${CTID}..."
    if pct status "$CTID" &>/dev/null; then
        print_warning "CT ${CTID} already exists. Skipping creation."
    else
        pct create "$CTID" "$TEMPLATE" --hostname "$CTNAME" --storage "$STORAGE" --rootfs "$STORAGE:${DISK}" \
          --cores "$CORES" --memory "$MEMORY" --swap 512 --onboot 1 --unprivileged 0 \
          --net0 name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW --features nesting=1 >/dev/null
        pct start "$CTID"
        print_warning "Waiting for LXC to boot..." && sleep 5
    fi

    # Step 2: Apply LXC Configuration
    print_status "[2/6] Applying LXC Configuration..."
    local CONF_FILE="/etc/pve/lxc/${CTID}.conf"
    local REBOOT_NEEDED=false
    if ! grep -q "lxc.apparmor.profile: unconfined" "$CONF_FILE"; then
        print_warning "Applying unconfined AppArmor profile..."; echo "lxc.apparmor.profile: unconfined" >> "$CONF_FILE"; REBOOT_NEEDED=true
    fi
    if ! grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$CONF_FILE"; then
        print_warning "Enabling TUN device access..."; echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$CONF_FILE"; echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$CONF_FILE"; REBOOT_NEEDED=true
    fi

    if [ "$REBOOT_NEEDED" = true ]; then
        print_warning "Rebooting LXC to apply new configuration..."; pct reboot "$CTID" >/dev/null; print_warning "Waiting for container to reboot (up to 30s)..." && sleep 15
    else
        print_status "LXC configuration already set."
    fi
    pct start "$CTID" &>/dev/null || true

    # Step 3: Install Dependencies
    print_status "[3/6] Installing Dependencies in LXC..."
    pct exec "$CTID" -- apt-get update >/dev/null
    pct exec "$CTID" -- apt-get install -y curl ca-certificates >/dev/null
    if ! pct exec "$CTID" -- command -v docker &>/dev/null; then pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh" >/dev/null; fi
    if ! pct exec "$CTID" -- command -v tailscale &>/dev/null; then pct exec "$CTID" -- bash -c "curl -fsSL https://tailscale.com/install.sh | sh" >/dev/null; fi
    print_status "Ensuring Tailscale service is running..."; pct exec "$CTID" -- systemctl enable --now tailscaled
    success "Dependencies installed and services started."

    # Step 4: Configure Tailscale
    print_status "[4/6] Configuring Tailscale in LXC..."
    if ! pct exec "$CTID" -- tailscale status | grep -q "Logged in"; then
        print_warning "You need to log in to Tailscale to continue."; echo "The script will now run 'tailscale up'. A URL will be printed."; echo "Copy the URL and open it in a browser on any device to authenticate."
        read -p "Press Enter to continue..."
        pct exec "$CTID" -- tailscale up
    fi
    local TAILSCALE_IP=$(pct exec "$CTID" -- tailscale ip -4)
    [ -z "$TAILSCALE_IP" ] && print_error "Could not get Tailscale IP." && exit 1
    success "LXC is on Tailscale with IP: $TAILSCALE_IP"

    # Step 5: Deploy Docker Container
    print_status "[5/6] Deploying RustDesk Container in LXC..."
    pct exec "$CTID" -- mkdir -p "$DATA_DIR/server" "$DATA_DIR/api"
    local CONTAINER_NAME='rustdesk-server'
    if pct exec "$CTID" -- docker ps -a -q -f name=$CONTAINER_NAME | grep -q .; then
        print_warning "Removing existing RustDesk container..."; pct exec "$CTID" -- docker stop $CONTAINER_NAME &>/dev/null || true; pct exec "$CTID" -- docker rm $CONTAINER_NAME &>/dev/null || true
    fi
    print_status "Pulling Docker image: $DOCKER_IMAGE..."; pct exec "$CTID" -- docker pull $DOCKER_IMAGE >/dev/null
    
    print_status "Starting RustDesk container..."
    pct exec "$CTID" -- docker run -d --name $CONTAINER_NAME \
        --network=host \
        -v "$DATA_DIR/server:/data" \
        -v "$DATA_DIR/api:/app/data" \
        -e "RUSTDESK_API_RUSTDESK_ID_SERVER=$TAILSCALE_IP:21116" \
        -e "RUSTDESK_API_RUSTDESK_RELAY_SERVER=$TAILSCALE_IP:21117" \
        -e "RUSTDESK_API_RUSTDESK_API_SERVER=http://$TAILSCALE_IP:21114" \
        --restart unless-stopped \
        $DOCKER_IMAGE >/dev/null
    success "RustDesk container started."

    # Step 6: Final Status
    print_status "[6/6] Finalizing Setup..."
    status
}

destroy() {
    if ! pct status "$CTID" &>/dev/null; then print_warning "CT ${CTID} does not exist."; return; fi
    print_warning "This will permanently stop and destroy the LXC container ${CTID} and all its data."
    read -p "Are you sure? [y/N] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then print_status "Destroy cancelled."; return; fi
    
    print_status "Stopping and destroying LXC ${CTID}..."; pct stop "$CTID" &>/dev/null || true; pct destroy "$CTID"
    success "LXC ${CTID} has been destroyed."
}

status() {
    if ! pct status "$CTID" &>/dev/null; then print_warning "CT ${CTID} does not exist."; return; fi
    print_status "--- LXC ${CTID} Status ---"; pct status "$CTID"
    
    local CONTAINER_NAME='rustdesk-server'
    print_status "--- Docker Container Status (inside LXC) ---"
    pct exec "$CTID" -- docker ps --filter "name=$CONTAINER_NAME"

    local tailscale_ip=$(pct exec "$CTID" -- tailscale ip -4 2>/dev/null || echo "Not Available")
    
    print_status "Retrieving credentials (can take up to 30s)..."
    local key_path="$DATA_DIR/server/id_ed25519.pub"
    local admin_password=""
    local public_key=""
    local counter=0
    while [ $counter -lt 30 ]; do
        # Check for key
        if [ -z "$public_key" ] && pct exec "$CTID" -- test -f "$key_path"; then
            public_key=$(pct exec "$CTID" -- cat "$key_path" 2>/dev/null)
        fi
        # Check for password
        if [ -z "$admin_password" ]; then
            admin_password=$(pct exec "$CTID" -- docker logs $CONTAINER_NAME 2>&1 | grep "Admin Password Is" | tail -1 | awk -F': ' '{print $2}' | tr -d ' \r' || true)
        fi
        # Exit loop if both are found
        if [ -n "$public_key" ] && [ -n "$admin_password" ]; then break; fi
        sleep 1; counter=$((counter+1))
    done
    
    public_key=${public_key:-"Not found. Check logs with option 6."}
    admin_password=${admin_password:-"Not found. Check logs with option 6."}

    echo ""
    echo "============================================================="
    echo -e "${GREEN}      RustDesk on Tailscale - Configuration Details${NC}"
    echo "============================================================="
    echo -e "\n${YELLOW}🌐 Web Admin Panel:${NC}"
    echo "   URL:      http://$tailscale_ip:21114/_admin/"
    echo "   Username: admin"
    echo "   Password: $admin_password"
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
    echo "==================================================="; echo "     RustDesk on Tailscale - LXC Management"; echo "==================================================="
    echo "  Manages LXC ${CTID} (${CTNAME})"; echo "==================================================="
    echo " 1. Setup / Re-deploy Server"; echo -e " 2. ${RED}Destroy Server LXC${NC}"; echo " -------------------------------------------------"
    echo " 3. Start LXC"; echo " 4. Stop LXC"; echo " 5. Show Status and Credentials"; echo " 6. View Server Logs (inside LXC)"; echo " 7. Enter LXC Shell"
    echo " -------------------------------------------------"; echo -e " 0. ${YELLOW}Quit${NC}"; echo "==================================================="
}

main() {
    while true; do
        show_menu
        read -p "Enter your choice [0-7]: " choice
        case "$choice" in
            1) setup ;; 2) destroy ;; 3) print_status "Starting LXC ${CTID}..."; pct start "$CTID" 
            4) print_status "Stopping LXC ${CTID}..."; pct stop "$CTID" ;; 5) status 
            6) print_status "Following logs for rustdesk-server. Press Ctrl+C to stop."; pct exec "$CTID" -- docker logs -f rustdesk-server 
            7) pct enter "$CTID" ;; 0) break ;; *) print_error "Invalid option." 
        esac
        echo; read -p "Press Enter to return to the menu..."
    done
    print_status "Exiting."
}

main