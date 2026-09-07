# /srv/user_salt/vpn/dvmtemplate.sls
#
# The AppVM that the disposable is based on. It never runs itself.
# netvm is deliberately none: fail-closed, so anything spawned from this
# template without explicit configuration gets no uplink at all. The uplink is
# set on the named disposable instead (see dispvm.sls).

{% set v = pillar.get('vpn', {}) %}

{{ v.dvm_template }}-present:
  qvm.present:
    - name: {{ v.dvm_template }}
    - template: {{ v.base_template }}
    - label: black
    - class: AppVM

{{ v.dvm_template }}-prefs:
  qvm.prefs:
    - name: {{ v.dvm_template }}
    - netvm: none
    - template_for_dispvms: true
    - provides_network: true
    - maxmem: 800
    - vcpus: 2
    - require:
      - qvm: {{ v.dvm_template }}-present

# Scopes the qubes.Filecopy policy that lets vpn-config-files-vm push configs
# in. Nothing else may receive them. See /etc/qubes/policy.d/30-vpn.policy.
{{ v.dvm_template }}-tags:
  qvm.tags:
    - name: {{ v.dvm_template }}
    - present:
      - vpn-endpoint
    - require:
      - qvm: {{ v.dvm_template }}-prefs

# qubes-firewall is required (it runs qubes-firewall-user-script).
# network-manager is deliberately NOT enabled: the uplink is a Qubes vif, not
# an NM-managed device, so NM is pure attack surface here.
{{ v.dvm_template }}-services:
  qvm.service:
    - name: {{ v.dvm_template }}
    - enable:
      - qubes-firewall
    - disable:
      - network-manager
    - require:
      - qvm: {{ v.dvm_template }}-tags
