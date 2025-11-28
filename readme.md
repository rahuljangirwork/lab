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

Create a new port forwarding rule with the following settings:
Service Port (or External Port): 51820
Internal IP Address (or Server IP): 192.168.0.22 (This is the IP of your WireGuard LXC)
Internal Port: 51820
Protocol: UDP (Crucially, WireGuard uses UDP, not TCP)
Name: Give it a name like "WireGuard"


Log in to your main office router's admin page.
Find the "Static Route", "Advanced Routing", or "Routing" section.
Create a new static route with the following settings:
Destination Network (or IP Address): 10.8.0.0
Subnet Mask: 255.255.255.0 (or it might be a dropdown for /24)
Gateway (or Next Hop): 192.168.0.22 (The IP of your WireGuard LXC)
Interface: LAN (if it asks)
This rule tells your router: "If you need to send something to the 10.8.0.0 network, forward it to the WireGuard server at 192.168.0.22."
