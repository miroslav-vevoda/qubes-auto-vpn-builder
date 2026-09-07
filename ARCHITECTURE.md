# Architecture

How the Qubes VPN Build system is put together and why.

**Purpose:** turn setting up a VPN qube in Qubes OS — normally a manual,
one-off job — into a single config edit and one command in dom0, producing
a ready-to-use, firewalled, disposable VPN qube on demand.

**In one sentence:** dom0 orchestrates four qubes so that the automation
scripts, the VPN provider's keys, and the disposable qube that actually
runs the tunnel never share trust with each other — and a firewall enforced
in two independent places (inside the VPN qube, and by dom0 on the qube
from outside) makes sure that if the tunnel ever drops, downstream qubes
lose network access instead of leaking traffic in the clear.

Reviewed from inside a Fedora 43 AppVM (`qubes-core-agent-4.3.47-1.fc43`).
Items marked **[VERIFIED]** were checked against that running qube. Items
about dom0 were not — dom0 was not accessible from the authoring qube. The
VPN qube's own template may differ; re-check `[VERIFIED]` items there before
relying on them.

---

## 1. The four qubes

| Qube | Role |
|---|---|
| dom0 | Orchestrates everything: creates qubes, sets prefs/tags, applies `qvm-firewall`, triggers the config copy. The only place that knows both storage qube names below. |
| `salt-configs-vm` | Holds the salt state tree (authoring copy) and the one settings file you edit — protocol, MTU, country/server. No secrets. |
| `vpn-config-files-vm` | Holds the actual provider config files (private keys included) and `endpoint-map.txt`. `netvm = none`. Answers only two narrow qrexec requests, and only from dom0. |
| `<provider>-<sel>-vpn` | The named disposable that runs the tunnel and acts as the network source for your other qubes. |

`salt-configs-vm` and `vpn-config-files-vm` never learn about each other.
Only dom0 names both, and only dom0 decides which qube (if any) is allowed
to pull from `vpn-config-files-vm`.

## 2. Trust boundaries: code, parameters, and secrets

Three different kinds of data move through this system, and each is handled
differently:

- **Code** — the salt states themselves. A `.sls` file under `/srv/salt`
  runs as root in dom0, so it's treated as software: authored in
  `salt-configs-vm`, packaged and **signed** in a separate offline build qube,
  and installed into dom0 as one RPM under the procedure in
  `docs/getting-files-into-dom0.md`. It is never fetched automatically at
  apply time.

  Signing is not what makes the code trustworthy — a signed backdoor installs
  perfectly. What it buys is a **place to do the checking**. Every structural
  check (`tools/rpm/vpn-rpm-audit`: no install-time scriptlets, nothing
  outside the reviewed manifest, no symlink/setuid/device/`%ghost`, every
  digest matching the source tree, payload unpacked and compared to the
  header) runs in the build qube, on a package that has not been near dom0.
  dom0 then does two things only: verify the signature, and install. The
  earlier tar-based procedure had no way to achieve that split — dom0 had to
  parse the untrusted archive itself, before anything had been reviewed.

  Reading the source remains the only defence against a compromised
  `salt-configs-vm`, and no part of this is automated.

  Installing it once is enough because the tree is nine files that do not
  vary. Everything build-specific — protocol, transport, MTU, country,
  server, derived qube names — reaches them as `{{ }}` pillar references,
  and dom0 writes the pillar itself. So routine use moves no code into dom0
  at all; the only thing crossing per build is the dozen `key=value` lines of
  `vpn-selection.conf`, parsed against a fixed whitelist.

  Because the package owns `/srv/user_salt/vpn/`, `rpm -V
  qubes-vpn-dvm-dom0` answers a question the old procedure could not: is what
  is in dom0 still what was installed?

  `vpn-salt-sync` bypasses the package for the authoring loop, when the state
  tree itself is being edited. It shows a diff and asks for confirmation. It
  writes into paths the package owns, so afterwards `rpm -V` reports the
  drift — which is correct, and is the signal to roll the change into a new
  package version rather than leaving dom0 as the place the work lives. It is
  for iterating, not for shipping, and must never be automated.

  The archive that arrives is untrusted, which constrains how that review can
  work. `vpn-salt-sync` accepts only the `vpn/` subtree — `top.sls`, which
  decides *what* runs against dom0, is installed by hand and can never arrive
  this way. It rejects any non-regular file, because a symlink in the archive
  would redirect the later `chmod` pass onto an arbitrary dom0 path, as root.
  It normalises modes inside the staging directory rather than in
  `/srv/user_salt`, so no `chmod` ever runs against a live path. The diff must
  cover everything that gets installed or the review is theatre, and it's
  piped through `cat -v`, since escape sequences in an added line could
  otherwise repaint the text you're being asked to approve. Finally the
  subtree is replaced rather than merged, so a file deleted upstream actually
  disappears instead of lingering as live state.
