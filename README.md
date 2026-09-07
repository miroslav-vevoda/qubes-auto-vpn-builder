# Qubes Auto VPN Builder

Automatically generate a firewalled, disposable VPN qube in Qubes OS from a
single config choice — protocol, MTU, and a country or specific server — with
a two-layer kill switch that fails closed when the tunnel drops.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the design rationale: the trust
boundaries between the qubes, both firewall layers in full, the build-time and
boot-time data flow, and external validation against Qubes docs and community
projects.

**Contents**

- [What this is for](#what-this-is-for)
- [The three qubes, and why they are separate](#the-three-qubes-and-why-they-are-separate) — read this first
- [Using it](#using-it) — the four steps, briefly
- [Step 1 in detail: preparing your provider's configs](#step-1-in-detail-preparing-your-providers-configs) — the endpoint map
- [What happens when you run the build](#what-happens-when-you-run-the-build)
- [What happens every time the VPN qube boots](#what-happens-every-time-the-vpn-qube-boots)
- [Repository layout](#repository-layout)
- [Install order](#install-order) — the commands
- [Building several qubes](#building-several-qubes) — chaining
- [The two firewalls](#the-two-firewalls) — how the kill switch works
- [Verify after build](#verify-after-build)
- [Status: verified vs. assumed](#status-verified-vs-assumed) — what is actually tested
- [Support](#support)

---

## What this is for

Normally, setting up a VPN qube in Qubes OS is a manual, one-off job: create
an AppVM, install WireGuard or OpenVPN, copy in one config file by hand,
write firewall rules by hand, and repeat all of that from scratch every time
you want to switch provider, country, or server.

This project turns that into one edit and one command. You pick a protocol,
an MTU, and a country or specific server; you run one build command in dom0;
you get back a ready-to-use, disposable VPN qube — firewalled, named, and
connected — with no manual qube-building involved. Want a different server
next week? Change one line and re-run the build.

That's the whole point: making a correctly-configured VPN qube something you
generate on demand instead of something you hand-build and are then
reluctant to touch again.

## The three qubes, and why they are separate

Almost every design decision here follows from one split, so it is worth
understanding before anything else.

| Qube | Holds | Network |
|---|---|---|
| **dom0** | the build commands and the salt states | none, as always |
| **`salt-configs-vm`** | the settings file you edit, and an authoring copy of the salt states | normal |
| **`vpn-config-files-vm`** | your provider's configs, **including private keys** | **`netvm = none`** |
| *(generated)* `<provider>-<sel>-vpn-dvm` + `-vpn` | the template and the disposable you actually use | template: none; disposable: whatever you set `uplink=` to |

Three consequences, each of which explains a chunk of the rest of this
document:

### What the split is not

**It is not protection from dom0.** dom0 is the most privileged thing on the
machine and can read anything in any qube — one `qvm-run --pass-io
vpn-config-files-vm 'cat …'` and it has your private keys. `netvm = none`
constrains the *network*, not dom0. Nothing here changes that, and no design
on Qubes can.

So the split is not a claim that your keys are safe from the automation. It is
a set of defences against everything that *isn't* dom0:

**A compromised config qube cannot exfiltrate.** `vpn-config-files-vm` has
`netvm = none`, so even if something in it is malicious — a tampered config, a
bad download — it has no route out. This is also why the endpoint map must be
built *before* the configs land there: that qube has no DNS, ever.

**Another qube cannot ask for your keys.** The qrexec policy in
`30-vpn.policy` scopes the copy by a **tag that only dom0 can set**, so
`vpn-config-files-vm` will only ever send files to the qube dom0 just tagged.
A second compromised qube cannot request them, and cannot name itself as the
destination.

**The keys are not in dom0's filesystem.** dom0 *could* read them, but as
built it never stores or relays them — it triggers a direct qube-to-qube
transfer. That keeps them out of dom0's disk, logs and swap, which reduces
accidental exposure rather than adversarial exposure. A real but modest
benefit, and worth stating as the modest thing it is.

**The file you edit is not where your secrets are.** Choosing a country is
routine and frequent; handling private keys is not. Separating them means the
thing you touch weekly is not the thing that would hurt you to lose.

### The actual threat model

The concern is **dom0 being compromised**, not secrecy. Since dom0 can already
read every secret on the machine, protecting secrets *from* it is not a goal
worth pursuing — the goal is to minimise what flows *into* it, because that is
the only direction that can make dom0 worse than it already is.

That is what the rest of this design is about, and it is why the security
effort is concentrated somewhere that looks unrelated: the only code that ever
crosses into dom0 does so as a signed package whose structure has been audited
in a disposable build qube (`tools/rpm/vpn-rpm-audit`), and the only thing
crossing per build is a dozen `key=value` lines parsed against a fixed
whitelist.

## Using it

1. **Prepare your provider's configs.** Sort them one folder per country code,
   run `tools/build-endpoint-map.sh` over them *in the networked qube you
   downloaded them in*, then copy the tree into `vpn-config-files-vm` and take
   it offline. Detail in the next section — this is the only fiddly step.
2. **Edit one settings file** in `salt-configs-vm`: WireGuard or OpenVPN, a
   transport (`udp`/`tcp`), an MTU, and a country or specific server.
3. **In dom0, run the build** (see **Install order**, below).
4. **Use it** — start the disposable and point other qubes at it as their
   network source.

Everything else — naming, firewall rules, config delivery, kill switch — is
automatic from there.

## Step 1 in detail: preparing your provider's configs

This is the one step that needs thought, and the one most likely to bite you
later if rushed. Everything after it is automatic.

### What you start with

A download from your VPN provider: anywhere from a handful to several hundred
`.conf` files, one per server. Sort them into **one folder per two-letter
lowercase country code**, and name each file `<stem>.<provider>.<tld>.conf`
where the stem is two letters plus one to four digits:

```
~/configs/
  uk/
    uk123.mullvad.net.conf
    uk124.mullvad.net.conf
  de/
    de77.mullvad.net.conf
```

The stem (`uk123`) is what you will later put in your settings file to pick a
specific server, and it becomes part of the generated qube's name. Files that
don't match the pattern are skipped by dom0, so the script warns you about
them up front rather than letting a server go quietly missing.

### Then run the endpoint map builder

```sh
tools/build-endpoint-map.sh ~/configs
```

**Run it in the networked qube where you downloaded the configs — before
copying anything into `vpn-config-files-vm`.**

### Why this is a separate step

Because it needs DNS, and this is the only moment in the entire workflow that
has any:

- `vpn-config-files-vm` has `netvm = none`
- dom0 has no network at all
- the VPN qube has DNS **dropped** by the `qvm-firewall` rules dom0 applies to
  it (layer 1 under [The two firewalls](#the-two-firewalls))

Your provider's configs usually name servers by hostname
(`Endpoint = uk123.mullvad.net:51820`). But the firewall that locks the VPN
qube down has to be written in terms of **IP addresses** — you cannot
whitelist a name you have no way to resolve. So every hostname is resolved
once, here, at gathering time, and the answers are written down.

That's the whole reason this script exists on its own.

### What it produces

An `endpoint-map.txt` in each country folder:

```
# Generated by build-endpoint-map.sh on 2026-09-07 14:22 UTC
# <config-filename> <ip>:<port>   -- hostnames already resolved
uk123.mullvad.net.conf 193.32.249.66:51820
uk124.mullvad.net.conf 193.32.249.67:51820
```

That file is the *only* thing dom0 ever reads out of `vpn-config-files-vm`.
It contains no key material — just which server is at which address — which
is what lets dom0 build the firewall without ever touching your keys.

### What it checks, and why

- **Rejects addresses with a leading zero.** `010.0.0.1` is read as octal by
  some tools and decimal by others; whitelisting it would open a hole to an
  address nobody chose. Anything numeric-but-malformed is refused outright
  rather than resolved — `getent` would cheerfully turn `010.0.0.1` into
  `8.0.0.1` and the firewall would then permit a completely different server.
- **Refuses IPv6.** This design is IPv4-only by choice: `qvm-firewall` gets
  `dst4` rules and the VPN qube has IPv6 disabled.
- **Writes via a temp file and `mv`.** An interrupted run never leaves a
  half-built map that a later build would read as authoritative.
- **Warns when a hostname has several addresses** and tells you which one it
  pinned.

One warning deserves special attention:

> `! uk123…conf - WireGuard Endpoint is a hostname.`

`wg-quick` resolves `Endpoint` *itself*, inside the VPN qube — where there is
no DNS. The map fixes the firewall but cannot fix the config, so for WireGuard
you must also edit the `.conf` to use the literal address the script prints.
The script tells you the exact line to write.

### Then move it across

Copy the whole tree into `vpn-config-files-vm` at `/home/user/configs/`, and
from dom0 set `qvm-prefs vpn-config-files-vm netvm none`. From that point on
the qube is offline permanently, and re-running the map means bringing the
configs back out to a networked qube — so it is worth getting right once.

## What happens when you run the build

You type one command in dom0: `vpn-build`. In order:

1. **Read your choice, check it's sane.** dom0 reads the settings file
   (protocol, MTU, which server) and checks every value against a strict
   pattern before using it — e.g. the country code must be exactly two
   lowercase letters. Anything that doesn't match aborts the build rather
   than guessing.
2. **Create the qubes.** dom0 derives qube names from your choice (e.g.
   `uk123` → `nordvpn-uk123-vpn-dvm` and `nordvpn-uk123-vpn`), then creates a
   plain AppVM template with no network connection of its own, and a named
   disposable based on it that does get a connection — the one you actually
   use.
3. **Install the scripts into the template**, so every disposable spun up
   from it inherits them.
4. **Fetch the list of VPN server addresses** for the chosen country from
   `vpn-config-files-vm`, validating every line looks like a real IP/port
   before using it.
5. **Lock down the firewall (Layer 2) — before anything else happens.** The
   VPN qube is restricted to only ever reach the whitelisted server addresses,
   on the right port and protocol. This happens *before* the config file is
   delivered, so there's never a moment where the qube is open.
6. **Deliver the actual VPN config.** Only now does dom0 tell
   `vpn-config-files-vm` to send the real config — including its private key
   — directly to the VPN qube. The contents do not pass through dom0, which
   keeps them out of its disk and logs; it is not a barrier against dom0
   itself, which could read them regardless.
7. **Secure what was delivered.** The files are moved out of the inbox into
   root-owned `0700` storage at `0600` each, and the template is shut back
   down.

## What happens every time the VPN qube boots

Because it's a disposable, this runs fresh every time:

1. Picks a config — the specific server you chose, or a random one from the
   country you chose.
2. Brings up the tunnel (WireGuard or OpenVPN).
3. Applies the firewall / kill-switch rules (see Architecture).
4. Sets the correct MTU on downstream qubes so packets fit inside the
   tunnel's overhead.

## Repository layout

```
dom0/                                    installed on dom0
  srv/user_salt/vpn/                     salt states — qube creation, prefs, tags
    init.sls / dvmtemplate.sls / dispvm.sls / vmfiles.sls
    files/                               payload placed inside the VPN qube
      qubes-firewall-user-script         the kill switch
      90-vif-mtu                         MTU hook for downstream vifs
      vpn-up                             tunnel bring-up, run at boot
      rc.local                           calls vpn-up
      vpn-params.jinja                   -> /rw/config/vpn-params
  srv/user_pillar/                       generated + example pillar data
  usr/local/bin/
    vpn-build                            builds one qube, start to finish
    vpn-build-all                        several qubes from numbered configs
    vpn-params-fetch                     validates vpn-selection.conf -> pillar
    vpn-endpoints-fetch                  validates the endpoint map -> IP:PORT
    vpn-firewall-apply                   the qvm-firewall ruleset
    vpn-salt-sync                        authoring only — not used to install
  etc/qubes/policy.d/30-vpn.policy       the isolation between the two storage qubes

salt-configs-vm/
  home/user/vpn-selection.conf           the one file you edit
  home/user/vpn-configs/                 numbered set, for vpn-build-all
  home/user/salt/                        authoring copy of dom0/srv/user_salt/vpn

vpn-config-files-vm/                     netvm = none
  etc/qubes-rpc/custom.VpnEndpointList   returns endpoint-map.txt only
  etc/qubes-rpc/custom.VpnConfigPush     pushes configs to a tagged target qube
  home/user/configs/<iso>/               one folder per country code

tools/                                   run outside dom0, nothing installed
  build-endpoint-map.sh                  builds endpoint-map.txt from configs
  rpm/                                   packaging for the dom0 half
    manifest.txt                         THE reviewed list of what reaches dom0
    build-rpm.sh                         manifest -> spec -> signed .rpm
    vpn-rpm-audit                        refuses a package that fails any check
    selftest-hostile.spec                a bad package, to prove the audit works

docs/                                    documentation only, nothing installed
  getting-files-into-dom0.md             building, signing and installing the package
```

Each top-level directory except `tools/` and `docs/` is named after the qube
the files under it belong to; the rest of the path is the literal destination
path inside that qube. `docs/` is prose only. `tools/build-endpoint-map.sh`
runs wherever you gather your configs — a qube with a network connection,
which none of the three above has. `tools/rpm/` runs in the build qube, and
`vpn-rpm-audit` refuses to run in dom0 at all.

## Install order

1. **In `salt-configs-vm`:**
   ```sh
   mkdir -p ~/salt
   cp -a vpn-build/dom0/srv/user_salt/vpn ~/salt/
   cp vpn-build/salt-configs-vm/home/user/vpn-selection.conf ~/
   $EDITOR ~/vpn-selection.conf
   ```
   For several qubes at once, copy `vpn-configs/` here as well and edit that
   instead — see **Building several qubes**, below.
2. **In the networked qube where you downloaded your configs:** arrange them
   one folder per country code and run `tools/build-endpoint-map.sh ~/configs`.
   This resolves any hostnames and writes `endpoint-map.txt` into each folder.
   It has to happen here — it's the only step in the whole workflow with DNS.
   Full explanation in **Step 1 in detail**, above; read it before you run
   this, particularly if you use WireGuard with hostname endpoints.
3. **In `vpn-config-files-vm`:** copy `etc/qubes-rpc/*` to `/etc/qubes-rpc/`
   (mode 755, root:root); copy the whole `configs/` tree from step 2 into
   `/home/user/configs/`; from dom0,
   `qvm-prefs vpn-config-files-vm netvm none`. **OpenVPN only:** if your
   configs carry a bare `auth-user-pass` line, put your service username and
   password on two lines in `/home/user/configs/auth-user-pass.txt` — without
   it the tunnel cannot authenticate. See `configs/README.txt`.
4. **Install the dom0 half as a signed package.** In a dedicated offline build
   qube: `tools/rpm/build-rpm.sh --sign <KEYID>`, which generates the spec
   from `tools/rpm/manifest.txt`, builds, signs, and then runs
   `tools/rpm/vpn-rpm-audit` against its own output — deleting the package if
   any check fails. Then, in dom0, pull the one `.rpm`, `rpmkeys -Kv` it, and
   `sudo rpm -Uvh`.

   Full procedure, including generating the key and getting its fingerprint
   into dom0 safely, is in
   [`docs/getting-files-into-dom0.md`](docs/getting-files-into-dom0.md).

   This is the only time code crosses into dom0. Note what the signature does
   and does not do: it proves the package left the build VM unmodified. It
   does **not** make the contents safe — a signed backdoor installs perfectly
   — so `vpn-rpm-audit` checks the package (no install-time scriptlets, no
   symlinks or setuid, nothing outside the manifest, every digest matching the
   reviewed source), and reading the source is still on you. What signing buys
   is that all of that checking happens in a disposable qube instead of in
   dom0.
5. **In dom0:** `vpn-build` — creates everything. For a set of numbered
   configs instead, `vpn-build-all -n` to validate and then `vpn-build-all`
   to build (see **Building several qubes**).
6. **Use it:**
   ```sh
   qvm-start <provider>-<sel>-vpn
   qvm-prefs <some-qube> netvm <provider>-<sel>-vpn
   ```

## Building several qubes

`vpn-build` builds one qube from one settings file. `vpn-build-all` builds a
set, in order, from a directory of numbered settings files in
`salt-configs-vm`:

```
~/vpn-configs/
  10-uk123.conf     uplink=sys-firewall          entry hop
  20-de77.conf      uplink=nordvpn-uk123-vpn     chained inside it
  30-nl04.conf      uplink=none                  attach by hand later
```

Each file has exactly the format of `vpn-selection.conf`. Which leaves three
ways to build, all run in dom0:

```sh
vpn-build                            # ~/vpn-selection.conf   -> one qube
vpn-build-all -n                     # validate the set, create nothing
vpn-build-all                        # ~/vpn-configs/*.conf   -> the whole set
vpn-build vpn-configs/20-de77.conf   # one file out of the set -> one qube
```

The last is for rebuilding a single hop after editing it, without touching
the rest. `uplink` is read from that file as usual, so a chained qube stays
chained — but seeing one file, `vpn-build` cannot check the MTU against its
parent or spot a name collision with another config. Run `vpn-build-all -n`
first if more than that one file changed.

Nothing about the single-file path changed. `vpn-build` with no argument
behaves exactly as it always did, and if you never create `~/vpn-configs/`
none of this applies to you.

**Always sequential.** A chained qube's uplink has to exist before it does,
and `/srv/user_pillar/vpn.sls` is a single file that every build overwrites —
so two builds at once would race even with no chaining involved.

**Numbering and `uplink` are separate axes.** The filename decides *when* a
config is built; the `uplink` field decides *where* it attaches. Two
independent VPN qubes both on `sys-firewall` are a normal set.

**`uplink` defaults to `none`, never to `sys-firewall`.** An omitted key must
never hand a qube a network path nobody asked for. `none` is also a
legitimate deliberate value — the qube is fully built, firewalled and loaded
with its config, and you attach it later with `qvm-prefs <disposable> netvm
<qube>`. The final report lists every qube built this way.

**Nothing is created until the whole set validates.** `vpn-params-fetch`
already checks each file on its own; `vpn-build-all` adds the checks no
single file can be validated against:

- **name collisions** — two configs deriving the same qube names would
  silently produce one qube, the second config's key material overwriting the
  first's;
- **uplink ordering** — an uplink must name a lower-numbered config's
  disposable, an existing qube, or `none`. Requiring *lower-numbered* is also
  what makes a routing loop impossible to write, so there is no cycle to
  detect;
- **MTU descent** — each hop must fit inside its parent (~60 bytes per
  WireGuard hop, ~69 OpenVPN/udp, ~89 OpenVPN/tcp). Every MTU in a broken
  chain is inside 1280–1500, so each file passes alone; get it wrong and you
  get a tunnel where ping works and anything large vanishes. `--no-mtu-check`
  skips this if your provider's real overhead is smaller;
- **endpoint availability** — asked up front, rather than at step 4/7 after
  the qubes already exist.

A set failing any of these is refused entirely, because a half-built chain is
worse than an unbuilt one: qubes holding live key material, a child pointing
at a parent that does not exist, and no record of which qubes were yours.

**Nothing is started.** The build is a build; the report prints the start
order, and a chained qube needs its uplink running first.

The 1280 MTU floor puts a practical limit of about three WireGuard hops on a
1500-byte uplink. Past that, `vpn-build-all` says the chain is too long
rather than suggesting an MTU the validator would reject.

## The two firewalls

There are two, they run in different places, and neither is sufficient alone.
Confusing them is the easiest way to think you are protected when you are not.

Numbering matches [`ARCHITECTURE.md`](ARCHITECTURE.md) §4: **Layer 1 is
inside the qube, Layer 2 is outside it.**

| | Layer 1 — nftables `custom-forward` | Layer 2 — `qvm-firewall` |
|---|---|---|
| Set by | `qubes-firewall-user-script`, in the qube | `vpn-firewall-apply`, in dom0 |
| Enforced by | the VPN qube itself | the disposable's netvm — whatever `uplink=` names |
| Governs | traffic that **passes through** the qube | traffic the VPN qube **originates** |
| Stops | downstream qubes leaking to the clear | the qube talking to anything but the VPN server |
| If the tunnel drops | **this is the kill switch** | unaffected — it never saw tunnel traffic |

The split matters because each is blind to the other's job. `qvm-firewall`
sees the VPN qube as a single endpoint and cannot distinguish a downstream
qube's packet from the qube's own. `custom-forward` only sees the forward
hook, so the tunnel handshake — which the qube originates — never passes
through it at all.

### Layer 1 — nftables `custom-forward`, inside the qube

Loaded at firewall-service start, before per-qube rules are inserted, so the
chains are guaranteed to exist. Both `ip` and `ip6` get the identical ruleset
unconditionally — the ip6 chain exists even with IPv6 off, so if IPv6 is ever
enabled the kill switch already covers it.

```
1  tcp syn → clamp MSS to path MTU          (tunnel overhead)
2  iifgroup 2  oifname <tun>        accept  downstream → tunnel
3  iifname <tun>  oifgroup 2  ct established,related accept
4  iifname <tun>  oifname eth0     accept   tunnel → outside (already encrypted)
5  iifgroup 2  oifname eth0        drop     downstream → uplink: the leak
6  oifname eth0                    drop     kill switch
7  (bare)                          drop     catch-all
```

`iifgroup 2` means "arrived from a qube using this one as its netvm". Four
design points, each of which is load-bearing:

- **Every `accept` names the tunnel interface.** When the tunnel is down there
  is no state in which an accept can match, so the chain degrades to
  kill-switch-only rather than failing open.
- **Rule 3 is scoped on purpose.** A bare `ct state established,related
  accept` would also match a flow established *through* the tunnel that is now
  routing out `eth0` because the tunnel dropped — and `accept` is terminal, so
  it would never reach rules 5 and 6. That is precisely the leak this exists
  to stop. Scoping cannot break connectivity: the Qubes base forward chain
  carries its own unscoped established/related accept *after* the jump, so a
  legitimate packet this rule misses still gets through, while a leaked one
  hits a drop first.
- **Rule 7 exists because 5 and 6 name `eth0`.** Traffic leaving by any other
  interface would fall through to the base forward chain, which is `policy
  accept`. A second uplink — an attached NIC, a USB tether — would otherwise
  leak everything, silently.
- **Each family loads as one `nft -f` transaction.** Adding rules one at a
  time leaves the chain empty between the flush and the final add, and with a
  `policy accept` base chain that window is a real leak on *every* firewall
  reload. A transaction also means a rejected rule leaves the previous ruleset
  intact instead of a half-built one.

If the ruleset fails to load, the script flushes the chain and forces a bare
`oifname eth0 drop`. An empty chain would mean `policy accept`, so the failure
mode is closed, not open.

### Layer 2 — `qvm-firewall`, on the *named disposable*

Applied by `vpn-firewall-apply` to the running disposable, never the template
(a template with `netvm = none` filters nothing). Final order:

```
0  drop specialtarget=dns
1  drop proto=icmp
2  accept proto=<udp|tcp> dst4=<endpoint-ip> dstports=<port>   (one per endpoint)
…
N  drop                                                         (no address family)
```

The qube may reach the VPN server and nothing else.

**Enforcement happens in the qube's netvm, not in the qube.** So whatever
`uplink=` names has to be a qube that runs the Qubes firewall service.
`sys-firewall` does; a chained VPN qube does, since it is an AppVM with
`provides_network true`; `sys-net` generally does not, which is why the uplink
should not point straight at it. With `uplink=none` there is no netvm at all,
so these rules are configured but inert until the qube is attached.

Three further consequences worth knowing:

- **DNS is dropped deliberately**, so the qube cannot resolve hostnames. That
  is why `vpn-up` rewrites an OpenVPN `remote` to the whitelisted IP rather
  than leaving a hostname in the config.
- **The trailing `drop` carries no address family**, so it covers IPv6 too.
- `vpn-firewall-apply` **asserts** the last rule is a drop rather than just
  printing the list, and exits non-zero if it is not.

## Verify after build

```sh
qvm-prefs <dvm-template> netvm            # blank (none) — always
qvm-prefs <disposable> netvm              # whatever you set uplink= to
qvm-prefs <disposable> provides_network   # True
qvm-tags  <dvm-template> list             # vpn-endpoint
qvm-tags  <disposable> list               # vpn-endpoint
qvm-firewall <disposable> list            # last rule is an unconditional drop
```

The disposable's `netvm` should match your `uplink=` value exactly — normally
`sys-firewall`, another VPN qube's disposable if you are chaining, or blank if
you set `uplink=none` and intend to attach it by hand later. If it is blank
and you did *not* ask for `none`, the pillar did not reach `dispvm.sls`; check
the `'*-vpn-dvm'` glob in `srv/user_pillar/top.sls`.

Note that `uplink=none` means the Layer 2 (`qvm-firewall`) rules are in place
but **not yet enforced by anything** — those rules are applied by a qube's
netvm, and this qube has none. They take effect when you attach it. Layer 1,
inside the qube, is unaffected and works regardless.

In the disposable:

```sh
sudo journalctl -t vpn-up -t qubes-fw-user
sudo nft list chain ip  qubes custom-forward
sudo nft list chain ip6 qubes custom-forward   # must not be empty
ip link show wireguard                          # or vpn0
sudo stat -c '%a %n' /rw/config/vpn/*.conf      # 600
```

Every `accept` in `custom-forward` must name the tunnel interface, and the
chain must end with a bare `drop`. A bare `ct state established,related
accept` in that chain is a leak: it matches flows established through the
tunnel that are now routing out `eth0`, and `accept` is terminal, so they
never reach the drops below. The trailing `drop` covers the mirror-image
case — traffic leaving by an interface the earlier drops don't name.

**Kill-switch test — the one that actually matters:** with a downstream qube
online, run `sudo wg-quick down wireguard` in the disposable. Downstream
traffic must stop dead, not fall back to the clear.

## Status: verified vs. assumed

Checked against a running qube (`qubes-core-agent-4.3.47`, Fedora 43) — see
`ARCHITECTURE.md` for the detail:

- the firewall script path and its execute-bit/shebang requirement
- `custom-forward` exists in both `ip qubes` and `ip6 qubes` even with IPv6 off
- all six kill-switch rules load identically in both address families
- `oifname` accepts a not-yet-existing interface name; `oif` does not

- the Qubes base forward chain is `policy accept` and jumps to
  `custom-forward` first — which is why rule order in that chain, and
  applying it as one atomic `nft -f` transaction, are both security-relevant

### Why there is a hostile package at all

`tools/rpm/selftest-hostile.spec` is a deliberately malicious package that
exists to be rejected. Three reasons it is in the repo rather than something
run once and thrown away:

**An audit script that passes everything looks exactly like one that works.**
Feeding a checker good input tells you nothing — it returns PASS whether it is
sound or whether it is a stub. The only way to learn that a refusal actually
fires is to hand it something you *know* is bad and watch it refuse. Every
green run of `build-rpm.sh` is evidence only if the red run has been seen too.

**Nothing else in the toolchain will stop you.** `rpmbuild` builds a package
carrying a root cron job, a setuid binary, a symlink to `/etc/shadow`, an
`Obsoletes:` on `qubes-core-dom0` and a scriptlet that runs as root in dom0 —
and exits **0**. Its sole objection is one `warning: absolute symlink` line,
easily lost in build output. rpm is a packaging tool, not a security boundary,
and it does not pretend otherwise. If the check does not happen here, it does
not happen.

**It is what makes the signature mean something.** Signing proves origin, not
safety — a signed backdoor installs perfectly. The signature is only worth
trusting because the build qube refuses to sign anything that fails the audit,
so the audit's soundness is the load-bearing part. Testing it is testing the
one thing the whole dom0 install path rests on.

The fixture's header documents which check should catch which trait. If one of
them ever *passes*, that check is broken.

**Result — `vpn-rpm-audit` against the hostile package** (rpm 6.0.2, Fedora
43, 2026-09-07). `rpmbuild` built it and exited 0; the audit raised 14 FAIL
lines and exited 1, catching every planted trait:

- the `%post` scriptlet, the `Obsoletes: qubes-core-dom0`, the `Conflicts:`
- the setuid file, the world-writable file, the non-root owner
- the symlink to `/etc/shadow` — twice, once from header metadata (check 6)
  and again from the unpacked payload (check 9)
- the `%ghost`, the `/etc/cron.d` path, the compressed payload, and every
  manifest and source-tree mismatch

Two of the fourteen were not predicted when the fixture was written: rpm
injects a `/bin/sh` dependency whenever a scriptlet exists — *even under
`AutoReqProv: no`* — so check 4 catches install-time code independently of
check 3. Reproduce it with the commands in `selftest-hostile.spec`.

**`build-rpm.sh`, end to end** (same host and date). Three runs: unsigned
fails only check 2 and the package is deleted, exit 1; signed with a matching
key passes all 31 assertions and the package is kept, exit 0; signed with a
non-matching key fails check 2 and is deleted. Short key ids, `0x` prefixes
and spaced gpg fingerprints all match correctly.

Getting there took fixing two real bugs, both worth knowing about:

- **`brp-mangle-shebangs` rewrote the payload.** Fedora's rpmbuild runs
  policy scripts over the buildroot after `%install`; one of them rewrites
  `#!/bin/bash` to `#!/usr/bin/bash` in every file with the execute bit. The
  package therefore shipped bytes that were *not* the reviewed bytes —
  harmless in effect, fatal to the guarantee. Check 8 caught it, failing on
  exactly the ten 0755 files and no others. Fixed by setting
  `%global __os_install_post %{nil}` in the generated spec.
- **The `--key` check could never pass on rpm 6.** rpm 4/5 print
  `key ID <16 hex>`; rpm 6 prints `key fingerprint: <40 hex>`. The audit
  matched only the older wording, so a correctly signed package was reported
  as signed by "a different key: " — with nothing after the colon. A false
  failure in a security tool is worse than no check, because the sane
  response is to stop believing it. Now accepts either wording, and fails
  loudly if it can parse no key id at all rather than passing silently.

Neither would have been found by reading the scripts.

**Not checked** — dom0 was not accessible from the authoring qube:

- exact `qvm.present` / `qvm.prefs` / `qvm.tags` / `qvm.service` salt state
  argument forms against your Qubes salt version
- the `qrexec-client -d <vm> 'DEFAULT:QUBESRPC <service> dom0'` call form and
  the `user=user` policy qualifier
- `base_template` in the generated pillar defaults to `fedora-42-xfce` —
  change it to yours, and confirm it has `qubes-mgmt-salt-vm-connector`,
  `wireguard-tools`, and/or `openvpn` installed
- the `'*-vpn-dvm'` pillar glob in `srv/user_pillar/top.sls` — confirm your
  dvm template actually receives the pillar, or `vpn-params` will render
  empty
- **OpenVPN mode end to end.** The WireGuard path is the one the design was
  built around; the OpenVPN path (remote rewrite from the endpoint map,
  `dev` pinning, `tcp` transport) is reasoned-through but has not been run.
- **Installing the package in dom0.** The build and audit are proven (see
  *Verified* above), but no package has been transferred to dom0 or installed
  there. `rpm -Uvh`, the `.rpmnew` behaviour on upgrade, and `rpm -V` drift
  reporting are all reasoned-through and unexercised.
- **Chained VPN qubes end to end.** `vpn-build-all`'s own logic is tested
  (validation, ordering, MTU descent, failure handling — against stubbed
  `qvm-*` commands), but no chain has actually been brought up. Two things
  to watch when you first try it: whether your provider allows reaching one
  of its endpoints from inside another of its tunnels, and whether the real
  per-hop overhead matches the conservative figures above.

## Support

If this saved you an afternoon, a tip is welcome. Entirely optional — the
project is GPLv2 and stays that way either way.

**Bitcoin**

```
bc1qzv427sr20hvp3kuau32ctl8hp89krer5qcdgrj
```

**Monero**

```
455UkB9UWDPgJUxoUsLwqvMK6yh6k2sJ1PSU6spFbYT9h5ehwvEdcM5iHKBV5gwD3CBbovfPtUYMhWWUXcaLTyw45ifym6q
```

**Ethereum / EVM tokens**

```
0x1875Eb325f5a97009e24E9B4567f2f9A8d6F9A7e
```

> **Check before you send.** Addresses in a public README are a standing
> target for tampering — a swapped address in a pull request or a commit is a
> well-known way to redirect donations, and it is invisible unless someone
> looks. All three above carry their own checksums (bech32, EIP-55, and
> Monero's keccak checksum), so a wallet will reject a corrupted one, but a
> *substituted* valid address checks out fine. Compare against
> `git log -p -- README.md` if you want to see when they last changed.
