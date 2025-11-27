# #!/usr/bin/env bash
# set -euo pipefail

# ### ========== CONFIG (edit to fit your office) ==========
# CTID="${CTID:-101}"
# CTNAME="${CTNAME:-wg-office}"

# # Proxmox / networking
# STORAGE="${STORAGE:-local-lvm}"        # where to put the CT root disk (lvmthin)
# BRIDGE="${BRIDGE:-vmbr0}"
# CT_IP="${CT_IP:-192.168.0.22/24}"      # LXC container LAN IP
# CT_GW="${CT_GW:-192.168.0.1}"          # LAN gateway/router
# TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"  # pveam list local
# DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9}"

# # Office LAN (used for “lan” peers)
# OFFICE_LAN_CIDR="${OFFICE_LAN_CIDR:-192.168.0.0/24}"

# # WireGuard basics (inside the VPN)
# WG_PORT="${WG_PORT:-51820}"
# WG_NET="${WG_NET:-10.8.0.0/24}"        # VPN subnet
# WG_SVR_IP="${WG_SVR_IP:-10.8.0.1}"     # server IP in that subnet
# WG_HOST="${WG_HOST:-example.office.com}"   # public DNS name or IP

# # Routing policy inside CT:
# # "lan-only"     -> only office LAN is routed; requires a static route on the office router (WG_NET via CT_IP)
# # "full-tunnel"  -> NAT enabled; no router static route needed. Per-peer you can still choose lan/full.
# ROUTE_MODE="${ROUTE_MODE:-lan-only}"
# ### =======================================================

# need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

# echo "[1/7] Checking prerequisites on host..."
# need pct
# need pveam

# echo "[2/7] Ensuring template exists: $TEMPLATE"
# if ! pveam list local | awk '{print $1}' | grep -q "$(basename "$TEMPLATE")"; then
#   echo "Template $TEMPLATE not found in local; run: pveam download local <debian-12-*.tar.zst>"
#   exit 1
# fi

# echo "[3/7] Creating LXC $CTID ($CTNAME) if not exists..."
# if pct status "$CTID" >/dev/null 2>&1; then
#   echo "CT $CTID already exists. Skipping create."
# else
#   # set a temporary root password to avoid interactive prompt (change later inside CT with `passwd`)
#   TEMP_PW="${TEMP_PW:-TempPass$(date +%s | tail -c5)}"

#   pct create "$CTID" "$TEMPLATE" \
#     --hostname "$CTNAME" \
#     --rootfs "$STORAGE:4" \
#     --cores 1 --memory 512 --swap 512 \
#     --net0 "name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW" \
#     --features "keyctl=1,nesting=1" \
#     --unprivileged 0 \
#     --password "$TEMP_PW"
# fi

# echo "[4/7] Starting CT..."
# pct start "$CTID"

# echo "[5/7] Base packages in CT..."
# pct exec "$CTID" -- bash -lc "apt update && apt install -y --no-install-recommends wireguard wireguard-tools iproute2 nftables qrencode ca-certificates curl vim dnsutils"

# echo "[6/7] Enable IP forwarding and nftables..."
# pct exec "$CTID" -- bash -lc "sed -i 's/^#\\?net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf && sysctl -p || true"
# pct exec "$CTID" -- bash -lc "systemctl enable nftables --now"

# echo "[7/7] Configure WireGuard (wg0)..."
# # Generate server keys if missing
# pct exec "$CTID" -- bash -lc '
# set -e
# umask 077
# mkdir -p /etc/wireguard
# cd /etc/wireguard
# [ -f server_private.key ] || (wg genkey > server_private.key)
# [ -f server_public.key ]  || (wg pubkey < server_private.key > server_public.key)
# '

# SERVER_PUB=$(pct exec "$CTID" -- bash -lc "cat /etc/wireguard/server_public.key" | tr -d '\r\n')