- **Parameters** — protocol, transport, MTU, country/server selector. A plain
  `key=value` file in `salt-configs-vm`, pulled by `vpn-params-fetch` and
  validated against a strict pattern before use (e.g. `protocol` must be
  `wireguard` or `openvpn`, `transport` must be `udp` or `tcp`, `mtu` must
  fall in `[1280, 1500]`, the selector must match `^[a-z]{2}([0-9]{1,4})?$`).
  Anything that doesn't match aborts the build. The same validation applies
  to `endpoint-map.txt` lines before they reach a `qvm-firewall` command
  line, including rejecting octets with leading zeros — `010.0.0.1` is
  parsed as octal by some tools and must never be passed on as if it were
  unambiguous.
- **Secrets** — the provider `.conf` files. These never touch dom0's
  filesystem at all. dom0 tags the destination qube, then tells
  `vpn-config-files-vm` to copy the file directly to it:

  ```sh
  qvm-tags nordvpn-uk123-vpn-dvm add vpn-endpoint
  qvm-run vpn-config-files-vm \
    'qvm-copy-to-vm nordvpn-uk123-vpn-dvm /home/user/configs/uk/uk123.nordvpn.com.conf'
  ```

  qrexec policy scopes the copy by tag, not by hardcoded name, so
  `vpn-config-files-vm` can only ever send files to whichever qube dom0 has
  just tagged:

  ```
  qubes.Filecopy  *  vpn-config-files-vm  @tag:vpn-endpoint  allow
  qubes.Filecopy  *  vpn-config-files-vm  @anyvm             deny
  qubes.Filecopy  *  @tag:vpn-endpoint    @anyvm             deny
  ```

  The third rule is what stops key material coming back *out*. Both the dvm
  template and the disposable carry the tag, because the disposable is the
  qube that actually runs with the keys loaded — tagging only the template
  would leave the running qube outside the denial.

  `endpoint-map.txt` rides along with the configs in the same copy. It is
  metadata, not key material — the same lines `vpn-config-files-vm` already
  hands dom0 — and the VPN qube needs it locally because DNS is blocked
  there (see §4).

  The map is built outside all three qubes, by `tools/build-endpoint-map.sh`,
  in the networked qube where the configs were downloaded. That placement is
  forced: resolving a provider hostname to an address needs DNS, and none of
  the qubes in the trust path has it — `vpn-config-files-vm` has
  `netvm = none`, dom0 has no network, and the VPN qube has DNS dropped by the
  firewall. Resolution therefore happens once, at gathering time, and the
  result travels with the configs as data.

  A hijacked DNS answer at that moment is a denial of service, not an
  interception: both protocols authenticate the server cryptographically —
  WireGuard pins the peer's public key, OpenVPN checks the CA and
  `remote-cert-tls server` — so a wrong address fails to handshake rather than
  carrying traffic somewhere unnoticed.

  For the one piece of data dom0 does need — the endpoint address list — a
  narrow qrexec service in `vpn-config-files-vm` returns only
  `endpoint-map.txt` lines, never config bodies.

  Once delivered, `vpn-build` moves the files out of the template's
  `~/QubesIncoming` into a root-owned `0700` directory, `0600` per file.
  Otherwise the persistent copy in the template's home would keep whatever
  mode it arrived with, indefinitely.

## 3. Qube creation and naming

