#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

PLAYER_NAME=$1
PLATFORM=$2
IP_MAP_FILE="keys/ip_mappings.txt"

if [ -z "$PLAYER_NAME" ]; then
    echo "Usage: $0 <player_name>"
    exit 1
fi

if [ -d "keys/$PLAYER_NAME" ]; then
    echo "Error: Directory keys/$PLAYER_NAME already exists. Please choose a different player name."
    exit 1
fi

if [ -z "$PLATFORM" ]; then
    echo "Warning: No platform specified. Defaulting to 'windows'."
    PLATFORM="windows"
fi

if [ ! -f "$IP_MAP_FILE" ]; then
    touch "$IP_MAP_FILE"
fi

NEXT_IP=2
while grep -q "^10.0.0.$NEXT_IP " "$IP_MAP_FILE"; do
    NEXT_IP=$((NEXT_IP + 1))
done


# Player directory, keys, IP config
mkdir keys/$PLAYER_NAME
wg genkey | tee keys/$PLAYER_NAME/private.key | wg pubkey > keys/$PLAYER_NAME/public.key

# Assign IP
echo "10.0.0.$NEXT_IP $PLAYER_NAME" >> "$IP_MAP_FILE"


SERVER_PUB=$(cat keys/server_public.key)

DOMAIN=$(cat main.tfvars | grep "[[:space:]]domain[[:space:]]" | head -1 | cut -d '"' -f 2)
SUBDOMAIN=$(cat main.tfvars | grep "[[:space:]]subdomain[[:space:]]" | head -1 | cut -d '"' -f 2)
domain="$SUBDOMAIN.$DOMAIN"

FOLDERS_ONLY=$(find keys -mindepth 1 -maxdepth 1 -type d)

for folder in $FOLDERS_ONLY; do
    CLIENT_NAME=$(basename $folder)
    CLIENT_IP=$(grep " $CLIENT_NAME$" "$IP_MAP_FILE" | cut -d' ' -f1 | cut -d'.' -f4)

    if [ -z "$CLIENT_IP" ]; then
        echo "Warning: No IP mapping found for $CLIENT_NAME, skipping..."
        continue
    fi
    if [ "$PLATFORM" == "windows" ]; then
            cat <<EOF > "$folder/$CLIENT_NAME.conf"
[Interface]
PrivateKey = $(cat $folder/private.key)
Address = 10.0.0.$CLIENT_IP/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $domain:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    else
        sed -e "s#\$TEMPLATE_ADDRESS#10.0.0.$CLIENT_IP/32#g" \
            -e "s#\$TEMPLATE_PRIVATE_KEY#$(cat $folder/private.key)#g" \
            -e "s#\$TEMPLATE_PUBLIC_KEY#$SERVER_PUB#g" \
            -e "s#\$TEMPLATE_ENDPOINT#$domain#g" keys/linux_client_template.sh > "$folder/$CLIENT_NAME.sh"
    fi

done

echo "Created client '$PLAYER_NAME' with IP 10.0.0.$NEXT_IP"

./keys/update_setup_script.sh
