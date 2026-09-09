# /srv/user_salt/vpn/dispvm.sls
#
# The named disposable that actually runs the tunnel and serves as netvm for
# downstream qubes. It must be NAMED (not ad-hoc disp####) because other qubes
# reference it by name as their netvm.
#
# netvm/provides_network are set explicitly here rather than inherited: for a
# named disposable the template's values are only a default, and an explicit
# qvm-prefs value persists across resets (only the private volume is discarded).

{% set v = pillar.get('vpn', {}) %}

{{ v.dispvm }}-present:
  qvm.present:
    - name: {{ v.dispvm }}
    - template: {{ v.dvm_template }}
    - label: black
    - class: DispVM

# uplink is whatever vpn-params-fetch validated: sys-firewall, another VPN
# qube's disposable (a chained tunnel), or the literal "none". It defaults to
# none when the selection file does not set it, so an omitted key can never
# hand this qube a network path -- the same fail-closed stance the template
# takes above. A disposable with netvm none is built and firewalled but
# cannot reach its endpoint until one is attached by hand.
{{ v.dispvm }}-prefs:
  qvm.prefs:
    - name: {{ v.dispvm }}
    - netvm: {{ v.uplink }}
    - provides_network: true
    - autostart: false
    - require:
      - qvm: {{ v.dispvm }}-present

# The disposable is the qube that actually runs with live key material, so it
# needs the tag too -- 30-vpn.policy denies qubes.Filecopy OUT of anything
# tagged vpn-endpoint, and without this that denial would only cover the
# template and miss the running qube entirely.
{{ v.dispvm }}-tags:
  qvm.tags:
    - name: {{ v.dispvm }}
    - present:
      - vpn-endpoint
    - require:
      - qvm: {{ v.dispvm }}-prefs

# Set on the disposable EXPLICITLY, not left to inherit from the template.
#
# qubes-firewall is what runs qubes-firewall-user-script, and that script is
# Layer 1 -- the in-qube kill switch. The template it would be inherited from
# has netvm none and never runs, so enabling it there does nothing except be
# inherited: the whole of Layer 1 would rest on that inheritance behaving as
# expected. This file already declines to inherit netvm and provides_network
# for the same class of reason, and the cost of being wrong is higher here.
#
# If inheritance does work, this is redundant and harmless. If it does not,
# this is the difference between two independent enforcement layers and one --
# and the difference would be close to invisible, because Layer 2 confines the
# qube to its endpoint regardless, so the documented kill-switch test would
# still appear to pass with Layer 1 entirely absent.
#
# network-manager stays disabled: the uplink is a Qubes vif, not an
# NM-managed device, so NM here is attack surface and nothing else.
{{ v.dispvm }}-services:
  qvm.service:
    - name: {{ v.dispvm }}
    - enable:
      - qubes-firewall
    - disable:
      - network-manager
    - require:
      - qvm: {{ v.dispvm }}-tags
