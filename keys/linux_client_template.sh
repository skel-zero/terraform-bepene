#!/bin/bash
ADDRESS="$TEMPLATE_ADDRESS";
PRIVATE_KEY="$TEMPLATE_PRIVATE_KEY";
PUBLIC_KEY="$TEMPLATE_PUBLIC_KEY";
ENDPOINT="$TEMPLATE_ENDPOINT";

# If you dont know what is going on don't mess with these variables
PROFILE="skel0vpn_st";
NETNS="vpn";
MTU=1420
SCRIPT_PATH="$(realpath "$0")";
INSTALL_PATH="/usr/local/bin/skel0vpn";
SCRIPT_CONFIG_PATH=/etc/skel0vpn;
RULES_FILE_PATH="$SCRIPT_CONFIG_PATH/rules";
WIREGUARD_CONF_PATH="$SCRIPT_CONFIG_PATH/$PROFILE.conf";

USER_NAME="$SUDO_USER"; [ -z "$USER_NAME" ] && USER_NAME="$USER";
USER_ID="$(id -u "$USER_NAME")";
USER_ENV=$(export | grep -vE "SUDO_|LS_COLORS|SSH_" | sed 's/^declare -x //' | sed 's/^export //');

INSTALLED=0; #INSTALLED Flag

COMMANDS="native|flatpak|install|uninstall|rule|test|help";
[ $INSTALLED -eq 1 ] && COMMANDS="native|flatpak|endpoint|rule|uninstall|help";

COMMAND="$1";
STEAM_TYPE="$1"; [ "$COMMAND" == "test" ] && STEAM_TYPE="$2";
VERBOSITY="$2"; [ "$COMMAND" == "test" ] && VERBOSITY="$3";
case "$VERBOSITY" in
"-vv") VERBOSE=2;;
"-v")  VERBOSE=1;;
*)     VERBOSE=0;;
esac


# Missing command check
if [[ -z "$COMMAND" ]] || ! grep -qs "$COMMAND" <<< "$COMMANDS" || [[ "$COMMAND" == "test" && "$INSTALLED" -eq 1 ]]; then
    echo "Usage: $0 {$COMMANDS}";
    exit 1;
elif [[ "$COMMAND" == "help" ]]; then
    echo "Usage: $0 {$COMMANDS}";
    echo "  $0 native - Runs native steam inside the vpn.";
    echo "  $0 flatpak - Runs flatpak steam inside the vpn.";
    echo "  $0 install - Installs the script.";
    echo "  $0 uninstall - Uninstalls the script and all rules and configurations.";
    echo "  $0 rule - Split tunneling rules configuration.";
    echo "          add <alias> <exe> - Adds a rule targeting the game's executable.";
    echo "          del <alias> - Removes a rule.";
    echo "          list - Lists all rules";
    [ "$INSTALLED" -eq 1 ] && exit 0;
    echo "  $0 test - Validates the script's logic and functionality in your machine, run this once before installing.";
    exit 0;
fi

# Elevate script
if [[ "$EUID" -ne 0 ]]; then exec sudo -s "$0" "$@"; fi
shift;

info() {
    echo "[#] $1";
}

trim_whitespace() {
    echo "$1" | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//' | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}';
}

indent() {
    local indent_size="$1";
    local padding=$(printf '%*s' "$indent_size" "");
    local input="$2";

    echo "${padding}${input//$'\n'/$'\n'$padding}";
}

wait_until() {
    local condition="$1";
    local timeout="$2";

    SECONDS=0;
    while ! eval "$condition" >/dev/null; do
        [[ -n "$timeout" && "$SECONDS" -gt "$timeout" ]] && return 1;
        sleep 0.1;
    done

    return 0;
}
wait_until_open_x() {
    wait_until "pgrep -x '$1'" "$2"; return $?;
}
wait_until_closed_x() {
    wait_until "! pgrep -x '$1'" "$2"; return $?;
}

wait_until_open_f() {
    wait_until "pgrep -f '$1'" "$2"; return $?;
}
wait_until_closed_f() {
    wait_until "! pgrep -f '$1'" "$2"; return $?;
}

