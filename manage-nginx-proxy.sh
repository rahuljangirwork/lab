#!/usr/bin/env bash
set -euo pipefail

### ========== CONFIGURATION (edit for your lab) ==========
CTID="${CTID:-105}"
CTNAME="${CTNAME:-nginx-proxy}"
CT_IP="${CT_IP:-192.168.0.105/24}"
CT_GW="${CT_GW:-192.168.0.1}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"
DISK_GB="${DISK_GB:-16}"

COMPOSE_DIR="/opt/nginx-proxy-manager"
LOCAL_STACK_DIR="./nginx-proxy"
### =======================================================

# --- Helpers ---
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info() { echo -e "${C_BLUE}[INFO]${C_NC} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_NC} $1"; exit 1; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_NC} $1"; }

require_pct() {
  command -v pct >/dev/null 2>&1 || error "pct command not found. Run this on a Proxmox host."
}

ensure_template() {
  local template_name
  template_name=$(basename "$TEMPLATE")
  if ! pveam list local | awk '{print $1}' | grep -q "$template_name"; then
    error "Template $template_name not found. Download it with: pveam download local $template_name"
  fi
}

# --- Core Functions ---
setup() {
  require_pct
  ensure_template

  info "[1/6] Creating or reusing CT ${CTID}..."
  if pct status "$CTID" >/dev/null 2>&1; then
    warn "CT $CTID already exists. Skipping creation."
  else
    pct create "$CTID" "$TEMPLATE" \
      --hostname "$CTNAME" \
      --storage "$STORAGE" \
      --rootfs "${STORAGE}:${DISK_GB}" \
      --cores "$CORES" \
      --memory "$MEMORY" \
      --swap 512 \
      --onboot 1 \
      --unprivileged 0 \
      --net0 name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW \
      --features nesting=1 >/dev/null
    pct start "$CTID"
    sleep 5
  fi

  info "[2/6] Applying LXC config for Docker..."
  local conf_file="/etc/pve/lxc/${CTID}.conf"
  local reboot_needed=false
  if ! grep -q "lxc.apparmor.profile: unconfined" "$conf_file"; then
    echo "lxc.apparmor.profile: unconfined" >> "$conf_file"
    reboot_needed=true
  fi
  if [ "$reboot_needed" = true ]; then
    warn "Rebooting CT $CTID to apply config..."
    pct reboot "$CTID"
    sleep 10
  else
    info "AppArmor profile already set."
  fi

  info "[3/6] Installing Docker + prerequisites..."
  pct exec "$CTID" -- bash -c "apt-get update" >/dev/null
  pct exec "$CTID" -- bash -c "apt-get install -y curl ca-certificates docker-compose-plugin" >/dev/null
  if ! pct exec "$CTID" -- docker --version >/dev/null 2>&1; then
    pct exec "$CTID" -- bash -c "curl -fsSL https://get.docker.com | sh" >/dev/null
  fi
  success "Docker runtime ready."

  info "[4/6] Copying docker-compose stack..."
  pct exec "$CTID" -- mkdir -p "$COMPOSE_DIR"
  pct push "$CTID" "${LOCAL_STACK_DIR}/docker-compose.yml" "${COMPOSE_DIR}/docker-compose.yml"
  pct exec "$CTID" -- bash -c "mkdir -p ${COMPOSE_DIR}/data ${COMPOSE_DIR}/letsencrypt"

  info "[5/6] Deploying Nginx Proxy Manager..."
  pct exec "$CTID" -- bash -c "cd $COMPOSE_DIR && docker compose pull"
  pct exec "$CTID" -- bash -c "cd $COMPOSE_DIR && docker compose up -d"

  info "[6/6] Finalizing setup..."
  status
}

destroy() {
  if ! pct status "$CTID" >/dev/null 2>&1; then
    warn "CT $CTID does not exist."
    return
  fi
  warn "Destroying CT $CTID ($CTNAME) will delete all proxy data."
  read -p "Are you sure? [y/N] " -n 1 -r; echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    return
  fi
  info "Stopping CT $CTID..."; pct stop "$CTID" || true
  info "Destroying CT $CTID..."; pct destroy "$CTID"
  success "CT $CTID removed."
}

status() {
  if ! pct status "$CTID" >/dev/null 2>&1; then
    warn "CT $CTID does not exist."
    return
  fi
  local ip_address
  ip_address=$(echo "$CT_IP" | cut -d'/' -f1)
  info "--- CT Status ---"
  pct status "$CTID"
  info "--- Docker Containers ---"
  pct exec "$CTID" -- docker ps --filter "name=nginx-proxy-manager"
  echo
  info "Nginx Proxy Manager UI"
  echo "  URL: http://${ip_address}:81"
  echo "  Default login: admin@example.com / changeme"
  echo "  Ports proxied: 80 (HTTP), 443 (HTTPS)"
  echo "  Add hosts/interfaces inside the UI after first login."
}

ct_action() {
  local action=$1
  if ! pct status "$CTID" >/dev/null 2>&1; then
    error "CT $CTID does not exist."
  fi
  info "${action^} CT $CTID..."
  pct "$action" "$CTID"
  success "CT $CTID ${action} complete."
}

show_menu() {
  clear
  echo -e "${C_GREEN}Nginx Proxy Manager - LXC Control${C_NC}"
  echo "---------------------------------"
  echo " 1) Setup / Re-deploy"
  echo -e " 2) ${C_RED}Destroy Container${C_NC}"
  echo "---------------------------------"
  echo " 3) Start CT"
  echo " 4) Stop CT"
  echo " 5) Reboot CT"
  echo " 6) Show Status"
  echo " 7) Enter CT Shell"
  echo "---------------------------------"
  echo -e " 0) ${C_YELLOW}Quit${C_NC}"
  echo "---------------------------------"
}

main() {
  while true; do
    show_menu
    read -p "Enter choice [0-7]: " choice
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
    echo; read -p "Press Enter to continue..."
  done
  info "Exiting."
}

main "$@"
