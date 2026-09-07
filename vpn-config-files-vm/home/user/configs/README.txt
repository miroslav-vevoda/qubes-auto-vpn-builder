/home/user/configs/   (in vpn-config-files-vm)

    configs/
      auth-user-pass.txt          <- OpenVPN account credentials, if needed
      uk/
        endpoint-map.txt          <- metadata; the only thing dom0 ever reads
        uk123.nordvpn.com.conf    <- key material; never leaves except by
        uk124.nordvpn.com.conf       qvm-copy-to-vm to a vpn-endpoint-tagged
        uk125.nordvpn.com.conf       qube, on dom0's instruction
      de/
        endpoint-map.txt
        de45.nordvpn.com.conf
        ...

One directory per ISO country code, lowercase, exactly two letters.


OPENVPN ACCOUNT CREDENTIALS

Most providers' OpenVPN configs contain a bare "auth-user-pass" line, meaning
"prompt for a username and password". There is no terminal to prompt on in the
VPN qube, so the connection fails at startup unless the credentials come from
a file.

Put them in configs/auth-user-pass.txt, exactly two lines:

    your-service-username
    your-service-password

These are usually SERVICE credentials from the provider's dashboard, not your
account login. They are pushed to the VPN qube alongside the configs, land in
/rw/config/vpn/auth-user-pass.txt at mode 0600 root-owned, and vpn-up rewrites
the config to point "auth-user-pass" at that path.

They live here, not in salt-configs-vm, for the same reason the configs do:
anything reaching the VPN qube through salt would pass through dom0's pillar in
/srv/user_pillar first. This path is qube-to-qube and never touches dom0's
filesystem. salt-configs-vm holds no secrets, and this would be one.

Not needed for WireGuard, or for OpenVPN configs that authenticate purely by
certificate.

This qube should have netvm = none. It never needs a network: dom0 reaches it
over qrexec, and configs leave over qrexec. Set it and the isolation stops
depending on the firewall being right.


BUILDING endpoint-map.txt

Do not write it by hand. Run tools/build-endpoint-map.sh in the NETWORKED qube
where you downloaded the configs, before copying them here:

    ./build-endpoint-map.sh ~/configs

It reads each .conf, extracts the server address, resolves any hostname to an
IPv4 address, and writes endpoint-map.txt into each country folder. Then copy
the whole configs/ tree into this qube.

It has to run there, not here, because that is the only point in the workflow
with DNS: this qube has netvm = none, dom0 has no network at all, and the VPN
qube has DNS dropped by the dom0 firewall. Re-run it whenever you add configs
or a previously working server stops connecting -- providers rotate addresses,
and a stale IP looks exactly like a dead tunnel.

Each line is

    <stem>.<provider>.<tld>.conf  <ip>:<port>

where <stem> is two letters plus 1-4 digits. dom0 re-validates each line,
skips comments, and rejects octets with leading zeros. Malformed lines are
skipped, not fatal -- the build tool warns about them at generation time so
they can be fixed by renaming.


ONE THING THE MAP CANNOT FIX

The map controls the dom0 firewall and OpenVPN's remote line -- vpn-up rewrites
"remote" to the address listed here. It does NOT rewrite a WireGuard Endpoint:
wg-quick resolves that itself, inside the VPN qube, where there is no DNS.

So a WireGuard config whose Endpoint is a hostname will not connect even with a
correct map. build-endpoint-map.sh detects this and prints the exact line to
paste into the config.