steamctl() {
    steam_type="$1";
    local cmd="$2";
    shift 2;

    steam_run() {
        local run_in_netns; [ "$1" == "netns" ] && { run_in_netns="$1"; shift; };
        local command=(sudo -u "$USER_NAME" env "$USER_ENV" PULSE_SERVER="unix:/run/user/$USER_ID/pulse/native" dbus-run-session);
        [ -n "$run_in_netns" ] && command=(ip netns exec "$NETNS" "${command[@]}");
        [ "$steam_type" == "flatpak" ] && command=("${command[@]}" -- flatpak run com.valvesoftware.Steam);

        "${command[@]}" steam "$@";
    }

    case "$cmd" in
    run)       steam_run "$1" &>/dev/null;;
    shutdown)  steam_run -shutdown &>/dev/null; steam_run netns -shutdown &>/dev/null;;
    applaunch) steam_run netns -applaunch "$1" &>/dev/null;;
    is_running)
        local running_steam="$(pgrep -xa "steam")"; [ -z "$running_steam" ] && return 1;
        local is_flatpak=$(grep "com.valvesoftware.Steam" <<< "$running_steam");

        if [[ (-n "$is_flatpak" && "$steam_type" == "flatpak") || (-z "$is_flatpak" && "$steam_type" == "native") ]]; then
            return 0;
        fi

        return 1;
    ;;
    find_appid_from_exe)
        local exe="$1"
        local steam_root="/home/$USER_NAME/.local/share/Steam";
        [ "$steam_type" == "flatpak" ] && steam_root="/home/$USER_NAME/.var/app/com.valvesoftware.Steam/.local/share/Steam";

        local lib_vdf="$steam_root/steamapps/libraryfolders.vdf";
        if [ ! -f "$lib_vdf" ]; then
            echo "Error: libraryfolders.vdf not found.";
            return 1;
        fi

        grep -oP '"path"\s+"\K[^"]+' "$lib_vdf" | while read -r lib; do
            local search_dir="$lib/steamapps/common"; [[ ! -d "$search_dir" || ! -r "$search_dir" ]] && continue;

            local full_path=$(find "$lib/steamapps/common" -name "$exe" -print -quit); [ -z "$full_path" ] && continue;

            local target_folder=$(echo "$full_path" | sed -n "s|.*common/\([^/]*\)/.*|\1|p");
            [ -z "$target_folder" ] && target_folder=$(echo "$full_path" | awk -F'/common/' '{print $2}' | cut -d'/' -f1);

            for manifest in "$lib"/steamapps/appmanifest_*.acf; do
                if grep -qi "\"installdir\"[[:space:]]\+\"$target_folder\"" "$manifest"; then
                    local appid=$(echo "$manifest" | grep -oP 'appmanifest_\K[0-9]+');
                    echo "$appid";
                    return 0;
                fi
            done
        done

        return 1;
    ;;
    esac
}