# # Build wg0.conf
# pct exec "$CTID" -- bash -lc "cat > /etc/wireguard/wg0.conf" <<EOF
# [Interface]
# Address = ${WG_SVR_IP}/24
# ListenPort = ${WG_PORT}
# PrivateKey = $(pct exec "$CTID" -- bash -lc "cat /etc/wireguard/server_private.key")
# SaveConfig = true
# PostUp = sysctl -w net.ipv4.ip_forward=1

# # nftables baseline (accept forward)
# PostUp = nft add table ip wg 2>/dev/null; nft 'add chain ip wg forward { type filter hook forward priority 0 ; policy accept ; }' 2>/dev/null || true

# # NAT if full-tunnel
# $( [ "$ROUTE_MODE" = "full-tunnel" ] && echo "PostUp = nft add table ip nat 2>/dev/null; nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }' 2>/dev/null || true; nft add rule ip nat postrouting ip saddr ${WG_NET} oifname \"eth0\" masquerade || true" )

# # Clean-up on down
# PostDown = nft delete table ip wg 2>/dev/null || true
# $( [ "$ROUTE_MODE" = "full-tunnel" ] && echo "PostDown = nft delete table ip nat 2>/dev/null || true" )
# EOF

# # DNS in CT (safe write)
# pct exec "$CTID" -- bash -lc 'printf "nameserver %s\n" '"$DNS_SERVERS"' > /etc/resolv.conf'

# # Enable & start
# pct exec "$CTID" -- bash -lc "systemctl enable wg-quick@wg0 && systemctl restart wg-quick@wg0"

# echo "Creating helper script inside CT for adding peers..."
# pct exec "$CTID" -- bash -lc "cat > /usr/local/bin/wg-add-peer" <<'EOS'
# #!/usr/bin/env bash
# set -euo pipefail
# NAME="${1:-}"
# PEER_IP="${2:-}"
# ALLOWED="${3:-lan}"
# # usage: wg-add-peer <name> <peer_vpn_ip> [lan|full]

# if [ -z "$NAME" ] || [ -z "$PEER_IP" ]; then
#   echo "Usage: wg-add-peer <name> <peer_vpn_ip> [lan|full]"
#   exit 1
# fi

# WG_NET="__WG_NET__"
# WG_SVR_IP="__WG_SVR_IP__"
# WG_PORT="__WG_PORT__"
# WG_HOST="__WG_HOST__"
# OFFICE_LAN_CIDR="__OFFICE_LAN_CIDR__"

# # Decide AllowedIPs (what the client can reach)
# if [ "$ALLOWED" = "full" ]; then
#   ALLOWED_IPS="0.0.0.0/0, ::/0"
# else
#   ALLOWED_IPS="${OFFICE_LAN_CIDR}"
# fi

# umask 077
# cd /etc/wireguard
# wg genkey | tee "${NAME}_private.key" | wg pubkey > "${NAME}_public.key"
# PVT=$(cat "${NAME}_private.key")
# PUB=$(cat "${NAME}_public.key")

# # Add to server
# cat >> /etc/wireguard/wg0.conf <<EOT

# # ${NAME}
# [Peer]
# PublicKey = ${PUB}
# AllowedIPs = ${PEER_IP}/32
# EOT

# # Apply live
# wg set wg0 peer "${PUB}" allowed-ips "${PEER_IP}/32"
# wg-quick save wg0

# # Client config
# cat > "/etc/wireguard/${NAME}.conf" <<EOT
# [Interface]
# Address = ${PEER_IP}/24
# PrivateKey = ${PVT}
# DNS = 1.1.1.1

# [Peer]
# PublicKey = $(cat server_public.key)
# AllowedIPs = ${ALLOWED_IPS}
# Endpoint = ${WG_HOST}:${WG_PORT}
# PersistentKeepalive = 25
# EOT

# # QR for mobile
# if command -v qrencode >/dev/null 2>&1; then
#   echo "========== ${NAME}.conf (QR) =========="
#   qrencode -t ANSIUTF8 < "/etc/wireguard/${NAME}.conf"
#   echo "======================================="
# fi

# echo "Client file at: /etc/wireguard/${NAME}.conf"
# EOS

