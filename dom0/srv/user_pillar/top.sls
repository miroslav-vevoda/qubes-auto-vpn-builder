# /srv/user_pillar/top.sls
#
# Scoped rather than '*': the pillar carries the provider, country, server and
# derived qube names. No secrets, but no reason to hand it to every minion
# either. dom0 needs it to create the qubes; the dvm template needs it to
# render vpn-params. The glob matches the naming convention vpn-params-fetch
# derives (<provider>-<stem>-vpn-dvm).
base:
  'dom0':
    - vpn
  '*-vpn-dvm':
    - vpn