vpnctl() {
    case "$1" in
    get_wireguard_conf)
        WIREGUARD_CONFIG="
            [Interface]
            PrivateKey = $PRIVATE_KEY

            [Peer]
            PublicKey = $PUBLIC_KEY
            AllowedIPs = 0.0.0.0/0, ::/0
            Endpoint = $ENDPOINT:443
            PersistentKeepalive = 25
        ";
        trim_whitespace "$WIREGUARD_CONFIG";
    ;;
    install_conf)
        info "Installing profile.";
        vpnctl get_wireguard_conf > "$WIREGUARD_CONF_PATH";
        info "Done.";
    ;;
    uninstall_conf)
        info "Uninstalling profile.";
        rm -f "$WIREGUARD_CONF_PATH";
        info "Done.";
    ;;
    create)
        ip netns add "$NETNS";

        ip link add wg0 type wireguard;
        wg setconf wg0 "$WIREGUARD_CONF_PATH";

        ip link set wg0 netns "$NETNS";
        ip link set dev wg0 mtu "$MTU";
        ip -n "$NETNS" addr add "$ADDRESS" dev wg0;

        ip netns exec "$NETNS" ip link set lo up;

        mkdir -p "/etc/netns/$NETNS";
        echo "nameserver 1.1.1.1" | tee "/etc/netns/$NETNS/resolv.conf" > /dev/null;
    ;;
    watch)
        local steam_type="$2";
        local rules=($(awk '{print $2}' "$RULES_FILE_PATH"));
        info "Waiting for $steam_type steam to open...";
        wait_until "steamctl '$steam_type' is_running";

        info "Waiting for a game to open...";
        while steamctl "$steam_type" is_running; do for rule in "${rules[@]}"; do
            game_pid="$(pgrep -f "^[A-Z]:.*\\$rule" | head -n 1)";
            game_rule="$rule";

            if [ -n "$game_pid" ]; then
                info "$game_rule($game_pid) is open, enabling traffic.";
                vpnctl up;

                info "Waiting for the game to close...";
                while [ -d "/proc/$game_pid" ]; do sleep 0.05; done

                info "$game_rule is closed, stopping traffic.";
                vpnctl down;

                info "Waiting for a game to open...";
                break;
            fi
        done; sleep 0.2; done
    ;;
    up)
        ip -n "$NETNS" link set wg0 up;
        ip -n "$NETNS" route add default dev wg0;
    ;;
    down)
        ip -n "$NETNS" link set wg0 down;
    ;;
    delete)
        ip netns del "$NETNS" 2>/dev/null;
    ;;
    esac
}

cleanup() {
    info "Shutting down $STEAM_TYPE steam..."
    steamctl "$STEAM_TYPE" shutdown
    info "Removing $NETNS namespace..."
    vpnctl delete
    info "Done."
}

case "$COMMAND" in
install)
    echo "[#--- Installing VPN ---#]";

    mkdir -p "$SCRIPT_CONFIG_PATH";

    if [ ! -f "$RULES_FILE_PATH" ]; then
        info "Creating rules file...";
        touch "$RULES_FILE_PATH";
    fi

    if [ ! -f "$WIREGUARD_CONF_PATH" ]; then
        vpnctl install_conf;
    fi

    echo "[#] Installing script to $INSTALL_PATH...";
    cp "$SCRIPT_PATH" "$INSTALL_PATH";
    sed -i '0,/INSTALLED=0/s//INSTALLED=1/' "$INSTALL_PATH"; # Set INSTALLED flag
    chmod +x "$INSTALL_PATH";

    echo "[#] Done.";
    echo "[#] VPN Installed.";
;;
uninstall)
    keep_config="$1"
    echo "[#--- Uninstalling VPN ---#]";

    if [[ -z "$keep_config" || "$keep_config" != "--keep_config" ]]; then
        info "Deleting rules file...";
        rm "$RULES_FILE_PATH";

        vpnctl uninstall_conf;

        rmdir "$SCRIPT_CONFIG_PATH";
    fi

    echo "[#] Uninstalling $INSTALL_PATH...";
    rm -f "$INSTALL_PATH";
    echo "[#] Done.";

    echo "[#] VPN uninstalled.";
;;
rule)
    rule_command="$1"; shift;
    case "$rule_command" in
    add)
        alias="$1";
        exe="$2";
        if [[ -n "$alias" && -n "$exe" ]]; then
            grep -v "$alias" "$RULES_FILE_PATH" > "${RULES_FILE_PATH}.tmp"; mv "${RULES_FILE_PATH}.tmp" "$RULES_FILE_PATH";
            grep -v "$exe" "$RULES_FILE_PATH" > "${RULES_FILE_PATH}.tmp"; mv "${RULES_FILE_PATH}.tmp" "$RULES_FILE_PATH";
            echo "$alias $exe" >> "$RULES_FILE_PATH";
            info "Added: $alias($exe)";
        else
          echo "Usage: $0 rule add <alias> <executable>";
        fi
    ;;
    del)
        alias="$1";

        if [[ -n "$alias" ]]; then
            grep -v -F "$alias" "$RULES_FILE_PATH" > "${RULES_FILE_PATH}.tmp"; mv "${RULES_FILE_PATH}.tmp" "$RULES_FILE_PATH";
            info "Removed: $alias";
        else
          echo "Usage: $0 rule del <alias>";
        fi
    ;;
    list)
        cat "$RULES_FILE_PATH";
    ;;
    *)
        echo "Usage: $0 {add <alias> <executable>|del <alias>|list}";
    ;;
    esac