# pct exec "$CTID" -- sed -i \
#   -e "s|__WG_NET__|$WG_NET|g" \
#   -e "s|__WG_SVR_IP__|$WG_SVR_IP|g" \
#   -e "s|__WG_PORT__|$WG_PORT|g" \
#   -e "s|__WG_HOST__|$WG_HOST|g" \
#   -e "s|__OFFICE_LAN_CIDR__|$OFFICE_LAN_CIDR|g" \
#   /usr/local/bin/wg-add-peer

# pct exec "$CTID" -- chmod +x /usr/local/bin/wg-add-peer

# echo
# echo "=== DONE ==="
# echo "CT $CTID ($CTNAME) at $CT_IP"
# echo "WireGuard server pubkey: $SERVER_PUB"
# echo "WG listening UDP port: $WG_PORT"
# echo "WG host (public): $WG_HOST"
# echo "Route mode: $ROUTE_MODE"
# echo
# echo "Add a LAN-only peer (example):"
# echo "  pct exec $CTID -- wg-add-peer phone __FIRST_CLIENT__/24 lan"
# echo "  # replace __FIRST_CLIENT__ with an IP in $WG_NET (e.g., 10.2.0.10 if WG_NET=10.2.0.0/24)"
# echo
# echo "Show status:"
# echo "  pct exec $CTID -- wg show"



#!/usr/bin/env bash
set -euo pipefail

### ========== CONFIG (edit to fit your office) ==========
CTID="${CTID:-101}"
CTNAME="${CTNAME:-wg-office}"

# Proxmox / networking
STORAGE="${STORAGE:-local-lvm}"        # lvmthin storage
BRIDGE="${BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-192.168.0.22/24}"      # LXC container LAN IP
CT_GW="${CT_GW:-192.168.0.1}"          # LAN gateway/router
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 9.9.9.9}"

# Office LAN (used for “lan” peers)
OFFICE_LAN_CIDR="${OFFICE_LAN_CIDR:-192.168.0.0/24}"

# WireGuard basics (inside the VPN)
WG_PORT="${WG_PORT:-51820}"
WG_NET="${WG_NET:-10.8.0.0/24}"        # VPN subnet
WG_SVR_IP="${WG_SVR_IP:-10.8.0.1}"     # server IP in that subnet
WG_HOST="${WG_HOST:-example.office.com}"   # public DNS name or IP

# Routing policy inside CT:
# "lan-only"     -> only office LAN is routed; requires a static route on the office router (WG_NET via CT_IP)
# "full-tunnel"  -> NAT enabled; no router static route needed. Per-peer you can still choose lan/full.
ROUTE_MODE="${ROUTE_MODE:-lan-only}"

# ---- wg-easy (web UI) ----
WGE_ENABLE="${WGE_ENABLE:-yes}"        # yes/no to deploy wg-easy container
WGE_UI_PORT="${WGE_UI_PORT:-51821}"    # UI port (tcp)
WGE_PASSWORD="${WGE_PASSWORD:-}"       # if empty, random will be generated
WGE_DEFAULT_DNS="${WGE_DEFAULT_DNS:-1.1.1.1,9.9.9.9}"
WGE_ALLOWED_IPS_DEFAULT="${WGE_ALLOWED_IPS_DEFAULT:-${OFFICE_LAN_CIDR},${WG_NET}}"
TZ_VAL="${TZ_VAL:-Asia/Kolkata}"
### =======================================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

echo "[1/8] Checking prerequisites on host..."
need pct
need pveam

echo "[2/8] Ensuring template exists: $TEMPLATE"
if ! pveam list local | awk '{print $1}' | grep -q "$(basename "$TEMPLATE")"; then
  echo "Template $TEMPLATE not found in local; run: pveam download local <debian-12-*.tar.zst>"
  exit 1
fi

echo "[3/8] Creating LXC $CTID ($CTNAME) if not exists..."
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists. Skipping create."
else
  TEMP_PW="${TEMP_PW:-TempPass$(date +%s | tail -c5)}"
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CTNAME" \
    --rootfs "$STORAGE:4" \
    --cores 1 --memory 512 --swap 512 \
    --net0 "name=eth0,bridge=$BRIDGE,ip=$CT_IP,gw=$CT_GW" \
    --features "keyctl=1,nesting=1" \
    --unprivileged 0 \
    --password "$TEMP_PW"
