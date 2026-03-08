#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

SERVER_PRIV=$(cat keys/server_private.key)
IP_MAP_FILE="keys/ip_mappings.txt"

# Sorting for consistent output
FOLDERS_ONLY=$(find keys -mindepth 1 -maxdepth 1 -type d | sort)

PEER_SECTIONS=""
for folder in $FOLDERS_ONLY; do
    CLIENT_NAME=$(basename "$folder")
    CLIENT_PUB=$(cat "$folder/public.key")
    

    CLIENT_IP=$(grep " $CLIENT_NAME$" "$IP_MAP_FILE" | cut -d' ' -f1 | cut -d'.' -f4)
    
    if [ -z "$CLIENT_IP" ]; then
        echo "Warning: No IP mapping found for $CLIENT_NAME, skipping..."
        continue
    fi
    
    PEER_SECTIONS="${PEER_SECTIONS}
[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.0.0.$CLIENT_IP/32
"
done

cat > setup.tpl <<EOF
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


# Create Server Config
cat <<'WGEOF' > /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = \${port}
PrivateKey = $SERVER_PRIV

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens5 -j MASQUERADE
$PEER_SECTIONS
WGEOF

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
EOF

echo "setup.tpl has been updated with $(echo "$FOLDERS_ONLY" | wc -l) client(s)"
