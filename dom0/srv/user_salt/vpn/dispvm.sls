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

# No qvm.service block here on purpose.
#
# The disposable needs qubes-firewall -- it is what creates the nftables
# "qubes" table and the custom-forward chain that Layer 1 lives in, and what
# invokes /rw/config/qubes-firewall-user-script. The script only ever does
# "add rule ip qubes custom-forward ...", never creating the chain, so without
# the service every invocation fails, including its own emergency-drop
# fallback. vpn-up calling the script later cannot substitute for it.
#
# But services ARE inherited from the dvm template, verified in dom0 against a
# real build, so enabling it in dvmtemplate.sls covers this qube too. Setting
# it again here would be redundant. netvm and provides_network above are a
# different case: those are prefs, not features, and for a named disposable
# the template's values are only a default.
