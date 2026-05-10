# Linux
**Thanks to Lobato for figuring this out**

This is a new and provisory version of the linux client that split tunnels steam itself instead of the games. It is kind of inconvenient, but until I figure out how to properly split tunnel the game's processes it is this or nothing.

If someone more knowledgeable on linux networking wants to help with developing game split-tunneling this is the current implementation: [linux_client_template.sh](https://github.com/LobatoLobato/terraform-bepene/blob/linux-client-game-tunneling/keys/linux_client_template.sh)

## Installation
### Dependencies: 
These are the packages needed for the script, you should look for your distro's way of installing them.

`{steam|flatpak steam} wg`

https://wiki.archlinux.org/title/Steam  
https://flathub.org/en/apps/com.valvesoftware.Steam  
https://command-not-found.com/wg  
https://command-not-found.com/ip

### Testing the script on your machine:
This script was developed on manjaro so maybe something specific to your distro can prevent it from working.  

To test if everything is ok run `${playername}.sh test {native|flatpak} -v`  
Then, when prompted input any game's executable you want to use for the test, e.g., GGST-Win64-Shipping.exe. Skip cloud sync and shader compilation when prompted by steam itself.
- If all the tests pass go to the next step, else contact #lobato4539 on discord with screenshots of the test results for troubleshooting support.

### The installation itself:
Run `${playername}.sh install` and the client will be available globally as `skel0vpn`.  
- It is recommended to keep `${playername}.sh` or your credentials stored somewhere in case there's an update to the script later.

### Updating:
Download the file in https://github.com/skel-zero/terraform-bepene/blob/main/keys/linux_client_template.sh or copy it to your current `${playername}.sh`  
Replace `$TEMPLATE_*` with your credentials and run:  
`${script}.sh uninstall --keep_config`  
`${script}.sh install`

## Usage
> ## **IMPORTANT!: You need to configure your steam client to disallow downloads during gameplay.**
> **Go to Steam>Settings>Downloads and make sure `Allow downloads during gameplay` is unchecked.**

**First add your game to the rule list with `skel0vpn rule add <alias> <exe>`**  
Ex: `skel0vpn rule add "GGST" "GGST-Win64-Shipping.exe"`

**Then run `skel0vpn native` or `skel0vpn flatpak` depending on which steam you want to launch inside the vpn.**  
This will launch steam inside a network namespace with no connection to the internet to prevent game download/update traffic from bankrupting skel0.

**Now, in the steam client, open any game you added to the rule list.**  
The vpn client will detect that game and enable the internet connection inside the network namespace as long as the game is running, when you close the game the connection will go down again.

#### **Note: Since game downloads and updates are disabled via the vpn client, please use the standard Steam client to download or update the games you want to run inside the vpn. There's a plan to implement interface switching to solve this.**

### Commands:
- `skel0vpn native`: Runs native steam inside the vpn.
- `skel0vpn flatpak`: Runs flatpak steam inside the vpn.
- `skel0vpn rule`: Manages the vpn's game rule list.
  - `add <alias> <exe>`: Adds a game's executable under an alias to the list.
  - `del <alias>`: Deletes a rule from the list.
  - `list`: Lists the configured rules.
- `${playername}.sh install`: Installs the script to /usr/local/bin and its configuration files to /etc/skel0vpn.  
  This command is only available from `${playername}.sh`.
- `skel0vpn uninstall`: Uninstalls the script and its configuration files.
- `${playername}.sh test <native|flatpak>`: Tests the script's functionality.  
  This command is only available from `${playername}.sh`. It accepts a verbosity flag: {-v|-vv}

## How it works:
When `skel0vpn {native|flatpak}` is ran the client:
1. Creates a network namespace and a downed wireguard vpn interface inside it.
2. Runs steam, native or flatpak, in the namespace and waits for a game in the rule list to open.
3. When a process matching a rule's exe is detected, the vpn interface goes up and enables internet connection within the network namespace, e.g, enabling traffic for both steam and the game.
4. When the game exits the vpn interface goes down again and the client goes back to step 3.
5. If steam is closed the client deletes the network namespace and exits. Moreover, if the client exits, (e.g, via Ctrl+C) while steam is still open, it will force steam to close before deleting the namespace.
