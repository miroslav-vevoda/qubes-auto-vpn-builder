# /srv/user_salt/vpn/vmfiles.sls
#
# Applied INSIDE the dvm template, not in dom0:
#   qubesctl --skip-dom0 --targets=<dvm-template> state.apply vpn.vmfiles
#
# Requires qubes-mgmt-salt-vm-connector in the base template.
#
# Mode 0755 on the firewall script is load-bearing: qubes-firewall gates
# execution on os.access(path, os.X_OK) and skips it SILENTLY if unset.

{% set v = pillar.get('vpn', {}) %}

/rw/config/qubes-firewall-user-script:
  file.managed:
    - source: salt://vpn/files/qubes-firewall-user-script
    - user: root
    - group: root
    - mode: '0755'

/rw/config/network-hooks.d:
  file.directory:
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

/rw/config/network-hooks.d/90-vif-mtu:
  file.managed:
    - source: salt://vpn/files/90-vif-mtu
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: /rw/config/network-hooks.d

/rw/config/vpn-params:
  file.managed:
    - source: salt://vpn/files/vpn-params.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context:
        protocol: {{ v.protocol }}
        transport: {{ v.transport }}
        mtu: {{ v.mtu }}
        mode: {{ v.mode }}
        vpn_if: {{ v.vpn_if }}

/rw/config/vpn-up:
  file.managed:
    - source: salt://vpn/files/vpn-up
    - user: root
    - group: root
    - mode: '0755'

/rw/config/rc.local:
  file.managed:
    - source: salt://vpn/files/rc.local
    - user: root
    - group: root
    - mode: '0755'

# Where vpn-config-files-vm's pushed configs are moved to by vpn-up.
/rw/config/vpn:
  file.directory:
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: True
