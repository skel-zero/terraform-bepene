#!/bin/bash
ADDRESS="$TEMPLATE_ADDRESS"
PRIVATE_KEY="$TEMPLATE_PRIVATE_KEY"
PUBLIC_KEY="$TEMPLATE_PUBLIC_KEY"
ENDPOINT="$TEMPLATE_ENDPOINT"

# If you dont know what is going on don't mess with these variables
MTU="1420"
CGROUP="skel0vpn"
CGROUP_PATH="/sys/fs/cgroup/net_cls/$CGROUP"
CLASSID="0x10001"
PROFILE="fg"
MARK="11"
TABLE="1221"
SCRIPT_PATH=$(realpath "$0")
INSTALL_PATH=/usr/local/bin/skel0vpn

# Elevate script
if [ "$EUID" -ne 0 ] && [ "$1" != "run" ]; then
   exec sudo "$0" "$@"
fi

trim_whitespace() {
    echo "$1" | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//'
}

WireguardConfig() {
    echo "[Wireguard]:"
    if [ "$1" == "install"]; then
        WIREGUARD_CONFIG="
            [Interface]
            Address = $ADDRESS
            DNS = 1.1.1.1
            Table = off
            MTU = $MTU
            PrivateKey = $PRIVATE_KEY

            [Peer]
            PublicKey = $PUBLIC_KEY
            AllowedIPs = 0.0.0.0/0, ::/0
            Endpoint = $ENDPOINT:443
            PersistentKeepalive = 25
        "
        echo "[#] Installing profile."
        trim_whitespace "$WIREGUARD_CONFIG" > /etc/wireguard/$PROFILE.conf
        echo "[#] Done."
    elif [ "$1" == "uninstall"]; then
        echo "[#] Uninstalling profile."
        rm -f /etc/wireguard/$PROFILE.conf
        echo "[#] Done."
    fi
}
CGroupInitService() {
    service_id="$CGROUP-cgroup-init.service"
    service_path="/etc/systemd/system/$service_id"

    echo "[CGroup]:"
    if [ "$1" == "install" ]; then
        CGROUP_SERVICE="
            [Unit]
            Description=Setup skel0vpn cgroup hierarchy
            After=local-fs.target
            Before=network.target

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            # Ensure the directory exists
            ExecStartPre=/usr/bin/mkdir -p /sys/fs/cgroup/net_cls
            # Explicitly mount with v1 options, ignoring errors if already mounted
            ExecStartPre=/usr/bin/sh -c '/usr/bin/mountpoint -q /sys/fs/cgroup/net_cls || /usr/bin/mount -t cgroup -o net_cls net_cls /sys/fs/cgroup/net_cls'

            # Create the specific branch
            ExecStart=/usr/bin/cgcreate -a $SUDO_USER:$SUDO_USER -g net_cls:$CGROUP
            ExecStart=/usr/bin/sh -c 'echo $CLASSID | /usr/bin/tee $CGROUP_PATH/net_cls.classid'
            # ExecStart=/usr/bin/chown -R $SUDO_USER:$SUDO_USER $CGROUP_PATH

            [Install]
            WantedBy=multi-user.target
        "

        echo "[#] Installing $service_id..."
        trim_whitespace "$CGROUP_SERVICE" > $service_path

        echo "[#] Enabling service..."
        systemctl daemon-reload
        systemctl enable $service_id
        systemctl start $service_id
        echo "[#] Done."
    elif [ "$1" == "uninstall" ]; then
        echo "[#] Removing $service_id..."
        systemctl stop $service_id 2>/dev/null
        systemctl disable $service_id 2>/dev/null
        rm -f $service_path
        systemctl daemon-reload

        echo "[#] Deleting $CGROUP cgroup..."
        cgdelete -r net_cls:$CGROUP
        echo "[#] Done."
    fi
}