fi

echo "[4/8] Starting CT..."
pct start "$CTID"

echo "[5/8] Base packages in CT..."
pct exec "$CTID" -- bash -lc "apt update && apt install -y --no-install-recommends wireguard wireguard-tools iproute2 nftables qrencode ca-certificates curl vim dnsutils gnupg"

echo "[6/8] Enable IP forwarding and nftables..."
pct exec "$CTID" -- bash -lc "sed -i 's/^#\\?net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf && sysctl -p || true"
pct exec "$CTID" -- bash -lc "systemctl enable nftables --now"

echo "[7/8] Configure WireGuard (wg0)..."
# Generate server keys if missing
pct exec "$CTID" -- bash -lc '
set -e
umask 077
mkdir -p /etc/wireguard
cd /etc/wireguard
[ -f server_private.key ] || (wg genkey > server_private.key)
[ -f server_public.key ]  || (wg pubkey < server_private.key > server_public.key)
'

SERVER_PUB=$(pct exec "$CTID" -- bash -lc "cat /etc/wireguard/server_public.key" | tr -d '\r\n')

# Build wg0.conf
pct exec "$CTID" -- bash -lc "cat > /etc/wireguard/wg0.conf" <<EOF
[Interface]
Address = ${WG_SVR_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = $(pct exec "$CTID" -- bash -lc "cat /etc/wireguard/server_private.key")
SaveConfig = true
PostUp = sysctl -w net.ipv4.ip_forward=1

# nftables baseline (accept forward)
PostUp = nft add table ip wg 2>/dev/null; nft 'add chain ip wg forward { type filter hook forward priority 0 ; policy accept ; }' 2>/dev/null || true

# NAT if full-tunnel
$( [ "$ROUTE_MODE" = "full-tunnel" ] && echo "PostUp = nft add table ip nat 2>/dev/null; nft 'add chain ip nat postrouting { type nat hook postrouting priority 100 ; }' 2>/dev/null || true; nft add rule ip nat postrouting ip saddr ${WG_NET} oifname \"eth0\" masquerade || true" )

# Clean-up on down
PostDown = nft delete table ip wg 2>/dev/null || true
$( [ "$ROUTE_MODE" = "full-tunnel" ] && echo "PostDown = nft delete table ip nat 2>/dev/null || true" )
EOF

# DNS in CT (safe write)
pct exec "$CTID" -- bash -lc 'printf "nameserver %s\n" '"$DNS_SERVERS"' > /etc/resolv.conf'

# Enable & start wg
pct exec "$CTID" -- bash -lc "systemctl enable wg-quick@wg0 && systemctl restart wg-quick@wg0"

echo "Creating helper script inside CT for adding peers..."
pct exec "$CTID" -- bash -lc "cat > /usr/local/bin/wg-add-peer" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
NAME="${1:-}"
PEER_IP="${2:-}"
ALLOWED="${3:-lan}"
# usage: wg-add-peer <name> <peer_vpn_ip> [lan|full]

if [ -z "$NAME" ] || [ -z "$PEER_IP" ]; then
  echo "Usage: wg-add-peer <name> <peer_vpn_ip> [lan|full]"
  exit 1
fi

WG_NET="__WG_NET__"
WG_SVR_IP="__WG_SVR_IP__"
WG_PORT="__WG_PORT__"
WG_HOST="__WG_HOST__"
OFFICE_LAN_CIDR="__OFFICE_LAN_CIDR__"

# Decide AllowedIPs (what the client can reach)
if [ "$ALLOWED" = "full" ]; then
  ALLOWED_IPS="0.0.0.0/0, ::/0"
else
  ALLOWED_IPS="${OFFICE_LAN_CIDR}"
fi

umask 077
cd /etc/wireguard
wg genkey | tee "${NAME}_private.key" | wg pubkey > "${NAME}_public.key"
PVT=$(cat "${NAME}_private.key")
PUB=$(cat "${NAME}_public.key")

# Add to server
cat >> /etc/wireguard/wg0.conf <<EOT

# ${NAME}
[Peer]
PublicKey = ${PUB}
AllowedIPs = ${PEER_IP}/32
EOT

# Apply live
wg set wg0 peer "${PUB}" allowed-ips "${PEER_IP}/32"
wg-quick save wg0

# Client config
cat > "/etc/wireguard/${NAME}.conf" <<EOT
[Interface]
Address = ${PEER_IP}/24
PrivateKey = ${PVT}
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat server_public.key)
AllowedIPs = ${ALLOWED_IPS}
Endpoint = ${WG_HOST}:${WG_PORT}
PersistentKeepalive = 25
EOT