Qube names are derived from the config filename:
`uk123.nordvpn.com.conf` → `nordvpn-uk123-vpn-dvm` / `nordvpn-uk123-vpn`
(provider first, then server, `.com` dropped). A country-only selection
(no specific server) produces `nordvpn-uk-random-vpn-dvm` /
`nordvpn-uk-random-vpn`.

Two qubes are created per selection:

- **The dvm template** (`…-vpn-dvm`) — a plain AppVM, `netvm = none`,
  `provides_network = true`, `template_for_dispvms = true`, tagged
  `vpn-endpoint`. It never runs on its own; it exists purely so the
  disposable below can be spun up from it. `netvm = none` here is the
  fail-closed default — anything created from this template without an
  explicit override gets no uplink at all.
- **The named disposable** (`…-vpn`) — created from that template, with
  `netvm` and `provides_network` set explicitly:

  ```sh
  qvm-prefs nordvpn-uk123-vpn  netvm            sys-firewall
  qvm-prefs nordvpn-uk123-vpn  provides_network true
  ```

  It's a *named* disposable rather than an auto-named `disp####` because
  other qubes need to reference it by name as their `netvm`. An explicit
  `qvm-prefs` value on a named disposable persists across resets (only the
  private volume is discarded), so it keeps its network config every time it
  restarts.

  The uplink is `sys-firewall`, not `sys-net`, so the `qvm-firewall` rules in
  §4 are actually enforced. It is also tagged `vpn-endpoint`, so the policy
  denying file copies out of tagged qubes covers it.

  The uplink is a setting, not a constant: `uplink=` in the selection file
  reaches `dispvm.sls` through the pillar. It may name `sys-firewall`,
  another VPN qube's disposable (a chained tunnel — see §9), or the literal
  `none`. It **defaults to `none` when the key is absent**, matching the
  template's fail-closed stance: an omission must never hand a qube a
  network path nobody asked for. `none` is equally a legitimate deliberate
  value — the qube is created, firewalled and loaded with its config, and an
  uplink is attached by hand later.

`network-manager` is left off the VPN qube: its uplink is a Qubes vif, not
an NM-managed device, so NetworkManager is unneeded attack surface. It's
only needed on `sys-net`.

## 4. The firewall: two independent layers

If the tunnel drops, downstream qubes should lose connectivity outright
rather than falling back to the clear. Two layers enforce this independently:

### Layer 1 — inside the VPN qube: `qubes-firewall-user-script`

Placed at `/rw/config/qubes-firewall-user-script`, mode `0755`. Qubes'
firewall agent invokes this directly (`subprocess.call([path])`, no shell
wrapper) whenever it rebuilds the qube's nftables rules, gated only on
`os.path.isfile()` and `os.access(path, os.X_OK)` — so the shebang and the
execute bit are both required for it to run at all.

It takes the tunnel interface name from `/rw/config/vpn-params` (generated by
salt from the pillar), preferring a live interface in `/sys/class/net/` when
one exists, and builds the same seven rules in **both** the `ip` and `ip6`
nftables families:

```
1. MSS clamp        tcp syn/syn,rst -> clamp to path MTU
2. accept           downstream qubes (iifgroup 2) -> tunnel interface
3. accept           tunnel interface -> downstream, ct established,related
4. accept           tunnel interface -> uplink (eth0)
5. drop             downstream qubes (iifgroup 2) -> uplink directly
6. drop             everything else -> uplink
7. drop             everything else, by any interface
```

Rule 7 exists because rules 5 and 6 both name the uplink, so between them
they only cover traffic leaving by that one interface. Anything leaving by a
different interface would fall out of this chain into the Qubes base forward
chain, which is `policy accept` and carries its own *unscoped*
`ct state established,related accept` — so a second uplink (an attached NIC,
a USB tether) would leak established flows there and new ones at the accept
policy. Nothing legitimate reaches rule 7: downstream-to-downstream is
already dropped by the base chain's `oifgroup 2 drop`, and real tunnel
traffic matched rule 2, 3 or 4.

Each address family is applied as a **single `nft -f` transaction**, not as
seven separate `nft add` calls. That matters: building the chain incrementally
leaves `custom-forward` empty between the flush and the last rule, and since
the base forward chain is `policy accept`, that window is a real leak on
every firewall reload — and Qubes re-runs this script whenever any downstream
qube's rules change. A transaction also means a rejected rule leaves the
previous ruleset intact rather than a half-built one. If the load fails
anyway, the script forces a bare `oifname <uplink> drop` and exits non-zero
rather than reporting success over a chain in an unknown state.

