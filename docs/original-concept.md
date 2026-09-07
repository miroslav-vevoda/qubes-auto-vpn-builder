# Original concept (superseded)

This is the original design note this project started from, kept for
history. It predates the fixes and restructuring described in
[`../ARCHITECTURE.md`](../ARCHITECTURE.md) — several things here don't match
the shipped system (wrong firewall script path, IPv4-only rules, a shell
quoting bug, `netvm none` framed as a bug rather than the correct default).
Don't follow it directly; it's kept only so the reasoning in
`ARCHITECTURE.md` has something concrete to point back to.

---

Concept for automatic salt setup in Qubes 4.3 of vpn appvm and dispvm based on the appvm
--------------------
Claude AI Objective
-------------------
Create the salt configs, scripts and files I need. The files will be stored in a dedicated appvm called salt-configs-vm
Might be possible to use qubesctl with the --target option pointing to the salt-configs-vm where configs are stored, however only dom0 should determine where to get the vpn confs from (which will be for vpn-config-files-vm).

I do not want to put the vpn configs in the same vm as the salt configs and scripts. I need secure isolation between the two vms, both salt-configs-vm and vpn-config-files-vm. Only a dom0 command can determine the location of the vpn-config-files-vm.

Advise to me if this approach is correct or if there is a better one to use.




You can specify the following in a file inside the separate storage vm where the salt configs are stored (salt-configs-vm).
- choose wireguard or openvpn and MTU they want for virtual interfaces (e.g vif*)
- one whole config folder (iso country code) or a specfic server by using the first part (isocode-servernumber) from a different vm storing the configs. If you choose just iso country code - the server will be random

You specify to salt which template to use for a appvm.

-----------------------------------------------------------
START OF APPVM CREATION (WHICH THE DISP TEMPLATE IS BASED ON) SETUP
THE VPN APPVM WILL BE CALLED EITHER

SPECIFIC SERVER WILL BE nordvpn-uk123-vpn-dvm. derivied from the vpn config name, change dots for - between words. uk123.nordvpn.com.conf becomes nordvpn-uk123-vpn-dvm (nordvpn first)

COUNTRY ISO SELECTION WILL HAVEING A NAME SUCH AS nordvpn-uk-random-vpn-dvm

-----------------------------------------------------------
START OF NFTABLE RULES
--------------------

Inside the appvm put the following code into /rw/config/qubes/qubes-firewall-user-script one space down from the last line
If wireguard keep rules below the same, if openvpn replace "wireguard with "tun0"

```
# Clear previous rules from custom-forward to prevent duplicates.
nft flush chain ip qubes custom-forward

# 1. Automatically set MTU
nft add rule ip qubes custom-forward \
    tcp flags syn / syn,rst \
    tcp option maxseg size set rt mtu

# 2. Allow established/related connections first
nft add rule ip qubes custom-forward \
    ct state established,related accept

# 3. AppVMs -> WireGuard
nft add rule ip qubes custom-forward \
    iifgroup 2 oifname "wireguard" accept

# 4. WireGuard -> outside
nft add rule ip qubes custom-forward \
    iifname "wireguard" oifname "eth0" accept

# 5. Block AppVMs -> eth0
nft add rule ip qubes custom-forward \
    iifgroup 2 oifname "eth0" drop

# 6. Kill switch: block anything else -> eth0
nft add rule ip qubes custom-forward \
    oifname "eth0" drop
```

--------------------
END OF NFTABLE RULES
--------------------

-------------------------------------------------
START OF ADJUSTMENT SCRIPT FOR VIRTUAL INTERFACES
-------------------------------------------------
MTU adjustment for virtual interfaces

In the AppVM do the following

```
sudo mkdir -p /rw/config/network-hooks.d && sudo nano /rw/config/network-hooks.d/90-vif-mtu
```

Add the following

```
#!/bin/sh

command="$1"
vif="$2"

if [ "$command" = "online" ]; then
    case "$vif" in
        vif[0-9]*)
            ip link set dev "$vif" mtu $MTU
            ;;
    esac
fi
```

-------------------------------------------------
END OF ADJUSTMENT SCRIPT FOR VIRTUAL INTERFACES
-------------------------------------------------
-----------------------------------------------------------
END OF APPVM (WHICH THE DISP TEMPLATE IS BASED ON) SETUP
-----------------------------------------------------------
----------------------------
START OF DISPOSABLE SECTION
----------------------------
Salt makes this appvm a disposible template
The AppVM should not have network adaptor or connection (set to none)

Salt makes a disposible based on the disposible template of the appvm, with a name following either nord-isoname-theword"random" or  nord-isoname-servernumber (isoname-servernumber i.e first part uk123.nordvpn of conf name uk123.nordvpn.com.conf)

Salt makes network-manager and qubes-firewall services available only the disp

Salt allows the DispVM to be network for other VMs

---------------------------
END OF DISPOSABLE SECTION
---------------------------

------------------------------
START OF QVM-FIREWALL SECTION
------------------------------
endpoint ips found in the ISO country folder in a file called endpoint-map.txt, each line with the format "****.nordvpn.com.conf *.*.*.*:*port*"

$VPN_SERVER would be *.*.*.* and $VPN_PORT would be *port*

If user choose "random" (If you choose just iso country code as above) is selected all the endpoints inside the ISO folder are used and "qvm-firewall "$VM" add accept proto=udp dst4="$VPN_SERVER"" dstports="$VPN_PORT"" is applied for each endpoint. If a specific server is selected then only that endpoint is used

comprehensive qvm-firewall ruleset as follows

```
# Remove all gui added rules
qvm-firewall "$VM" reset

# Allow outgoing to vpn server
qvm-firewall "$VM" add accept proto=udp dst4="$VPN_SERVER"" dstports="$VPN_PORT"

# Delete first rule which allows everything
qvm-firewall "$VM" del --rule-no 0

# Add leak protection
qvm-firewall "$VM" add --before 0 drop proto=icmp
qvm-firewall "$VM" add --before 0 drop specialtarget=dns

# Block everything else
qvm-firewall "$VM" add drop

# List all rules and check
qvm-firewall "$VM" list
```

------------------------------
END OF QVM-FIREWALL SECTION
------------------------------