;;
"native" | "flatpak")
    if steamctl "$STEAM_TYPE" is_running; then
        info "Rebooting $STEAM_TYPE steam into vpn mode...";
        steamctl "$STEAM_TYPE" shutdown;
        wait_until_closed_x "steam" 10; sleep 2;
    fi

    trap cleanup EXIT;

    info "Creating net namespace and vpn interface...";
    vpnctl create;

    info "Starting steam and watching...";
    steamctl "$STEAM_TYPE" run netns > /dev/nullecho 2>&1 & vpnctl watch "$STEAM_TYPE";

    info "Steam was closed. Deleting net namespace...";
    vpnctl delete;

    trap - EXIT;
    info "Done.";
;;
esac
# ----------------------------------- TESTS ----------------------------------- #
[ "$COMMAND" != "test" ] && exit 0

FULL_TEST_RUN_OK=1;

test_echo() {
    [ "$VERBOSE" -lt 1 ] && return 0;
    indentation=0; [ -n "$2" ] && indentation="$2";
    color="90"; [ -n "$3" ] && color="$3";

    while IFS= read -r line; do
        echo -e "[#]  $(indent "$indentation" "\e[${color}m$line\e[0m")";
    done <<< "$1";
}

test_echo_ok() {
    test_echo "$1" "${var:-0}" "32";
}
test_echo_fail() {
    test_echo "$1" "${var:-0}" "31";
    TEST_OK=0;
}

test_run_command() {
    if [ -n "$1" ]; then
        local command_output="$("$@" | sed 's/^\[#\][[:space:]]*//' | sed 's/^/[#]   /')"
        [ "$VERBOSE" -eq 2 ] && echo "$command_output";
    fi
}

test_suite() {
    local type="$1";
    local name="$2";
    local no_run=1; [[ -n "$3" && "$3" == "no_run" ]] && no_run=0;

    echo -e "[#]\e[34m[Test:$type:$name]\e[0m:";
    [ $no_run -eq 0 ] && return 0;

    [ "$type" == "command" ] && test_run_command "$SCRIPT_PATH" "$name";
}

test_suite_end() {
    echo -e "[#]\e[34m[Test:end]\e[0m: \e[32mOK\e[0m";
}

test_case_begin() {
    TEST_NAME="$1";
    TEST_OK=1;
    [ "$VERBOSE" -gt 0 ] && echo -e "[#] \e[33m[case:begin:$TEST_NAME]\e[0m:";
}

test_assert() {
    local name="$1";
    local expression="$2";
    expression_output=$(eval "$expression");
    expression_result=$?;
    shift 2;


    if [ "$expression_result" -ne 0 ]; then
        TEST_OK=0;
        FULL_TEST_RUN_OK=0;

        if [ "$VERBOSE" -gt 0 ]; then
            local lines=("$@" "$(indent 2 "$expression_output")");

            echo -e "[#]  \e[93m[:$name]\e[0m: \e[31mFailed\e[0m";
            for line in "${lines[@]}"; do
                test_echo_fail "$line" 3;
            done
        fi
    elif [ "$VERBOSE" -gt 0 ]; then
        echo -e "[#]  \e[93m[:$name]\e[0m: \e[32mOK\e[0m";
    fi
}
test_assert_str_eq_file() {
    local name="$1";
    local actual_val="$2";
    local file_path="$3";
    shift 3;

    diff_cmd='diff --old-line-format="Line %dn: --- %L" --new-line-format="Line %dn: +++ %L" --unchanged-line-format=""';
    test_assert "$name" "$diff_cmd "<(echo "$actual_val")" \"$file_path\"" "$@";
}

test_case_end() {
    if [[ "$VERBOSE" -gt 0  && $TEST_OK -eq 1 ]]; then
         echo -e "[#] \e[33m[case:end]\e[0m: \e[32mOK\e[0m";
    elif [[ "$VERBOSE" -gt 0 ]]; then
        echo -e "[#] \e[33m[case:end]\e[0m: \e[31mFailed\e[0m";
    fi
    TEST_NAME="";
    TEST_OK=1;
}


# ----------------------------- TEST BEGIN ----------------------------- #
read -r -p "[#]  Please enter a game's executable(game.exe || game) to be used on the test: " TEST_EXE
TEST_APPID="$(steamctl "$STEAM_TYPE" find_appid_from_exe "$TEST_EXE")";
if [ -z "$TEST_APPID" ]; then
  test_echo_fail "Could not find appid of $TEST_EXE. Check if the spelling is correct."
  exit 1;
fi

# Prevent user's rules from being lost during test
RULES_BACKUP_FILE=$(mktemp);
if [[ -f "$RULES_FILE_PATH" ]]; then
    cat "$RULES_FILE_PATH" > "$RULES_BACKUP_FILE";
    trap 'mkdir -p "$SCRIPT_CONFIG_PATH" && cat "$RULES_BACKUP_FILE" > "$RULES_FILE_PATH"' EXIT;
fi

test_suite command uninstall;
    test_case_begin "Configuration files removal";
        test_assert 'Rules file removed' "[ ! -f \"$RULES_FILE_PATH\" ]" \
                    "$RULES_FILE_PATH was not removed.";
        test_assert 'Wireguard config removed' "[ ! -f \"$WIREGUARD_CONF_PATH\" ]" \
                    "$WIREGUARD_CONF_PATH was not removed.";
        test_assert 'Script config folder removed' "[ ! -d \"$SCRIPT_CONFIG_PATH\" ]" \
                    "$SCRIPT_CONFIG_PATH was not removed.";
    test_case_end;

    test_case_begin "Script bin removal";
        test_assert 'Script bin file removed' "[ ! -f \"$INSTALL_PATH\" ]" \
                    "$INSTALL_PATH was not removed.";
    test_case_end;
test_suite_end;

test_suite command install;
    test_case_begin "Configuration files installation";
        test_assert 'Script config folder created' "[ -d \"$SCRIPT_CONFIG_PATH\" ]" \
                    "$SCRIPT_CONFIG_PATH is missing.";
        test_assert 'Rules file created' "[ -f \"$RULES_FILE_PATH\" ]" \
                    "$RULES_FILE_PATH is missing.";
        test_assert 'Wireguard config installed' "[ -f \"$WIREGUARD_CONF_PATH\" ]" \
                    "$WIREGUARD_CONF_PATH is missing.";
        test_assert_str_eq_file 'Wireguard config matches template' "$(vpnctl get_wireguard_conf)" "$WIREGUARD_CONF_PATH" \
            "Wireguard config in $WIREGUARD_CONF_PATH does not match template.";
    test_case_end;

    test_case_begin "Script bin installation";
        test_assert 'Script bin installed' "[ -f \"$INSTALL_PATH\" ]" \
                    "$INSTALL_PATH is missing.";
        test_assert_str_eq_file 'Script bin matches original script file' "$(sed '0,/INSTALLED=0/s//INSTALLED=1/' "$SCRIPT_PATH")" "$INSTALL_PATH" \
            "File in $INSTALL_PATH does not match the original script file in $SCRIPT_PATH.";
    test_case_end;
test_suite_end;

test_suite command rule no_run;
    test_case_begin "Add rule";
        # Can add multiple rules
        test_run_command "$SCRIPT_PATH" rule add alias1 exe1;
        test_run_command "$SCRIPT_PATH" rule add alias2 exe2;
        test_run_command "$SCRIPT_PATH" rule add alias3 exe3;
        test_assert_str_eq_file 'Can add multiple rules to the list' $'alias1 exe1\nalias2 exe2\nalias3 exe3' "$RULES_FILE_PATH" \
            "Could not find entry 'alias1 exe1' in rule list.";
        # Rule is overwritten when duplicate alias or executable is added
        test_run_command "$SCRIPT_PATH" rule add alias1 exe4;
        test_run_command "$SCRIPT_PATH" rule add alias4 exe2;
        test_assert_str_eq_file 'Overwrites rules when adding duplicate aliases/executables to the list' \
            $'alias3 exe3\nalias1 exe4\nalias4 exe2' "$RULES_FILE_PATH" \
            "Could not find entry 'alias1 exe1' in rule list.";
    test_case_end;

    test_case_begin "Del rule";
        test_run_command "$SCRIPT_PATH" rule del alias1
        test_assert_str_eq_file 'Can delete a rule from the list by its alias' \
            $'alias3 exe3\nalias4 exe2' "$RULES_FILE_PATH" \
            "Entry 'alias1 ***' remained on the list.";

        test_run_command "$SCRIPT_PATH" rule del alias3
        test_run_command "$SCRIPT_PATH" rule del alias4
        test_assert 'Can delete rules from the list until empty' \
            "[ ! -s \"$RULES_FILE_PATH\" ]" \
            "List was not emptied";
    test_case_end;
test_suite_end;

if [ "$FULL_TEST_RUN_OK" -eq 0 ]; then
    echo -e "[#]\e[31mTest run result: Failed before main test. Stopping...\e[0m";
    exit 1;
fi

test_suite command "$STEAM_TYPE" no_run
    test_run_command "$SCRIPT_PATH" rule add alias "$TEST_EXE"
    test_case_begin 'Steam rebooting/Starting, Net Namespace & VPN creation'
        if ! steamctl "$STEAM_TYPE" is_running; then
            test_echo "Opening steam in main net namespace"
            steamctl "$STEAM_TYPE" run &>/dev/null &
            sleep 15;
        fi
        wait_until_open_x "steam" 10

        test_echo "Steam in main net namespace is opened. Running $SCRIPT_PATH $STEAM_TYPE";
        test_run_command "$SCRIPT_PATH" "$STEAM_TYPE" &
        echo $'\r'

        test_assert 'Can reboot steam into "vpn mode"' "wait_until_closed_x 'steam' 10 && wait_until_open_x 'steam' 10" \
                    "Timed out while waiting for steam to close"
        test_assert 'Creates Net Namespace' "grep 'vpn' <<< '$(ip netns)'" \
                    "'vpn' netns not found";
        test_assert 'Creates VPN Interface' "ip netns exec vpn ip link | grep 'wg0'" \
                    "'wg0' interface not found";
        test_assert 'VPN Interface is down when a rule is not detected' "ip netns exec vpn ip link | grep 'wg0' | grep 'state DOWN'" \
                    "'wg0' Interface is up";
    test_case_end;

    test_case_begin 'Steam handling and rule monitoring'
        test_assert 'Can open steam' "pgrep -x 'steam'" \
                    "Steam is not running";

        test_assert 'Steam opens inside net namespace' "[[ \"$(ip netns identify "$(pgrep -xo "steam")")\" == \"vpn\" ]]" \
                    "Steam is running outside of the net namespace";

        echo "[#]  Launching $TEST_EXE... Please press 'Play Anyway' on the cloud sync prompt and skip shader compilation."
        steamctl "$STEAM_TYPE" applaunch "$TEST_APPID";


        test_echo "Waiting for the game to start...";
        while [ -z "$game_pid" ]; do
            game_pid="$(pgrep -f "^[A-Z]:.*\\$TEST_EXE" | head -n 1)"; sleep 0.2;
        done; sleep 5;

        test_assert 'VPN interface goes up when a rule is detected' "ip netns exec vpn ip link | grep 'wg0' | grep -v 'state DOWN'" \
            "VPN interface remained down";

        test_echo "Killing game process...";
        kill "$game_pid"; sleep 1;

        test_assert 'VPN interface goes down when a rule is not being detected anymore' "ip netns exec vpn ip link | grep 'wg0' | grep 'state DOWN'" \
            "VPN interface remained up";

        steamctl "$STEAM_TYPE" shutdown
        wait_until_closed_x "steam" && sleep 1;
        test_assert 'Net namespace is deleted when steam is shutdown' "! grep 'vpn' <<< '$(ip netns)'" \
            "Net namespace was not deleted";
    test_case_end
test_suite_end

if [ "$FULL_TEST_RUN_OK" -eq 1 ]; then
    echo -e "[#]\e[32mTest run result: OK\e[0m"
else
    echo -e "[#]\e[31mTest run result: Failed\e[0m"
fi