The tunnel interface name is read from `/rw/config/vpn-params`, which salt
generates from the pillar, with a live interface in `/sys/class/net`
overriding it when one exists.

Rules 2, 3 and 4 are only added if interface detection succeeded; if it
didn't, the script installs rules 5, 6 and 7 alone — fail-closed rather than
fail-open.

**Every accept names the tunnel interface.** That is deliberate and is the
property the kill switch depends on: when the tunnel is down there is no
state in which an accept can match, so downstream traffic falls through to
a `drop` automatically and no separate "is the tunnel up" check is needed.

In particular, rule 3 is scoped to `iifname <tunnel> oifgroup 2` rather than
being a bare `ct state established,related accept`. An unscoped version
would also match a flow that was established *through* the tunnel but is now
being routed out the uplink because the tunnel dropped — and since `accept`
is a terminal verdict, that packet would be forwarded in the clear without
ever reaching rules 5 and 6. Scoping it costs nothing: the Qubes base
forward chain carries its own unconditional established/related accept
*after* the jump into `custom-forward`, so a legitimate return packet this
rule doesn't match still falls through to that one, while a leaked packet
hits a drop first.

**IPv6 is included unconditionally**, not gated behind a feature check.
`/etc/qubes/qubes-ipv6.nft` declares the `custom-forward` chain in the `ip6`
family unconditionally, and it's present even on a qube with the IPv6
feature off **[VERIFIED]** — so the rules always load. With IPv6 disabled
they simply never match any traffic; the cost is six inert rules, not a
per-packet cost. If IPv6 is ever turned on later, the kill switch is already
in place rather than needing to be remembered.

### Layer 2 — outside the VPN qube: `qvm-firewall`

Applied by dom0 via `vpn-firewall-apply`, before the VPN config is ever
delivered to the qube:

```
0  drop specialtarget=dns
1  drop proto=icmp
2..N accept proto=<transport> dst4=<endpoint> dstports=<port>   (one per allowed endpoint)
N+1 drop
```

built as:

```sh
qvm-firewall "$VM" reset
qvm-firewall "$VM" del --rule-no 0        # remove the blanket accept `reset` leaves behind
for ep in "$@"; do
    qvm-firewall "$VM" add accept proto="$PROTO" dst4="$ip" dstports="$port"
done
qvm-firewall "$VM" add --before 0 drop proto=icmp
qvm-firewall "$VM" add --before 0 drop specialtarget=dns
qvm-firewall "$VM" add drop
```

`$VM` is always the named disposable, never the dvm template — the
template's firewall rules never filter anything, since its `netvm` is
`none` and it never runs.

`$PROTO` comes from the `transport` setting (`udp` or `tcp`, default `udp`).
WireGuard is always UDP and `vpn-params-fetch` rejects any other value with
it; OpenVPN can be either, and whitelisting the wrong one makes the endpoint
silently unreachable — hence an explicit setting rather than a hardcoded
`udp`.

The trailing `drop` has no address family, so it covers IPv6 as well as
IPv4. After applying, `vpn-firewall-apply` asserts the last rule really is
an unconditional drop rather than just printing the list, so a broken
ruleset fails the build instead of shipping silently.

**Dropping DNS has a consequence worth stating.** The VPN qube cannot
resolve hostnames at all. That's intended — it removes a whole leak channel
— but it means an OpenVPN config with `remote <hostname>` can never connect.
`vpn-up` therefore rewrites the `remote` line to the IP the endpoint map
lists for that config, and refuses to start if there is no entry, rather
than hanging with no explanation.

### Why both layers, not just one

Qubes qubes that provide networking masquerade downstream traffic onto
their own uplink address. A packet that leaks from a downstream qube — say,
routed out `eth0` because the tunnel is down — reaches `sys-firewall` with
source = the VPN qube's own IP, which is exactly what Layer 2 matches on.
So both layers genuinely stop the same leak; they're not "one real layer and
one decorative one."