PacketFilters() {
    echo "[Packet Filters]:"
    if [ "$1" == "set" ]; then

        # Add mark on packets originating from the cgroup
        echo "[#] Setting cgroup filter..."
        iptables -t mangle -A OUTPUT -m cgroup --cgroup $CLASSID -j MARK --set-mark $MARK

        # Set MSS to MTU-40 to stop packets from being dropped
        echo "[#] Setting tcp MSS limiter..."
        iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $(($MTU - 40))

        # Set nat to MASQUERADE so the vpn server doesn't see the wrong ip
        echo "[#] Setting up packet NAT mask..."
        iptables -t nat -A POSTROUTING -o $PROFILE -j MASQUERADE

        echo "[#] Done."
    elif [ "$1" == "unset" ]; then
        echo "[#] Removing cgroup filter..."
        iptables -t mangle -D OUTPUT -m cgroup --cgroup $CLASSID -j MARK --set-mark $MARK 2>/dev/null

        echo "[#] Removing tcp MSS limiter..."
        iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $(($MTU - 40)) 2>/dev/null

        echo "[#] Removing packet NAT mask"
        iptables -t nat -D POSTROUTING -o $PROFILE -j MASQUERADE 2>/dev/null

        echo "[#] Done."
    fi
}
RoutingRules() {
    endpoint_ip=$(ping -c 1 $ENDPOINT | awk -F '[()]' '/PING/ {print $2}')

    echo "[Routing Rules]:"
    if [ "$1" == "set" ]; then
        # Packets with mark will go through the configured table
        echo "[#] Packet Rule: route marked packets to table $TABLE..."
        ip rule add fwmark $MARK priority 500 table $TABLE
        # Route vpn server's ip to main so it doesnt get routed to itself
        echo "[#] Packet Rule: route packets destined to the vpn server's endpoint through the main interface."
        ip rule add to $endpoint_ip priority 400 table main
        # Set the table as a route to the vpn
        echo "[#] Setting table $TABLE as a route to the vpn($PROFILE) interface..."
        ip route add default dev $PROFILE table $TABLE

        ip route flush cache

        echo "[#] Done."
    elif [ "$1" == "unset" ]; then
        echo "[#] Flushing $TABLE table..."
        ip route flush table $TABLE

        echo "[#] Deleting marked packet router"
        ip rule del fwmark $MARK priority 500 2>/dev/null

        echo "[#] Deleting vpn server endpoint router"
        ip rule del to $endpoint_ip priority 400 2>/dev/null

        echo "[#] Done."
    fi
}

vpn_status() {
    echo "[#--- VPN Status ---#]"

    if [ -d "$CGROUP_PATH" ]; then
        cgroup_ip=$(cgexec -g net_cls:$CGROUP curl -s4 ifconfig.me)

        echo "[CGROUP] $CGROUP is active (ClassID: $(cat $CGROUP_PATH/net_cls.classid))"
        echo "[#] IP: $cgroup_ip"
    else
        echo "[CGROUP] $CGROUP is missing. Please re-run \"skel0vpn install\""
        exit
    fi

    if ip link show $PROFILE >/dev/null 2>&1; then
        tunnel_ip=$(curl -s4 --interface $PROFILE ifconfig.me)

        echo "[VPN] Interface $PROFILE is UP"
        echo "[#] IP: $tunnel_ip"
        echo "[#] Interface: $(ip route show table $TABLE)"
        wg_info=$(wg show $PROFILE)

        echo "[#] Latest Handshake: $(echo "$wg_info" | grep -E "latest handshake" | sed 's/.*: //')"
        echo "[#] Session Transfer: $(echo "$wg_info" | grep -E "transfer" | sed 's/.*: //')"

        echo "[#] Latency Check:"
        ping -c 3 -W 1 1.1.1.1 | tail -1 | awk '{print "[#]   ISP Latency: " $4}'
        cgexec -g net_cls:$CGROUP ping -c 3 -W 1 1.1.1.1 | tail -1 | awk '{print "[#]   VPN Latency: " $4}'
    else
        echo "[VPN] Interface $PROFILE is DOWN"
    fi
}

if [ $1 == "install" ]; then
    echo "[#--- Installing VPN ---#]"

    WireguardConfig install

    CGroupInitService install

    echo "[#] Installing script to $INSTALL_PATH..."
    cp $SCRIPT_PATH $INSTALL_PATH
    chmod +x $INSTALL_PATH

    echo "[#] Done."
    echo "[#] VPN Installed."
elif [ $1 == "uninstall" ]; then
    echo "[#--- Uninstalling VPN ---#]"

    CGroupInitService uninstall

    WireguardConfig uninstall

    echo "[#] Uninstalling $INSTALL_PATH..."
    rm -f $INSTALL_PATH
    echo "[#] Done."

    echo "[#] VPN uninstalled."
elif [ $1 == "up" ]; then
    echo "[#]--- Bringing up VPN ---[#]"
    echo "[Wireguard]"
    sudo wg-quick up $PROFILE

    PacketFilters set

    RoutingRules set

    vpn_status
elif [ $1 == "down" ]; then
    echo "[#--- Tearing down VPN ---#]"

    RoutingRules unset

    PacketFilters unset

    echo "[Wireguard]"
    sudo wg-quick down $PROFILE

    ip route flush cache

    echo "[#] Cleanup complete."
elif [ "$1" == "run" ]; then
    shift
    if [ -d "$CGROUP_PATH" ]; then
        exec cgexec -g net_cls:$CGROUP "$@"
    else
        exec "$@"
    fi
elif [ "$1" == "monitor" ]; then
    if ip link show $PROFILE >/dev/null 2>&1; then
        sudo nethogs $PROFILE
    else
        echo "[VPN] Interface $PROFILE is DOWN"
    fi
elif [ "$1" == "status" ]; then vpn_status
else
    echo "Usage: $0 {install|uninstall|up|down|run|status|monitor}"
fi
