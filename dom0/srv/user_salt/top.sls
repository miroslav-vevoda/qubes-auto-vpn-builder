# /srv/user_salt/top.sls
#
# dom0 target creates and configures the qubes.
# The VM target places files inside the VPN dvm template and must be applied
# separately with --targets, e.g.
#   qubesctl --skip-dom0 --targets=nordvpn-uk123-vpn-dvm state.apply vpn.vmfiles

base:
  dom0:
    - vpn