Layer 1 is the one to trust more under failure conditions: it matches on
interface (`iifgroup`/`oifname`), not address, it drops the packet before it
ever leaves the qube, and it stays in force even if `sys-firewall`'s
ruleset for this qube is ever flushed or hasn't been applied yet at boot.
Layer 2 is what stops the VPN qube itself from reaching anything other than
the whitelisted endpoints, which Layer 1 alone can't do.

One deliberate tradeoff: dropping ICMP (rule 1 above) means giving up
path-MTU discovery. MSS clamping covers TCP; nothing covers large UDP, so a
wrong MTU fails silently for QUIC-like traffic rather than loudly. The MTU
should be set from the tunnel's actual overhead (1420 for stock WireGuard
over a 1500-byte uplink), not left as a guess.

## 5. Data flow at build time

Running `vpn-build` in dom0:

1. **Read and validate parameters.** `vpn-params-fetch` reads the settings
   file from `salt-configs-vm` and checks every value against a strict
   pattern; anything that fails aborts the build.
2. **Create the qubes.** dom0 derives the qube names and creates the dvm
   template and named disposable as described in §3.
3. **Install scripts into the template**, so anything spun up from it
   inherits them — `qubes-firewall-user-script`, the MTU hook, `vpn-up`,
   `rc.local`, and `vpn-params`.
4. **Fetch the endpoint list** for the chosen country from
   `vpn-config-files-vm`, validating each line.
5. **Apply the firewall (Layer 2) before anything else happens** — the VPN
   qube is locked to the whitelisted endpoints, on the configured transport,
   before the actual config file is delivered, so there's no window where
   it's open.
6. **Deliver the config files** (plus `endpoint-map.txt`) via the tagged
   qube-to-qube copy in §2. dom0 never sees the config contents.
7. **Secure the delivered files** — move them out of the template's
   `~/QubesIncoming` into root-owned `0700` storage at `0600`, then shut the
   template back down, since the copy is what started it.

Random-server selection (when only a country was chosen) happens inside the
VPN qube at boot, not in dom0 — Layer 2 already allows every endpoint in
that country, so picking one at random at boot doesn't need dom0 involved,
and it keeps per-boot logic out of dom0.

## 6. What happens at boot

Because the VPN qube is a disposable, this runs fresh every time:

1. `vpn-up` picks a config — the specific server chosen, or a random one
   from the country.
2. It's installed under a fixed filename regardless of the original
   provider filename (`/etc/wireguard/wireguard.conf` or
   `/etc/openvpn/client/vpn.conf`), mode `0600` in both cases — configs
   carry private keys and, for OpenVPN, often inline credentials.
   `wg-quick` names its interface after the config filename, and provider
   filenames like `uk123.nordvpn.com` exceed the kernel's 15-character
   `IFNAMSIZ` limit, so bring-up would fail under the original name.
3. For OpenVPN, the `remote` line is rewritten to the IP from
   `endpoint-map.txt` and the device name is pinned to the interface the
   firewall was told to expect. Both are required, not cosmetic: DNS is
   blocked, and a `dev` line inherited from the provider would produce an
   interface name no rule matches. For WireGuard the config's `Endpoint` is
   compared against the map and a mismatch is logged, since the symptom
   otherwise is an unexplained hang.
4. The tunnel comes up (`wg-quick` or `openvpn`). `wg-quick` creates the
   interface synchronously, but `systemctl start` does not, so `vpn-up`
   waits for the interface to appear (up to 30s) before re-running
   `qubes-firewall-user-script`. Without the wait, detection would run
   against an interface that doesn't exist yet and the qube would stay
   kill-switched permanently.
5. The MTU hook (`90-vif-mtu`) sets the correct MTU on downstream vifs as
   they come online, reading the value from `/rw/config/vpn-params` (this
   hook runs with a bare environment, so it can't rely on an inherited
   shell variable).

## 7. Notes verified against a running qube

- The firewall script's real path is the flat
  `/rw/config/qubes-firewall-user-script` — there is no `/rw/config/qubes/`
  directory.
- It's invoked by direct `execve` (`subprocess.call`), gated on
  `isfile()`/`X_OK`, so a missing shebang or execute bit fails **silently** —
  no log entry, no error.
