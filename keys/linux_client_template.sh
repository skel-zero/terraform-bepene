#!/bin/bash
ADDRESS="$TEMPLATE_ADDRESS"
PRIVATE_KEY="$TEMPLATE_PRIVATE_KEY"
PUBLIC_KEY="$TEMPLATE_PUBLIC_KEY"
ENDPOINT="$TEMPLATE_ENDPOINT"

# If you dont know what is going on don't mess with these variables
MTU="1420"
MSS=$(($MTU - 40)) # (MTU - 40) works
CGROUP="skel0vpn"
CGROUP_PATH="/sys/fs/cgroup/net_cls/$CGROUP"
CLASSID="0x10001"
PROFILE="fg"
MARK="11"
TABLE="1221"
SCRIPT_PATH=$(realpath "$0")
INSTALL_PATH=/usr/local/bin/skel0vpn
ENDPOINT_IP=$(ping -c 1 $ENDPOINT | awk -F '[()]' '/PING/ {print $2}')

WIREGUARD_CONFIG_PATH=/etc/wireguard/$PROFILE.conf

CGROUP_SERVICE_ID="$CGROUP-cgroup-init.service"
CGROUP_SERVICE_PATH="/etc/systemd/system/$CGROUP_SERVICE_ID"

if [ -z "$1" ]; then
    echo "Usage: $0 {install|uninstall|up|down|run|status|monitor|test}"
    exit 0
fi

# Elevate script
if [ "$EUID" -ne 0 ] && [ "$1" != "run" ]; then
   if [ -n "${DBG+x}" ] && [ $DBG == 1 ]; then
       exec sudo -E "$0" "$@"
   else
       exec sudo "$0" "$@"
   fi
fi

trim_whitespace() {
    echo "$1" | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//'
}

