#!/usr/bin/env bash
set -euo pipefail

### ========== CONFIG (edit to fit your office) ========== 
CTID="${CTID:-101}"
CTNAME="${CTNAME:-wg-office}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"

CT_IP="${CT_IP:-192.168.0.22/24}"
CT_GW="${CT_GW:-192.168.0.1}"
OFFICE_LAN_CIDR="${OFFICE_LAN_CIDR:-192.168.0.0/24}"
WG_NET="${WG_NET:-10.8.0.0/24}"
### =======================================================

# --- Script Internals ---
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info() { echo -e "${C_BLUE}[INFO]${C_NC} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_NC} $1"; exit 1; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_NC} $1"; }

# --- Core Functions ---

setup() {
  info "[1/5] Checking prerequisites..."
  command -v pct >/dev/null 2>&1 || error "pct command not found. Run this on Proxmox."
  if ! pveam list local | awk '{print $1}' | grep -q "$(basename "$TEMPLATE")"; then
    error "Template $TEMPLATE not found. Please run: pveam download local $(basename "$TEMPLATE")"
  fi
  success "Prerequisites met."

  info "[2/5] Creating LXC Container..."
  if pct status "$CTID" >/dev/null 2>&1; then
    warn "CT $CTID already exists. Skipping creation."
  else
    pct create "$CTID" "$TEMPLATE" --hostname "$CTNAME" --storage "$STORAGE" --rootfs "$STORAGE:4" \
      --cores 1 --memory 512 --swap 512 --onboot 1 --unprivileged 0 \
      --net0 name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW \
      --features nesting=1 >/dev/null
    pct start "$CTID"
    sleep 5
  fi
  
  info "[3/5] Installing Docker..."
  if pct exec "$CTID" -- command -v docker &>/dev/null; then
    warn "Docker is already installed. Skipping installation."
  else
    pct exec "$CTID" -- apt-get update
    pct exec "$CTID" -- apt-get install -y curl
    pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh"
    
    # **FIXED VERIFICATION STEP**
    if ! pct exec "$CTID" -- docker --version &>/dev/null; then
      error "Docker installation failed. Please check the output above."
    fi
    success "Docker installed successfully."
  fi

  info "[4/5] Preparing WireGuard Configuration..."
  local wg_host admin_pass confirm_pass
  echo "Please provide the public address for your WireGuard server."
  read -p "Enter WireGuard Host (e.g., vpn.yourdomain.com or your public IP): " wg_host
  [ -z "$wg_host" ] && error "WireGuard Host cannot be empty."

  while true; do
      read -sp "Enter a password for the WireGuard web admin panel: " admin_pass; echo
      read -sp "Confirm password: " confirm_pass; echo
      [ "$admin_pass" == "$confirm_pass" ] && [ -n "$admin_pass" ] && break
      warn "Passwords do not match or are empty. Please try again."
  done

  # Create a temporary .env file
  cat > ./wireguard/.env <<EOF
WG_HOST=${wg_host}
PASSWORD=${admin_pass}
WG_ALLOWED_IPS_DEFAULT=${OFFICE_LAN_CIDR},${WG_NET}
EOF
  
  info "[5/5] Deploying WireGuard Service (wg-easy)..."
  local COMPOSE_DIR="/opt/wireguard"
  pct exec "$CTID" -- mkdir -p "$COMPOSE_DIR/config"
pct push "$CTID" "./wireguard/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
pct push "$CTID" "./wireguard/.env" "$COMPOSE_DIR/.env"
rm "./wireguard/.env" # Clean up local temp file

  pct exec "$CTID" -- bash -c "cd $COMPOSE_DIR && docker compose up -d"
  
  echo
  success "=== SETUP COMPLETE ==="
  status
}

destroy() {
  if ! pct status "$CTID" >/dev/null 2>&1; then warn "CT $CTID does not exist."; return; fi
  warn "This will permanently stop and delete the container CT $CTID ($CTNAME)."
  read -p "Are you sure? [y/N] " -n 1 -r; echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then info "Aborted."; return; fi
  
  info "Stopping CT $CTID..."; pct stop "$CTID" || true
  info "Destroying CT $CTID..."; pct destroy "$CTID"
  success "CT $CTID has been destroyed."
}

status() {
  if ! pct status "$CTID" >/dev/null 2>&1; then warn "CT $CTID does not exist."; return; fi
  info "--- CT Status ---"; pct status "$CTID"
  info "--- Docker Container Status (inside CT) ---"
  pct exec "$CTID" -- docker ps
  info "--- Live WireGuard Status (from wg-easy container) ---"
  pct exec "$CTID" -- docker exec wg-easy wg show
  echo
  info "--- Summary ---"
  echo "WireGuard UI Panel: http://$(echo $CT_IP | cut -d/ -f1):51821"
  warn "Use the UI Panel to add/remove clients. Manual peer commands are no longer used."
}

ct_action() {
  local action=$1
  if ! pct status "$CTID" >/dev/null 2>&1; then error "CT $CTID does not exist."; fi
  info "${action}-ing CT $CTID..."; pct "$action" "$CTID"
  success "CT $CTID finished ${action}."
}

show_menu() {
    clear
    echo -e "${C_GREEN}WireGuard Lab Management Menu (Docker Compose Edition)${C_NC}"
    echo "---------------------------------"
    echo " 1) Setup / Re-deploy WireGuard"
    echo -e " 2) ${C_RED}Destroy WireGuard CT${C_NC}"
    echo "---------------------------------"
    echo " 3) Start CT"
    echo " 4) Stop CT"
    echo " 5) Reboot CT"
    echo " 6) Show Status"
    echo " 7) Open Shell in CT"
    echo "---------------------------------"
    echo -e " 0) ${C_YELLOW}Quit${C_NC}"
    echo "---------------------------------"
}

main() {
  while true; do
    show_menu
    read -p "Enter your choice [0-7]: " choice
    case "$choice" in
      1) setup ;;
      2) destroy ;;
      3) ct_action "start" ;;
      4) ct_action "stop" ;;
      5) ct_action "reboot" ;;
      6) status ;;
      7) pct enter "$CTID" ;;
      0) break ;;
      *) warn "Invalid option." ;;
    esac
    echo; read -p "Press Enter to return to the menu..."
  done
  info "Exiting."
}

main "$@"