- `custom-forward` exists in both `ip qubes` and `ip6 qubes` on a qube with
  the IPv6 feature confirmed off (`qubesdb-read /qubes-ip6` fails, no
  global IPv6 address, `net.ipv6.conf.all.forwarding = 0`) — the chain isn't
  conditionally created.
- `/etc/qubes/qubes-ipv6-disabled.nft` exists on disk but was **not loaded**
  on the checked qube — it isn't a usable IPv6 backstop on its own.
- All six Layer-1 rules, including the MSS clamp, load identically in both
  the `ip` and `ip6` families.
- `oifname "eth0"` (string match) accepts a not-yet-existing interface name
  at rule-load time; `oif eth0` (index match) does not — this is why
  interface detection in `qubes-firewall-user-script` can safely reference
  an interface that may not exist yet.

## 8. External validation

Checked against Qubes' own docs and existing community projects, to
corroborate specific mechanisms this design relies on, and to note what
this design doesn't attempt to solve.

- Qubes' [firewall docs](https://doc.qubes-os.org/en/latest/user/security-in-qubes/firewall.html)
  confirm that custom-forward rules for a qube that *provides networking*
  belong in `qubes-firewall-user-script`, while an ordinary AppVM's custom
  rules belong in `rc.local` instead. They also confirm
  `sudo journalctl -u qubes-firewall.service` as a place to check firewall
  state, alongside this design's own `journalctl -t qubes-fw-user`.

- Mullvad's own [Qubes guide](https://mullvad.net/en/help/wireguard-on-qubes-os)
  independently confirms the same constraint `vpn-up` works around:
  `wg-quick` requires its config under `/etc/wireguard/`, which isn't
  persistent on an AppVM, so it has to be copied there from `/rw/config/` on
  every boot.

