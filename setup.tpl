#!/bin/bash

# Update and install
apt-get update -y
apt-get install wireguard iptables -y

# Enable IP Forwarding
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Generate Keys
cd /etc/wireguard
umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

# Read keys (Normal bash syntax, Terraform will ignore these)
SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)
CLIENT_PRIV=$(cat client_private.key)
CLIENT_PUB=$(cat client_public.key)

# Create Server Config
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens5 -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.0.0.2/32
EOF

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Auto-Generate Windows Client
cat <<EOF > /home/ubuntu/windows_client.conf
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
# This is the ONLY variable Terraform will dynamically replace:
Endpoint = ${accelerator_ip}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chown ubuntu:ubuntu /home/ubuntu/windows_client.conf