WireguardConfig() {
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

    if [ "$1" == "get" ]; then
        trim_whitespace "$WIREGUARD_CONFIG"
        exit
    fi

    echo "[Wireguard]:"
    if [ "$1" == "install" ]; then
        echo "[#] Installing profile."
        trim_whitespace "$WIREGUARD_CONFIG" > $WIREGUARD_CONFIG_PATH
        echo "[#] Done."
    elif [ "$1" == "uninstall" ]; then
        echo "[#] Uninstalling profile."
        rm -f $WIREGUARD_CONFIG_PATH
        echo "[#] Done."
    fi
}
CGroupInitService() {
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
        ExecStart=/usr/bin/cgcreate -a $SUDO_USER:$SUDO_USER -t $SUDO_USER:$SUDO_USER -g net_cls:skel0vpn
        ExecStart=/usr/bin/sh -c 'echo $CLASSID | /usr/bin/tee $CGROUP_PATH/net_cls.classid'

        [Install]
        WantedBy=multi-user.target
    "

    if [ "$1" == "get" ]; then
      trim_whitespace "$CGROUP_SERVICE"
      exit
    fi

    echo "[CGroup]:"
    if [ "$1" == "install" ]; then
        echo "[#]  Installing $CGROUP_SERVICE_ID..."
        trim_whitespace "$CGROUP_SERVICE" > $CGROUP_SERVICE_PATH

        echo "[#]  Enabling service..."
        systemctl daemon-reload

        enable_result=$(trim_whitespace "$(systemctl enable $CGROUP_SERVICE_ID 2>&1)")

        if [ "$enable_result" == "" ]; then
            systemctl restart $CGROUP_SERVICE_ID
        else
            echo "[#]  $enable_result"
            systemctl start $CGROUP_SERVICE_ID
        fi

        echo "[#]  Done."
    elif [ "$1" == "uninstall" ]; then
        echo "[#] Removing $CGROUP_SERVICE_ID..."
        systemctl stop $CGROUP_SERVICE_ID 2>/dev/null
        systemctl disable $CGROUP_SERVICE_ID 2>/dev/null
        rm -f $CGROUP_SERVICE_PATH
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

        # Set MSS limit to stop packets from being dropped
        echo "[#] Setting tcp MSS limiter..."
        iptables -t mangle -I OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS

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
    echo "[Routing Rules]:"
    if [ "$1" == "set" ]; then
        # Packets with mark will go through the configured table
        echo "[#] Packet Rule: route marked packets to table $TABLE..."
        ip rule add fwmark $MARK priority 500 table $TABLE
        # Route vpn server's ip to main so it doesnt get routed to itself
        echo "[#] Packet Rule: route packets destined to the vpn server's endpoint through the main interface."
        ip rule add to $ENDPOINT_IP priority 400 table main
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
        ip rule del to $ENDPOINT_IP priority 400 2>/dev/null

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

    echo "[#] Tearing down the vpn"
    skel0vpn down

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
        echo "[skel0vpn]: running program inside of cgroup"
        exec cgexec -g net_cls:$CGROUP "$@"
    else
        echo "[skel0vpn]: running program outside of cgroup"
        exec "$@"
    fi
elif [ "$1" == "monitor" ]; then
    if ip link show $PROFILE >/dev/null 2>&1; then
        sudo nethogs $PROFILE
    else
        echo "[VPN] Interface $PROFILE is DOWN"
    fi
elif [ "$1" == "status" ]; then
    vpn_status
fi


#=================================== TESTS ===================================#
test_echo_ok() {
    INDENT=0; if [ ! -z $2 ]; then INDENT=$2; fi
    while IFS= read -r linha; do
        echo -e "[#] $(printf "%*s%s\n" "$INDENT" "" "\e[32m$linha\e[0m")"
    done <<< "$1"


}
test_echo_fail() {
    INDENT=0; if [ ! -z $2 ]; then INDENT=$2; fi

    while IFS= read -r linha; do
        echo -e "[#] $(printf "%*s%s\n" "$INDENT" "" "\e[31m$linha\e[0m")"
    done <<< "$1"

}

check_owner() {
    [[ -z $(find "$1" \( ! -user "$2" -o ! -group "$3" \) -print -quit) ]]
}
to_int() {
    printf '%ld' $1
}
to_uint() {
    printf '%lu' $1
}
to_hex() {
    printf '0x%x' $1
}
int_cmp() {
    n1=$(to_int $1)
    n2=$(to_int $2)

    if [ "$n1" -gt "$n2" ]; then
      return 1
    elif [ "$n2" -gt "$n1" ]; then
      return 2
    else
      return 0
    fi
}
uint_cmp() {
    n1=$(to_uint $1)
    n2=$(to_uint $2)

    if [ "$n1" -gt "$n2" ]; then
      return 1
    elif [ "$n2" -gt "$n1" ]; then
      return 2
    else
      return 0
    fi
}

test_install() {
    verbose=$1
    if [ -f "$INSTALL_PATH" ]; then
        $SCRIPT_PATH uninstall &>/dev/null
    fi

    echo -e "[#]\e[34m[Test:command:install]\e[0m:"
    if [ $verbose -eq 2 ]; then
        echo "[#][Command Output:]"
        $SCRIPT_PATH install 2>&1
    else
        $SCRIPT_PATH install &>/dev/null
    fi

    # Wireguard config
    if [ ! -f "$WIREGUARD_CONFIG_PATH" ]; then
        test_echo_fail "Wireguard profile installation: FAILED"
        test_echo_fail "  MISSING $WIREGUARD_CONFIG_PATH FILE"
    elif diff -qB "$WIREGUARD_CONFIG_PATH" <(WireguardConfig get) >/dev/null; then
        test_echo_ok "Wireguard profile installation: OK"
    else
        test_echo_fail "Wireguard profile installation: FAILED"
        test_echo_fail "  FILE IN $WIREGUARD_CONFIG_PATH DOES NOT MATCH TEMPLATE"
        if [ $verbose -gt 0 ]; then
            diff -B "$WIREGUARD_CONFIG_PATH" <(WireguardConfig get)
        fi
    fi

    # CGroup creation and configuration service
    if [ ! -f "$CGROUP_SERVICE_PATH" ]; then
        test_echo_fail "CGroup configuration and creation service setup: FAILED"
        test_echo_fail "  $CGROUP_SERVICE_ID is missing from /etc/systemd/system/"
    elif ! diff -qB "$CGROUP_SERVICE_PATH" <(CGroupInitService get) >/dev/null; then
        test_echo_fail "CGroup configuration and creation service setup: FAILED"
        test_echo_fail "  FILE IN $CGROUP_SERVICE_PATH DOES NOT MATCH TEMPLATE"
        if [ $verbose -gt 0 ]; then
            diff -B "$CGROUP_SERVICE_PATH" <(CGroupInitService get)
        fi
    elif ! systemctl is-enabled -q $CGROUP_SERVICE_ID; then
        test_echo_fail "CGroup configuration and creation service setup: FAILED"
        test_echo_fail "  $CGROUP_SERVICE_ID is not enabled"
        test_echo_fail "  try running 'journalctl -u $CGROUP_SERVICE_ID -xe' to see what is wrong"
    elif ! systemctl is-active -q $CGROUP_SERVICE_ID; then
        test_echo_fail "CGroup configuration and creation service setup: FAILED"
        test_echo_fail "  $CGROUP_SERVICE_ID has not been started successfully"
        test_echo_fail "  try running 'journalctl -u $CGROUP_SERVICE_ID -xe' to see what is wrong"
        test_echo_fail "  this failure may be related to failures on the tests below, fixing them will probably fix this"
    else
        test_echo_ok "CGroup configuration and creation service setup: OK"
    fi

    # CGroup creation and configuration
    conf_classid=$(cat $CGROUP_PATH/net_cls.classid)
    if [ ! -d "/sys/fs/cgroup/net_cls" ]; then
        test_echo_fail "CGroup configuration and creation: FAILED"
        test_echo_fail "  net_cls cgroup is not mounted, probably because the directory was not created"
        test_echo_fail "  try running systemctl status $CGROUP-cgroup-init.service to see what went wrong"
    elif ! /usr/bin/mountpoint -q /sys/fs/cgroup/net_cls; then
        test_echo_fail "CGroup configuration and creation: FAILED"
        test_echo_fail "  net_cls group is not mounted"
        test_echo_fail "  try running systemctl status $CGROUP-cgroup-init.service to see what went wrong"
    elif ! check_owner "$CGROUP_PATH" $SUDO_USER $SUDO_USER; then
        test_echo_fail "CGroup configuration and creation: FAILED"
        test_echo_fail "  some or all file/dir gid:pid in $CGROUP_PATH are wrong"
        test_echo_fail "  they should all be owned by $SUDO_USER:$SUDO_USER"
        if [ $verbose -gt 0 ]; then
            test_echo_fail "$(ls -lR "$CGROUP_PATH")"
        fi
    elif ! uint_cmp $conf_classid $CLASSID; then
        test_echo_fail "CGroup configuration and creation: FAILED"
        test_echo_fail "  $CGROUP cgroup's classid is wrong"
        test_echo_fail "    Got: $(to_hex $conf_classid) | $(to_uint $conf_classid)"
        test_echo_fail "    Expected: $(to_hex $CLASSID) | $(to_uint $CLASSID)"
    else
      test_echo_ok "CGroup configuration and creation: OK"
    fi

    # Script installation
    if [ ! -f "$INSTALL_PATH" ]; then
        test_echo_fail "Script installation: FAILED"
        test_echo_fail "  MISSING $INSTALL_PATH FILE"
    elif [ -f "$SCRIPT_PATH" ] && ! diff -qB "$INSTALL_PATH" "$SCRIPT_PATH" >/dev/null; then
        test_echo_fail "Script installation: FAILED"
        test_echo_fail "  FILE IN $INSTALL_PATH DOES NOT MATCH THE ORIGINAL SCRIPT FILE IN $SCRIPT_PATH"
        if [ $verbose -gt 0 ]; then
            diff -qB "$INSTALL_PATH" "$SCRIPT_PATH"
        fi
    elif [ ! -x "$INSTALL_PATH" ]; then
        test_echo_fail "Script installation: FAILED"
        test_echo_fail "  $INSTALL_PATH is not executable, file permissions are wrong"
    else
        test_echo_ok "Script installation: OK"
    fi
}
test_uninstall() {
    verbose=$1

    echo -e "[#]\e[34m[Test:command:uninstall]\e[0m:"
    if [ $verbose -eq 2 ]; then
        echo "[#][Command Output:]"
        $SCRIPT_PATH uninstall 2>&1
    else
        $SCRIPT_PATH uninstall &>/dev/null
    fi

    # VPN tear down
    if wg show $PROFILE &>/dev/null; then
        test_echo_fail "VPN tear down: FAILED"
        test_echo_fail "  VPN is still up."
    else
        test_echo_ok "VPN tear down: OK"
    fi

    # Wireguard config removal
    if [ -f "$WIREGUARD_CONFIG_PATH" ]; then
        test_echo_fail "Wireguard config removal: FAILED"
        test_echo_fail "  $PROFILE.conf file is still present in $WIREGUARD_CONFIG_PATH."
    else
        test_echo_ok "Wireguard config removal: OK"
    fi

    # CGroup creation and configuration service removal
    if systemctl is-active -q $CGROUP_SERVICE_ID; then
        test_echo_fail "CGroup configuration and creation service removal: FAILED"
        test_echo_fail "  $CGROUP_SERVICE_ID didn't stop."
    elif systemctl is-enabled -q $CGROUP_SERVICE_ID; then
        test_echo_fail "CGroup configuration and creation service removal: FAILED"
        test_echo_fail "  $CGROUP_SERVICE_ID is still enabled."
    elif [ -f "$CGROUP_SERVICE_PATH" ]; then
        test_echo_fail "CGroup configuration and creation service removal: FAILED"
        test_echo_fail "  $CGROUP_SERVICE_PATH was not removed."
    else
        test_echo_ok "CGroup configuration and creation service removal: OK"
    fi

    # Cgroup deletion
    if [ -d "$CGROUP_PATH" ]; then
        test_echo_fail "CGroup deletion: FAILED"
        test_echo_fail "  $CGROUP was not deleted, it is still present in $CGROUP_PATH"
    else
        test_echo_ok "CGroup deletion: OK"
    fi

    # Script removal
    if [ -f "$INSTALL_PATH" ]; then
        test_echo_fail "Script removal: FAILED"
        test_echo_fail "  skel0vpn is still present at $INSTALL_PATH"
    else
        test_echo_ok "Script removal: OK"
    fi
}

test_up() {
    verbose=$1

    echo -e "[#]\e[34m[Test:command:up]\e[0m:"
    if [ $verbose -eq 2 ]; then
        echo "[#][Command Output:]"
        $SCRIPT_PATH up 2>&1
    else
        $SCRIPT_PATH up &>/dev/null
    fi

    # VPN up check
    if ! wg show $PROFILE &>/dev/null; then
        test_echo_fail "VPN up: FAILED"
        test_echo_fail "  VPN is down."
    elif ! curl -q4 --interface $PROFILE ifconfig.me &>/dev/null; then
        test_echo_fail "VPN up: FAILED"
        test_echo_fail "  VPN is up but trying to retrieve the tunnel's ip failed."
        test_echo_fail "  test command was: curl -4 --interface $PROFILE ifconfig.me"
    else
        test_echo_ok "VPN up: OK"
    fi

    # Packet Filters
    mangle=$(iptables -t mangle -S)
    cgroup_filter_entry="-A OUTPUT -m cgroup --cgroup $(to_uint $CLASSID) -j MARK --set-xmark $(to_hex $MARK)/0xffffffff"
    tcp_mss_limiter_entry="-A OUTPUT -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS"
    nat_masquerade_entry="-A POSTROUTING -o $PROFILE -j MASQUERADE"

    if ! grep -q -- "$cgroup_filter_entry" <<< "$mangle"; then
        test_echo_fail "Packet Filters up (cgroup filter): FAILED"
        test_echo_fail "  missing cgroup entry in mangle table"
        test_echo_fail "  iptables -t mangle -S should list the entry bellow:"
        test_echo_fail "    $cgroup_filter_entry"
    else
        test_echo_ok "Packet Filters up (cgroup filter): OK"
    fi

    if ! grep -q -- "$tcp_mss_limiter_entry" <<< "$mangle"; then
        test_echo_fail "Packet Filters up (tcp mss limiter): FAILED"
        test_echo_fail "  missing tcp mss limiter entry in mangle table"
        test_echo_fail "  iptables -t mangle -S should list the entry bellow:"
        test_echo_fail "    $tcp_mss_limiter_entry"
    else
        test_echo_ok "Packet Filters up (tcp mss limiter): OK"
    fi

    if ! grep -q -- "$nat_masquerade_entry" <<< "$(iptables-save -t nat)"; then
        test_echo_fail "Packet Filters up (nat masquerade): FAILED"
        test_echo_fail "  missing nat masquerade entry in nat table"
        test_echo_fail "  iptables-save -t nat should list the entry bellow:"
        test_echo_fail "    $nat_masquerade_entry"
    else
        test_echo_ok "Packet Filters up (nat masquerade): OK"
    fi
    # Routing Rules
    ip_rules=$(ip rule show)
    marked_packets_to_table_rule_entry="from all fwmark $(to_hex $MARK) lookup $TABLE"
    table_to_interface_route_entry="default dev $PROFILE scope link"
    outgoing_vpn_packets_rule_entry="from all to $ENDPOINT_IP lookup main"

    if ! grep -q -- "$marked_packets_to_table_rule_entry" <<< "$ip_rules"; then
        test_echo_fail "Routing Rules up (router[marked packets -> table]): FAILED"
        test_echo_fail "  missing entry in ip rule list"
        test_echo_fail "  ip rule show should list the entry bellow:"
        test_echo_fail "    $marked_packets_to_table_rule_entry"
    else
        test_echo_ok "Routing Rules up (router[marked packets -> table]): OK"
    fi

    if ! grep -q -- "$outgoing_vpn_packets_rule_entry" <<< "$ip_rules"; then
        test_echo_fail "Routing Rules up (router[outgoing vpn packets -> main interface]): FAILED"
        test_echo_fail "  missing entry in ip rule list"
        test_echo_fail "  ip rule show should list the entry bellow:"
        test_echo_fail "    $outgoing_vpn_packets_rule_entry"
    else
        test_echo_ok "Routing Rules up (router[outgoing vpn packets -> main interface]): OK"
    fi

    if ! grep -q -- "$table_to_interface_route_entry" <<< "$(ip route show table $TABLE)"; then
        test_echo_fail "Routing Rules up (route[table -> vpn interface]): FAILED"
        test_echo_fail "  missing entry in ip route list"
        test_echo_fail "  ip route show table $TABLE should list the entry bellow:"
        test_echo_fail "    $table_to_interface_route_entry"
    else
        test_echo_ok "Routing Rules up (route[table -> vpn interface]): OK"
    fi

    # Connection test
    cgroup_ip=$(cgexec -g net_cls:$CGROUP curl -s4 ifconfig.me)
    tunnel_ip=$(curl -s4 --interface $PROFILE ifconfig.me)

    if [ "$cgroup_ip" != "$tunnel_ip" ]; then
        test_echo_fail "Connection to vpn from a process inside the cgroup: FAILED"
        test_echo_fail "  cgroup ip is different from the tunnel ip"
        test_echo_fail "  expected(tunnel): $tunnel_ip; got(cgroup): $cgroup_ip"
    else
        test_echo_ok "Connection to vpn from a process inside the cgroup: OK"
    fi
}
test_down() {
    verbose=$1

    echo -e "[#]\e[34m[Test:command:down]\e[0m:"
    if [ $verbose -eq 2 ]; then
        echo "[#][Command Output:]"
        $SCRIPT_PATH down 2>&1
    else
        $SCRIPT_PATH down &>/dev/null
    fi
    # VPN up check
    if wg show $PROFILE &>/dev/null; then
        test_echo_fail "VPN down: FAILED"
        test_echo_fail "  VPN is up."
    else
        test_echo_ok "VPN down: OK"
    fi

    # Packet Filters
    mangle=$(iptables -t mangle -S)
    cgroup_filter_entry="-A OUTPUT -m cgroup --cgroup $(to_uint $CLASSID) -j MARK --set-xmark $(to_hex $MARK)/0xffffffff"
    tcp_mss_limiter_entry="-A OUTPUT -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS"
    nat_masquerade_entry="-A POSTROUTING -o $PROFILE -j MASQUERADE"

    if grep -q -- "$cgroup_filter_entry" <<< "$mangle"; then
        test_echo_fail "Packet Filters down (cgroup filter): FAILED"
        test_echo_fail "  cgroup entry is still in the mangle table"
        test_echo_fail "  iptables -t mangle -S should not list the entry bellow:"
        test_echo_fail "    $cgroup_filter_entry"
    else
        test_echo_ok "Packet Filters down (cgroup filter): OK"
    fi

    if grep -q -- "$tcp_mss_limiter_entry" <<< "$mangle"; then
        test_echo_fail "Packet Filters down (tcp mss limiter): FAILED"
        test_echo_fail "  tcp mss limiter entry is still in the mangle table"
        test_echo_fail "  iptables -t mangle -S should not list the entry bellow:"
        test_echo_fail "    $tcp_mss_limiter_entry"
    else
        test_echo_ok "Packet Filters down (tcp mss limiter): OK"
    fi

    if grep -q -- "$nat_masquerade_entry" <<< "$(iptables-save -t nat)"; then
        test_echo_fail "Packet Filters down (nat masquerade): FAILED"
        test_echo_fail "  nat masquerade entry is still in the nat table"
        test_echo_fail "  iptables-save -t nat should not list the entry bellow:"
        test_echo_fail "    $nat_masquerade_entry"
    else
        test_echo_ok "Packet Filters down (nat masquerade): OK"
    fi
    # Routing Rules
    ip_rules=$(ip rule show)
    marked_packets_to_table_rule_entry="from all fwmark $(to_hex $MARK) lookup $TABLE"
    table_to_interface_route_entry="default dev $PROFILE scope link"
    outgoing_vpn_packets_rule_entry="from all to $ENDPOINT_IP lookup main"

    if grep -q -- "$marked_packets_to_table_rule_entry" <<< "$ip_rules"; then
        test_echo_fail "Routing Rules down (router[marked packets -> table]): FAILED"
        test_echo_fail "  entry is still in the ip rule list"
        test_echo_fail "  ip rule show should not list the entry bellow:"
        test_echo_fail "    $marked_packets_to_table_rule_entry"
    else
        test_echo_ok "Routing Rules down (router[marked packets -> table]): OK"
    fi

    if grep -q -- "$outgoing_vpn_packets_rule_entry" <<< "$ip_rules"; then
        test_echo_fail "Routing Rules down (router[outgoing vpn packets -> main interface]): FAILED"
        test_echo_fail "  entry is still in the ip rule list"
        test_echo_fail "  ip rule show should not list the entry bellow:"
        test_echo_fail "    $outgoing_vpn_packets_rule_entry"
    else
        test_echo_ok "Routing Rules down (router[outgoing vpn packets -> main interface]): OK"
    fi

    if grep -q -- "$table_to_interface_route_entry" <<< "$(ip route show table $TABLE)"; then
        test_echo_fail "Routing Rules down (route[table -> vpn interface]): FAILED"
        test_echo_fail "  entry is still in the ip route list"
        test_echo_fail "  ip route show table $TABLE should not list the entry bellow:"
        test_echo_fail "    $table_to_interface_route_entry"
    else
        test_echo_ok "Routing Rules down (route[table -> vpn interface]): OK"
    fi

    # Connection test
    main_itfc_ip=$(curl -s4 ifconfig.me)
    cgroup_ip=$(cgexec -g net_cls:$CGROUP curl -s4 ifconfig.me)

    if [ -z "$cgroup_ip" ]; then
      test_echo_fail "Connection from inside the cgroup goes through main interface: FAILED"
      test_echo_fail "  cgroup is not able to retrieve any IP from ifconfig.me"
    elif [ "$cgroup_ip" != "$main_itfc_ip" ]; then
        test_echo_fail "Connection from inside the cgroup goes through main interface: FAILED"
        test_echo_fail "  cgroup has a different ip from the main interface"
        test_echo_fail "  expected(main interface): $main_itfc_ip; got(cgroup): $cgroup_ip"
    else
        test_echo_ok "Connection from inside the cgroup goes through main interface: OK"
    fi
}
test_run() {
    verbose=$1
    echo -e "[#]\e[34m[Test:command:run]\e[0m:"

    # Verify that we can run the process inside the cgroup without sudo
    result=$(sudo -u $SUDO_USER $SCRIPT_PATH run echo "test_run" 2>&1)
    grep -q "running program inside of cgroup" <<< "$result"
    ran_inside_cgroup=$?
    grep -q "cgroup change of group failed" <<< "$result"
    change_of_group_failed=$?
    grep -q "test_run" <<< "$result"
    program_did_run=$?

    if [ ! -d "$CGROUP_PATH" ]; then
        test_echo_fail "Can run process inside the cgroup without being root: FAILED"
        test_echo_fail "  cgroup net_cls:$CGROUP does not exist, check if it was created at $CGROUP_PATH"
    elif [ ! -z "$result" ] && [ $ran_inside_cgroup -eq 0 ] && ([ $change_of_group_failed -eq 0 ] || [ $program_did_run -ne 0 ]); then
        test_echo_fail "Can run process inside the cgroup without being root: FAILED"
        test_echo_fail "  verify who owns $CGROUP_PATH, must be $SUDO_USER:$SUDO_USER"
        if [ $verbose -gt 0 ]; then
          test_echo_fail "$result"
        fi
    else
        test_echo_ok "Can run process inside the cgroup without being root: OK"
    fi

    # Verify that in the absence of the cgroup the command will still run the program
    if [ -d "$CGROUP_PATH" ]; then
        mv "$CGROUP_PATH" "$CGROUP_PATH\_TEST"
    fi

    result=$(sudo -u $SUDO_USER $SCRIPT_PATH run echo "test_run" 2>&1)
    grep -q "running program inside of cgroup" <<< "$result"
    ran_inside_cgroup=$?
    grep -q "running program outside of cgroup" <<< "$result"
    ran_outside_cgroup=$?
    grep -q "test_run" <<< "$result"
    program_did_run=$?

    if [ ! -z "$result" ] && [ $ran_outside_cgroup -ne 0 ] && [ $ran_inside_cgroup -eq 0 ]; then
        test_echo_fail "Can still run process when cgroup is absent: FAILED"
        test_echo_fail "  script branched to run the process inside the cgroup instead of outside."
        if [ $verbose -gt 0 ]; then
          test_echo_fail "$result" 4
        fi
    elif [ ! -z "$result" ] && [ $ran_outside_cgroup -eq 0 ] && [ $program_did_run -ne 0 ]; then
        test_echo_fail "Can still run process when cgroup is absent: FAILED"
        test_echo_fail "  script branched to run the process outside the cgroup, but there was no output."
        if [ $verbose -gt 0 ]; then
          test_echo_fail "  Command output:"
          test_echo_fail "$result" 4
        fi
    else
        test_echo_ok "Can still run process when cgroup is absent: OK"
    fi

    if [ -d "$CGROUP_PATH\_TEST" ]; then
        mv "$CGROUP_PATH\_TEST" "$CGROUP_PATH"
    fi
}

if [ "$1" == "test" ]; then
    test="$2"
    verbose=0
    if [ ! -z "$3" ] && [ "$3" = "-v" ]; then
        verbose=1
    elif [ ! -z "$3" ] && [ "$3" = "-vv" ]; then
        verbose=2
    fi

    if [ "$test" == "install" ]; then
        test_install $verbose
    elif [ "$test" == "uninstall" ]; then
        test_uninstall $verbose
    elif [ "$test" == "up" ]; then
        test_up $verbose
    elif [ "$test" == "down" ]; then
        test_down $verbose
    elif [ "$test" == "run" ]; then
        test_run $verbose
    elif [ "$test" == "all" ]; then
        if [ $verbose -eq 1 ]; then verbose_flag="-v";
        elif [ $verbose -eq 2 ]; then verbose_flag="-vv"; fi

        $SCRIPT_PATH test install $verbose_flag
        $SCRIPT_PATH test run $verbose_flag
        $SCRIPT_PATH test up $verbose_flag
        $SCRIPT_PATH test down $verbose_flag
        $SCRIPT_PATH test uninstall $verbose_flag
    fi
fi
