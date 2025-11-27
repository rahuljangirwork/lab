cd /root/officelab

CTID=101 \
CTNAME=wg-office \
STORAGE=local-lvm \
BRIDGE=vmbr0 \
CT_IP=192.168.0.201/24 \
CT_GW=192.168.0.1 \
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst" \
WG_PORT=51820 \
WG_NET=10.2.0.0/24 \
WG_SVR_IP=10.2.0.1 \
WG_HOST=vpn.getmysolutions.in \
OFFICE_LAN_CIDR=192.168.0.0/24 \
ROUTE_MODE=full-tunnel \
./office-wireguard-lxc.sh





Create a peer: pct exec 101 -- wg-add-peer phone 10.8.0.10/24 full


Create a peer: pct exec 101 -- wg-add-peer phone 10.8.0.11/24 lan


vpn.getmysolutions.in