- [xyhhx/qubes-wireguard](https://github.com/xyhhx/qubes-wireguard) uses the
  same forward-chain kill-switch pattern and documents the same scope this
  design has: the rules protect *downstream* (forwarded) traffic only. The
  VPN qube's own egress — the tunnel handshake itself — isn't covered by
  design; don't run user applications directly in the VPN qube.

- A community
  [namespace-killswitch project](https://forum.qubes-os.org/t/wireguard-vpn-w-namespace-killswitch/35168)
  takes a different approach (network namespaces instead of forward-chain
  rules) to close three failure modes worth checking this design against:
  - *boot race* — mitigated here since the dvm template's netvm is `none`
    and the disposable's uplink is only ever set explicitly before it
    starts; worth confirming empirically that the nft rules are present in
    the first second of boot.
  - *firewall-service reload racing the script's own writes* — the script
    is idempotent (flush-then-rebuild) and is the exact hook Qubes
    re-invokes on reload; not tested under `systemctl restart
    qubes-firewall` while traffic is flowing.
  - *DNS-over-HTTPS/TLS bypassing a port-based kill switch* — not
    applicable here, since these rules gate by interface, not port; DoH/DoT
    from a downstream qube either goes through the tunnel or hits the
    catch-all drop like everything else.

- No published project (`tasket/Qubes-vpn-support`, `hkbakke/qubes-wireguard`,
  `xyhhx/qubes-wireguard`, `taythebot/qubes`, `man-tee/qubes-vpn`) automates
  the specific pipeline this project implements — fetch a config from an
  isolated storage qube, derive a qube name from it, and generate a dvm
  template plus a named disposable per server/selector, entirely from dom0
  via salt. Existing projects assume a human hand-places one config into one
  long-lived qube.

## 9. Building more than one qube

`vpn-build` builds one qube from one settings file. `vpn-build-all` builds a
set from a directory of numbered settings files in `salt-configs-vm`, calling
`vpn-build` once per config. It adds no new mechanism — the pipeline in §5 is
unchanged and runs once per config — only ordering and a validation pass.

Because the path is just an argument, `vpn-build vpn-configs/20-de77.conf`
rebuilds one member of a set in isolation. That is the same single-qube path
as always; it simply forgoes the set-wide checks below, which by definition
need more than one file to mean anything.

### Why it must be sequential

Two independent reasons, either sufficient on its own:

- a chained qube's uplink has to exist before the qube that uses it;
- `/srv/user_pillar/vpn.sls` is a single file that every build overwrites, so
  two builds at once would race on it even with no chaining involved.

### Ordering and topology are separate

The filename number decides *when* a config is built. The `uplink` field
decides *where* the qube attaches. "20 comes after 10" does not imply "20
routes through 10" — two independent VPN qubes both on `sys-firewall` are a
normal set, built one after another purely because of the pillar.

Keeping the two explicit buys a simplification. The ordering rule is:

> A config's `uplink` must name `none`, a qube that already exists outside
> the set, or the disposable built by a **lower-numbered** config.

Requiring *lower-numbered* rather than merely *present in the set* makes a
routing loop impossible to express — a cycle needs a backward reference and
there is no syntax for one. That replaces a cycle detector, a topological
sort and a forward-reference check with an index comparison, and gives up
nothing: a chain that must be built in an order is numbered in that order.

In-set membership is tested *before* asking whether the qube exists, so a
forward reference to a qube left over from an earlier run cannot pass by
existing already.

### Validation before creation

`vpn-params-fetch` validates each file on its own — every field against a
whitelist, as always. `vpn-build-all` adds the checks that no single file can
be validated against, because they are properties of the set:

| Check | Why one file cannot see it |
|---|---|
| Name collisions | Two valid configs can derive the same qube names. Building both silently yields *one* qube, the second config's key material overwriting the first's. |
| Uplink ordering | Requires knowing what the other configs build, and in what order. |
| MTU descent | A property of a *pair*. Every MTU in a broken chain is inside 1280–1500, so each file passes alone. |
| Endpoint availability | `vpn-build` does not discover this until step 4/7 — after it has created the qubes. Acceptable for one build, wrong mid-chain. |

All of it is read-only, and none of it runs after the first qube exists. A
set failing any check is refused entirely. The reason is the failure mode: a
half-built chain leaves qubes holding live key material, a child pointing at
a parent that does not exist, and nothing recording which qubes were yours.
Refusing the whole set is recoverable by editing a text file; unpicking a
partial chain is not.

### MTU stacking

Each hop's tunnel must fit inside the one it runs through. Conservative
per-hop figures: ~60 bytes for WireGuard over IPv4/UDP (20 + 8 + 32), ~69 for
OpenVPN/udp, ~89 for OpenVPN/tcp. So a chain descends:

```
sys-firewall 1500 → 1420 → 1360 → 1300 → (1240, rejected)
```

With `vpn-params-fetch`'s 1280 floor, that is about three WireGuard hops on a
1500-byte uplink. When the budget falls below the floor, `vpn-build-all`
reports that the chain is too long rather than naming an MTU the validator
would itself reject — the floor is checked before the fit, specifically so
the error is one the user can act on.

The figures are deliberately conservative and are a sanity check, not a
computation; `--no-mtu-check` skips the comparisons when a provider's real
overhead is smaller.

### How chaining interacts with the two firewall layers

Neither layer needed changing, but it is worth being explicit about why.

**Layer 2 (`qvm-firewall`).** Qubes enforces a qube's rules *in its netvm*.
For a chained child that netvm is the parent VPN qube rather than
`sys-firewall`, so the child's endpoint whitelist is enforced one hop further
in. The rules themselves are identical.

**Layer 1 (`custom-forward`).** The child is a downstream qube of the parent,
so its packets arrive on the parent as `iifgroup 2` and leave by the parent's
tunnel — matching rule 2 (`iifgroup 2 oifname $VPN_IF accept`). Returns match
rule 3. The child's own chain is unaffected; it sees `eth0` as its uplink as
usual, without knowing that `eth0` is another VPN qube's vif. The kill switch
therefore composes: if the *parent's* tunnel drops, the child's traffic stops
at the parent's rule 6, and downstream of the child stops with it.

### What is not verified

The logic above is tested against stubbed `qvm-*` commands — ordering,
collisions, MTU descent, the floor-before-fit error, mid-build failure
reporting. No chain has been brought up on real hardware. Two runtime facts
sit outside what any validation can establish: whether a provider permits
reaching one of its endpoints from inside another of its own tunnels, and
whether real per-hop overhead matches the figures above.