# QR for mobile
if command -v qrencode >/dev/null 2>&1; then
  echo "========== ${NAME}.conf (QR) =========="
  qrencode -t ANSIUTF8 < "/etc/wireguard/${NAME}.conf"
  echo "======================================="
fi

echo "Client file at: /etc/wireguard/${NAME}.conf"
EOS

pct exec "$CTID" -- sed -i \
  -e "s|__WG_NET__|$WG_NET|g" \
  -e "s|__WG_SVR_IP__|$WG_SVR_IP|g" \
  -e "s|__WG_PORT__|$WG_PORT|g" \
  -e "s|__WG_HOST__|$WG_HOST|g" \
  -e "s|__OFFICE_LAN_CIDR__|$OFFICE_LAN_CIDR|g" \
  /usr/local/bin/wg-add-peer
pct exec "$CTID" -- chmod +x /usr/local/bin/wg-add-peer

echo "[8/8] (Optional) Install wg-easy web UI... ($WGE_ENABLE)"
if [ "$WGE_ENABLE" = "yes" ]; then
  # generate password if empty
  if [ -z "$WGE_PASSWORD" ]; then
    WGE_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)"
    echo "wg-easy admin password (generated): $WGE_PASSWORD"
  else
    echo "wg-easy admin password (from env):  [hidden]"
  fi

  # Install Docker (official repo) and run wg-easy
  pct exec "$CTID" -- bash -lc '
set -e
apt update
apt install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
docker stop wg-easy 2>/dev/null || true
docker rm wg-easy 2>/dev/null || true
'

  # Run wg-easy (bind /etc/wireguard, expose only web UI port)
  pct exec "$CTID" -- bash -lc "docker run -d \
    --name wg-easy \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    -e TZ='${TZ_VAL}' \
    -e WG_HOST='${WG_HOST}' \
    -e WG_PORT='${WG_PORT}' \
    -e PASSWORD='${WGE_PASSWORD}' \
    -e WG_DEFAULT_DNS='${WGE_DEFAULT_DNS}' \
    -e WG_ALLOWED_IPS='${WGE_ALLOWED_IPS_DEFAULT}' \
    -v /etc/wireguard:/etc/wireguard \
    -p ${WGE_UI_PORT}:51821/tcp \
    --restart unless-stopped \
    weejewel/wg-easy:latest"
fi

echo
echo "=== DONE ==="
echo "CT $CTID ($CTNAME) at $CT_IP"
echo "WireGuard server pubkey: $SERVER_PUB"
echo "WG listening UDP port: $WG_PORT"
echo "WG host (public): $WG_HOST"
echo "Route mode: $ROUTE_MODE"
if [ "$WGE_ENABLE" = "yes" ]; then
  echo "wg-easy UI: http://$(echo $CT_IP | cut -d/ -f1):${WGE_UI_PORT}"
  echo "wg-easy password: ${WGE_PASSWORD}"
fi
echo
echo "Add a LAN-only peer (example):"
echo "  pct exec $CTID -- wg-add-peer phone __FIRST_CLIENT__/24 lan"
echo "  # replace __FIRST_CLIENT__ with an IP in $WG_NET (e.g., 10.2.0.10 if WG_NET=10.2.0.0/24)"
echo
echo "Show status:"
echo "  pct exec $CTID -- wg show"
