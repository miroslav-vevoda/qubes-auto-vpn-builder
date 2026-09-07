~/salt/   (in salt-configs-vm)

Authoring copy of the dom0 state tree. Mirror of what ends up in
/srv/user_salt/ -- same layout, starting at the "vpn/" directory:

    ~/salt/vpn/init.sls
    ~/salt/vpn/dvmtemplate.sls
    ~/salt/vpn/dispvm.sls
    ~/salt/vpn/vmfiles.sls
    ~/salt/vpn/files/...

These nine files are installed into dom0 ONCE, by hand, along with everything
else that goes there -- see docs/getting-files-into-dom0.md.

You do not need to move them again to change a setting. Protocol, transport,
MTU, country and server all reach these files as {{ }} pillar values, and dom0
writes the pillar itself from vpn-selection.conf. The tree is identical whether
you are building a WireGuard UK tunnel or an OpenVPN-over-TCP German one.

If you are EDITING these files -- developing the project rather than using it
-- dom0 can re-pull them with:

    vpn-salt-sync

That shows a diff and asks for confirmation, because .sls files run as root in
dom0. It is a software install, not a runtime fetch -- do not automate it and
do not call it from vpn-build.
