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
- [What you get](#what-you-get) — speed, consistency, kill switch, chaining
- [The qubes involved](#the-qubes-involved)
- [Using it](#using-it) — the four steps, briefly
- [Step 1 in detail: preparing your provider's configs](#step-1-in-detail-preparing-your-providers-configs) — the endpoint map
- [What happens when you run the build](#what-happens-when-you-run-the-build) — the full flow, build through first start
- [Seeing the status](#seeing-the-status) — terminal banner and prompt marker
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

## What you get

**Speed.** Switching country or server is one line in a text file and one
command. No qube to create, no package to install, no rules to write, no
config to copy. Building a second, third or fourth VPN qube costs the same
one command each — the manual route costs the whole procedure again, every
time.

**Consistency.** Every qube is built from the same salt states and the same
validated parameters, so they come out identical apart from the values you
chose. There is no "I think I set the MTU on that one" — the MTU, the
firewall ruleset, the file modes, the tunnel bring-up and the kill switch are
the same on qube five as on qube one. Hand-built VPN qubes drift; generated
ones cannot.

**Disposability.** The qube you use is a *named disposable*. Its root
filesystem is discarded and rebuilt every boot, so nothing accumulates in it
and nothing you do inside it persists. Rebuilding from scratch is a restart,
not a project. The tunnel comes up fresh each time from the config, which
means a broken state is fixed by turning it off and on again — genuinely, not
as a joke.

**A kill switch that fails closed.** If the tunnel drops, downstream traffic
stops rather than falling back to your clear connection. This is the part
hand-rolled setups most often get wrong, because the obvious firewall rule
(`ct state established,related accept`) is exactly the rule that leaks. Two
independent layers enforce it — see [The two firewalls](#the-two-firewalls).

**Chaining.** Point one VPN qube at another as its uplink and traffic goes
through both tunnels. `vpn-build-all` builds a whole set in order and checks
the things you cannot check one file at a time: name collisions, uplink
ordering, and whether each hop's MTU actually fits inside its parent's. Get
that last one wrong by hand and you get a tunnel where `ping` works and
anything large silently vanishes.

**Nothing is guessed.** Every value is validated against a strict pattern
before use, and anything that doesn't match aborts the build instead of
proceeding on a default. A misspelt country code fails loudly at the start
rather than producing a qube that doesn't work for reasons you get to
discover later.

## The qubes involved

Four things, and knowing which is which makes the rest of this document easier
to follow:

| Qube | Holds | Network |
|---|---|---|
| **dom0** | the build commands and the salt states | none, as always |
| **`salt-configs-vm`** | the settings file you edit, and an authoring copy of the salt states | normal |
| **`vpn-config-files-vm`** | your provider's configs and keys | `netvm = none` |
| *(generated)* `<provider>-<sel>-vpn-dvm` | the DVM template — created for you | `none`, fixed |
| *(generated)* `<provider>-<sel>-vpn` | the disposable you actually use | whatever you set `uplink=` to |

The practical reasons for the split: your provider's configs sit in an offline
qube, so you can't accidentally break them and nothing in there can phone
home; the settings file you edit weekly is somewhere separate from your keys;
and the build reads the two independently, which is why a bad settings file
can never damage your config collection.

Two consequences you will actually run into:

- **`vpn-config-files-vm` has no network at all** (`netvm = none`), which is
  why the endpoint map has to be built beforehand in a networked qube — see
  the next section.
- **The generated template has no network** and never runs. Only the
  disposable does. Firewall rules on the template do nothing, which is why
  `vpn-firewall-apply` targets the disposable.

The trust boundaries — what each qube can and cannot reach, what dom0 can see,
and where the design deliberately stops trying — are set out in
[`ARCHITECTURE.md`](ARCHITECTURE.md) §2. Short version: this is not, and
cannot be, protection *from* dom0; dom0 can read anything on the machine. The
security effort goes into limiting what flows *into* dom0 instead.

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

Because it needs to resolve hostnames, and this is the only moment in the
entire workflow that can. Three different reasons:

- **`vpn-config-files-vm` has `netvm = none`** — no network at all, so
  nothing to resolve *with*
- **dom0 has no network** either
- **the VPN qube has network but DNS specifically dropped**, by the
  `qvm-firewall` rules dom0 applies to it (Layer 2 under
  [The two firewalls](#the-two-firewalls))

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
# <config-filename> <ip>:<port> <udp|tcp>   -- hostnames already resolved
uk123.mullvad.net.conf 193.32.249.66:51820 udp
uk124.mullvad.net.conf 193.32.249.67:51820 udp
```

That file is the *only* thing dom0 ever reads out of `vpn-config-files-vm`.
It contains no key material — just which server is at which address — which
is what lets dom0 build the firewall without ever touching your keys.

#### The third column, and why it exists

The protocol is recorded **per config**, not once for the country. A provider's
country folder can legitimately mix UDP/1194 and TCP/443 servers in the same
directory, but `transport=` in the pillar is a single value applied to the
whole country. Without the third column, half of such a folder gets whitelisted
on the wrong protocol — and because the config is chosen at random inside the
qube, the result is a tunnel that works on most boots and fails on the ones
that happen to draw a server from the wrong half.

For OpenVPN the protocol is read from the config's own `remote host port proto`
line, or a standalone `proto` directive, or defaults to `udp` as OpenVPN itself
does. `proto-force` is deliberately not treated as `proto` — it is a filter,
not a setting. WireGuard is always `udp`; there is nothing to disambiguate.

If a config names a protocol the script does not recognise, it is **skipped
rather than guessed**, because a firewall rule on the wrong protocol fails
silently.

**A map without the third column still works.** `vpn-endpoints-fetch` treats it
as optional, falls back to the global `transport=`, and prints one warning
telling you to regenerate the map if that country mixes transports. That is
exactly what the pipeline did before the column existed, so an older map is
never rejected — only flagged.

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

You type one command in dom0: `vpn-build`. What follows is the whole flow,
from that command to a disposable you can point other qubes at.

### Two qubes get created, and they are different things

Worth being clear about this up front, because the names are similar and the
roles are not:

- **`<provider>-<sel>-vpn-dvm`** — an **AppVM**, created from your base
  template, with `template_for_dispvms` set. That flag is what makes it usable
  as a disposable template. Its `netvm` is fixed at `none` — hardcoded in
  `dvmtemplate.sls`, not something you configure — and **it never runs**. It
  exists to hold the scripts and configs that every disposable spun from it
  inherits.
- **`<provider>-<sel>-vpn`** — a **named DispVM** whose template is the AppVM
  above. This is the one that actually runs, holds the live tunnel, and serves
  as `netvm` for your other qubes. Its own `netvm` is the one setting you
  control here, via `uplink=` in the settings file.

It is a *named* disposable rather than an ad-hoc `disp####` precisely so other
qubes can reference it by name. Its root filesystem is discarded and recreated
from the template on every start; only the private volume persists, which is
why an explicit `qvm-prefs` value on it survives resets.

### The build, in order

1. **Read your choice and validate it.** `vpn-params-fetch` pulls the settings
   file from `salt-configs-vm` and checks every value against a strict pattern
   — protocol must be `wireguard` or `openvpn`, transport `udp` or `tcp`, MTU
   within `[1280, 1500]`, the selector `^[a-z]{2}([0-9]{1,4})?$`. Anything that
   doesn't match aborts the build rather than falling back to a default. The
   validated values are written to dom0's pillar, which is how they reach the
   salt states.
2. **Derive the names and create both qubes.** `uk123` becomes
   `nordvpn-uk123-vpn-dvm` and `nordvpn-uk123-vpn`. The AppVM template gets
   `netvm = none` unconditionally, plus `provides_network`, the `vpn-endpoint`
   tag, the `qubes-firewall` service enabled and `network-manager` disabled.
   The disposable gets the same tag, `provides_network`, `autostart false`,
   and — the one value taken from your settings file — `netvm` set to the qube
   your `uplink=` named.
3. **Install the scripts into the template.** `vpn-up`, `rc.local`, the
   firewall script, the MTU hook, the status poller and banner, and the
   rendered `vpn-params` file are placed inside the AppVM template, so every
   disposable started from it has them already. They go into `/rw/config/`
   specifically — that is on the private volume, which is the only thing a
   disposable inherits. This step runs through the management disposable
   rather than dom0.
4. **Fetch the endpoint list.** dom0 asks `vpn-config-files-vm` for the
   `endpoint-map.txt` lines for your country and validates each one is a real
   IP and port — including rejecting octets with leading zeros — before any of
   it reaches a firewall command.
5. **Lock down the firewall (Layer 2) first.** The disposable is restricted to
   the whitelisted server addresses on the right transport and port, with DNS
   and ICMP dropped and a terminal `drop`. Each endpoint is whitelisted on the
   protocol its own map line names, so a country folder mixing UDP and TCP
   servers gets each one right; `transport=` is the fallback for map lines that
   predate the protocol column. Duplicate endpoints — providers routinely point
   several configs at one address — collapse into a single rule. Every argument
   is validated *before* any rule is applied, so a rejected endpoint leaves the
   qube's existing ruleset untouched rather than part-rewritten. This all
   happens *before* any config arrives, so there is never a window in which the
   qube has key material and an open firewall.
6. **Deliver the configs.** Only now does dom0 tell `vpn-config-files-vm` to
   copy the real configs — private keys included — directly to the template.
   **How many depends on what you asked for:** name a specific server
   (`uk123`) and exactly one config is sent; name a country (`uk`) and *all*
   of that country's configs are sent. The endpoint map travels with them, and
   `auth-user-pass.txt` too if your provider needs credentials. The contents
   don't pass through dom0, which keeps them out of its disk and logs — not a
   barrier against dom0 itself, which could read them regardless.
7. **Secure what arrived.** The files are moved out of `~/QubesIncoming` into
   root-owned `0700` storage at `0600` each.
8. **Check every delivered config has a whitelisted endpoint**, then shut the
   template — which the file copy had started — back down. This compares two
   sets that are built independently: the configs that arrived (a `*.conf`
   glob in `vpn-config-files-vm`) against the endpoints step 4 validated. If
   any config has no endpoint, the build says so and names the count. Nothing
   unsafe follows from a mismatch — `vpn-up` will not pick such a config — but
   it means your random pool is smaller than the country folder looks, and
   that is worth knowing at build time rather than discovering it later.

At this point nothing is running. The build is a build; it deliberately starts
nothing.

### Then you start it

```sh
qvm-start <provider>-<sel>-vpn
```

The disposable boots with a fresh root filesystem from the template, and:

1. **The kill switch goes up before the tunnel exists.** The
   `qubes-firewall` service runs `qubes-firewall-user-script`, which installs
   the Layer 1 nftables rules. With no tunnel interface yet, the chain is
   kill-switch-only — nothing can pass through this qube.
2. **`rc.local` runs `vpn-up`, which selects a config.** If you named a
   specific server there is one config and it is used. If you named a country,
   one is picked at random from those delivered — a fresh draw at every start,
   so the same disposable does not keep using the same server.

   The draw is not made from every config in the folder. It is made only from
   configs that have an `endpoint-map.txt` entry, because those are the ones
   step 5 could whitelist. Excluded configs are named in the log, and if
   *nothing* qualifies `vpn-up` refuses to continue and the qube stays
   kill-switched.

   That filter exists because the two lists were previously built by different
   code with different rules: the pool from a plain `*.conf` glob, the firewall
   allow list from map lines behind a much stricter check. A config could pass
   one and fail the other — a provider's `uk123.nordvpn.com.tcp.conf` second
   suffix, or a server whose hostname would not resolve when the map was
   built — and then sit in the pool with no firewall rule behind it, failing on
   whichever future boot happened to select it. With the kill switch doing its
   job the only symptom would be downstream qubes quietly losing the network.
3. **The endpoint comes from the map, not the config.** `vpn-up` looks up the
   chosen config's whitelisted `IP:PORT` in `endpoint-map.txt`, so the tunnel
   can only be aimed somewhere the firewall already permits. For WireGuard it
   warns if the config's own `Endpoint` disagrees; for OpenVPN it rewrites
   `remote` to the whitelisted address, because DNS is dropped and a hostname
   could never resolve. The transport comes from the same line, so a config in
   a mixed folder is dialled on the protocol dom0 actually whitelisted for it.
4. **The tunnel comes up**, with the MTU you chose injected, and the interface
   name pinned rather than guessed — WireGuard configs are installed under a
   fixed name because the kernel caps interface names at 15 characters and a
   provider filename easily exceeds it.
5. **The tunnel is checked for life, and a dead server is dropped for another.**
   Providers retire servers, and in random mode there are usually dozens of
   alternatives sitting in the same folder, so one dead draw should not cost the
   whole boot. `vpn-up` makes up to three attempts, drawing a *different* config
   each time — a server that just failed is removed from the pool rather than
   re-drawn.

   Checking for life is the part that makes this meaningful. **WireGuard has no
   connection state:** `wg-quick up` creates the interface whether or not the
   peer ever answers, so the interface existing proves nothing. `vpn-up` waits
   up to 15 seconds for an actual handshake (a live peer retries about every
   5 seconds, so that is three chances). OpenVPN only creates the tun device
   once it has connected, so there the interface appearing *is* the signal, and
   what remains is confirming the unit did not exit straight afterwards. Between
   attempts the old tunnel is torn down and `vpn-up` waits for its interface to
   actually disappear — otherwise the next attempt's interface check would pass
   instantly on the corpse of the previous one.

   Some failures are not worth retrying. A missing `auth-user-pass.txt` is
   account-wide, so every other config would fail identically; `vpn-up` says so
   and stops rather than burning two more attempts on the same message.

   Three attempts at up to 15 seconds each is roughly 45 seconds worst case.
   The budget is for boot delay as much as for reliability — a broken uplink
   should not stall the qube for minutes. In specific-server mode there is
   nothing to fall back to, so there is one attempt.
6. **The firewall script re-runs now the tunnel is real**, so its accept rules
   name the live interface. If no interface ever appears, `vpn-up` reapplies the
   kill switch and exits — the qube stays closed rather than falling open. If an
   interface *is* up but never carried traffic, it is left in place on purpose:
   WireGuard is connectionless, so a merely slow or briefly unreachable server
   may still establish on its own, whereas tearing it down leaves the qube dead
   until someone notices. Nothing leaks either way — traffic can only leave
   through the tunnel — and the status banner reports `DOWN`, so it is not
   silent.
7. **Downstream MTU is set** by the `90-vif-mtu` hook as other qubes attach,
   so their packets fit inside the tunnel's overhead.
8. **The status poller starts.** `rc.local` also installs the terminal banner
   into `/etc/profile.d/` and launches `vpn-statusd` as a transient systemd
   unit. From then on, opening a terminal in the qube tells you where things
   stand — see below.

Now point other qubes at it:

```sh
qvm-prefs <some-qube> netvm <provider>-<sel>-vpn
```

Every subsequent start repeats steps 1–8 from scratch. Nothing accumulates in
the disposable, and a broken tunnel is fixed by restarting it.

## Seeing the status

Open a terminal in the VPN qube and it tells you immediately:

```
  VPN    UP       wireguard on wireguard - last handshake 24s ago [uk123.nordvpn.com.conf]
         ARMED    kill switch armed - 7 rules, terminal drop present
```

and when the tunnel has died:

```
  VPN    DOWN     wireguard on wireguard - last handshake 847s ago, stale (>180s)
         ARMED    kill switch armed - 7 rules, terminal drop present
```

That second line is the one worth having. With a kill switch, a dead tunnel is
silent by design — downstream qubes just stop working, and nothing tells you
whether you are safely blocked or quietly leaking. `ARMED` means blocked.

There is also a marker in the prompt, so it cannot go stale while you sit in
the terminal:

```
[VPN up] [user@nordvpn-uk123-vpn ~]$
```

Opt out with `export VPN_STATUS_NO_PS1=1`.

### Why it needs a root helper

The two facts most worth knowing are both privileged, so a banner running as
`user` cannot get at them:

- **WireGuard has no connection state.** `wg-quick` creates the interface and
  it stays there forever whether or not the peer ever answers a single packet.
  Checking `/sys/class/net/wireguard` reports green on a stone dead tunnel. The
  only real signal is the last handshake time, and reading it needs
  `CAP_NET_ADMIN`.
- **Reading the nftables ruleset needs root**, so nothing unprivileged can
  confirm the kill switch is loaded.

So `vpn-statusd` runs as root, checks every 30 seconds, and writes its verdict
to `/run/vpn-status` — mode `0644`, on tmpfs, so it is empty at boot by
definition and can never persist into a fresh disposable. Everything else just
reads that file and needs no privilege at all.

It is launched with `systemd-run` rather than `&`, because the unit that runs
`rc.local` (`qubes-misc-post.service`) is `Type=oneshot` and a plain background
child sits in a cgroup systemd may reap. As a transient unit it restarts if it
dies and is inspectable:

```sh
systemctl status vpn-statusd
journalctl -u vpn-statusd
```

If the poller dies, the banner says so rather than showing you its last known
state — both it and the prompt marker treat a status file older than 150
seconds as no status at all.

### Where the files live, and why

`/etc/profile.d/` is on the **root volume**, which is a copy-on-write snapshot
of the base template, discarded at shutdown and re-copied at every start. A
file placed there would never reach a disposable. Only the private volume
(`/rw` and `/home`) is inherited. So the master copy lives at
`/rw/config/vpn-status.sh` and `rc.local` installs it into place on every boot.

### One thing it deliberately does not do

It does not send anything to dom0. In Qubes 4.3 `notify-send` is **not** local
— `qubes-notification-agent` proxies it over qrexec to dom0, which renders it.
The one provider-controlled string in the status output is the selected
config's filename, which comes out of your provider's download; `vpn-statusd`
scrubs it to printable ASCII at write time rather than in each reader, so
every consumer inherits that, including anything added later that does cross
into dom0.

## Repository layout

```
dom0/                                    installed on dom0
  srv/user_salt/vpn/                     salt states — qube creation, prefs, tags
    init.sls / dvmtemplate.sls / dispvm.sls / vmfiles.sls
    files/                               payload placed inside the VPN qube
      qubes-firewall-user-script         the kill switch
      90-vif-mtu                         MTU hook for downstream vifs
      vpn-up                             tunnel bring-up, run at boot
      rc.local                           installs the banner, starts the
                                         poller, then runs vpn-up
      vpn-statusd                        root status poller -> /run/vpn-status
      vpn-status.sh                      terminal banner + prompt marker
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
   It has to happen here — it's the only step in the whole workflow that can
   resolve a hostname at all.
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
   qube: `tools/rpm/build-rpm.sh --sign <KEYID>`, which builds, signs, and
   audits its own output, deleting the package if any check fails. Then in
   dom0: pull the `.rpm`, `rpmkeys -Kv` it, `sudo rpm -Uvh`.

   You only do this once — the state tree does not change per build, and
   everything build-specific reaches it as pillar data. Upgrades are
   `rpm -Uvh` again, and `rpm -V qubes-vpn-dvm-dom0` tells you whether what is
   in dom0 is still what you installed.

   Full procedure — generating the key, getting its fingerprint into dom0,
   what the audit checks and why signing alone is not enough — is in
   [`docs/getting-files-into-dom0.md`](docs/getting-files-into-dom0.md).
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
- **endpoint availability** — asked up front, rather than at step 4/8 after
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

`iifgroup 2` means "arrived from a qube using this one as its netvm".

What this buys you in practice:

- **The tunnel dropping is not a leak.** Every `accept` names the tunnel
  interface, so when it is gone there is no state in which an accept can
  match. The chain degrades to kill-switch-only instead of failing open.
- **A second uplink is not a leak either.** Rules 5 and 6 name `eth0`, so rule
  7 catches anything leaving by a different interface — an attached NIC, a USB
  tether — which would otherwise slip past into a `policy accept` base chain.
- **Reloading the firewall is not a leak.** Each address family loads as one
  `nft -f` transaction, so there is no window where the chain sits empty.
- **A failed load is not a leak.** If the ruleset won't load, the script
  forces a bare `oifname eth0 drop` rather than leaving an empty chain.
- **IPv6 is covered whether you use it or not**, so enabling it later cannot
  quietly open a hole.

Rule 3 is the subtle one, and it is where hand-written versions of this
usually go wrong: it is scoped to the tunnel interface rather than being a
bare `ct state established,related accept`, because the bare form also matches
flows established *through* the tunnel that are now routing out `eth0` — and
`accept` is terminal, so those never reach the drops below.
[`ARCHITECTURE.md`](ARCHITECTURE.md) §4 works through why each rule is shaped
the way it is, and why scoping it cannot break legitimate return traffic.

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

**Enforcement happens in the qube's netvm, not in the qube.** So the qube your
`uplink=` names has to be one that runs the Qubes firewall service.
`sys-firewall` does; a chained VPN qube does, since it is an AppVM with
`provides_network true`; `sys-net` generally does not, which is why you should
not point `uplink=` straight at it. Write `uplink=none` and the disposable has
no netvm, so these rules are configured but inert until you attach one.

Three further consequences worth knowing:

- **DNS is dropped deliberately**, so the qube cannot resolve hostnames. That
  is why `vpn-up` rewrites an OpenVPN `remote` to the whitelisted IP rather
  than leaving a hostname in the config.
- **The trailing `drop` carries no address family**, so it covers IPv6 too.
- `vpn-firewall-apply` **asserts** the last rule is a drop rather than just
  printing the list, and exits non-zero if it is not.

## Verify after build

```sh
qvm-prefs <dvm-template> netvm            # blank — hardcoded, not configurable
qvm-prefs <disposable> netvm              # the qube named by uplink=, or blank
qvm-prefs <disposable> provides_network   # True
qvm-tags  <dvm-template> list             # vpn-endpoint
qvm-tags  <disposable> list               # vpn-endpoint
qvm-firewall <disposable> list            # last rule is an unconditional drop
```

Two different things are being checked there, and only one of them is yours to
set:

- **The template's `netvm` is always blank.** `dvmtemplate.sls` sets it to
  `none` unconditionally, and `uplink=` has no bearing on it. If this is not
  blank, something is wrong.
- **The disposable's `netvm` is the qube your `uplink=` named.** It should
  match exactly — normally `sys-firewall`, or another VPN qube's disposable if
  you are chaining. It is blank only if you wrote `uplink=none`. If it is
  blank and you did *not* write that, the pillar never reached `dispvm.sls`;
  check the `'*-vpn-dvm'` glob in `srv/user_pillar/top.sls`.

If you did write `uplink=none`, the Layer 2 (`qvm-firewall`) rules are in
place but **not yet enforced by anything** — those rules are applied by a
qube's netvm, and this one has none. They take effect when you attach it.
Layer 1, inside the qube, is unaffected and works regardless.

In the disposable:

```sh
sudo journalctl -t vpn-up -t qubes-fw-user
sudo nft list chain ip  qubes custom-forward
sudo nft list chain ip6 qubes custom-forward   # must not be empty
ip link show wireguard                          # or vpn0
sudo stat -c '%a %n' /rw/config/vpn/*.conf      # 600

systemctl status vpn-statusd                    # the status poller
cat /run/vpn-status                             # what the banner is reading
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

**The packaging tools** (rpm 6.0.2, Fedora 43, 2026-09-07). `build-rpm.sh`
runs clean end to end: signed with a matching key it passes all 31 assertions
and keeps the package; unsigned, or signed by the wrong key, it fails and
deletes the package. `vpn-rpm-audit` raises 14 failures against the
deliberately hostile test package in `tools/rpm/selftest-hostile.spec`,
catching every planted trait.

Testing that turned up two bugs that reading the code had not — rpmbuild
silently rewriting shebangs in the payload, and the signing-key check being
impossible to pass on rpm 6. Both fixed; the detail, and why the hostile
package is in the repo at all, is in
[`docs/getting-files-into-dom0.md`](docs/getting-files-into-dom0.md).

**The status indicator** (same qube, Fedora 43). Verified by running it:

- `systemd-run` keeps a transient unit alive after the launching script exits,
  restarts it, and stops it cleanly — which is why `rc.local` uses it rather
  than `&`
- the kill-switch parser, against synthetic nftables chains covering all four
  cases: chain absent, chain empty, the real 7-rule ruleset, and the ruleset
  with its terminal `drop` removed. The last is the one that matters — a
  chain ending in `oifname "eth0" drop` still contains a drop but is not
  fail-closed, and is correctly reported as `open`
- the filename sanitiser, against a name carrying ANSI escapes and a
  `$(...)` substitution: escapes neutralised, no command execution
- the banner in every state — healthy, tunnel down, poller dead, status file
  corrupt, truncated, and absent — plus silence in a non-interactive shell and
  colour suppressed when stdout is not a tty

That found one bug: the prompt marker read the state word without checking the
timestamp, so it kept reporting `[VPN up]` after the poller had died. The
staleness check now lives in the shared reader, so the banner and the marker
cannot disagree.

**Not verified:** the WireGuard and OpenVPN branches of `vpn-statusd` have not
run against a live tunnel — the authoring qube has neither. The handshake-age
logic and the `openvpn-client@vpn` unit query are reasoned-through only.

**The random-mode pool filter** (same qube). Tested by running the real
`vpn-up` text with its paths redirected at a fixture directory, rather than a
re-typed copy of the logic:

- 200 consecutive draws from a folder of 10 configs with only 3 mapped picked
  one of those 3 every time and an unmapped config never
- the real-world case — a provider shipping `uk11.nordvpn.com.tcp.conf`
  alongside `uk11.nordvpn.com.conf` — excludes exactly the `.tcp` file
- fails closed when the map matches nothing, and when the map is absent
  entirely, with a different message for each
- the exclusion log is capped at 10 names plus a count, so a large folder with
  a stale map cannot turn one boot into thousands of log lines
- a config filename containing a literal newline is excluded rather than split
  into two candidates — including when the map holds two lines that would
  concatenate to match it
- specific mode is unchanged: no filter, no map required to select
- clean under `busybox sh` as well as bash, so the `#!/bin/sh` shebang holds

Build step 8's counter was tested the same way, against folders with all, some
and none of the configs mapped, no map, no configs, and a missing directory.
Testing dom0's side of it found two bugs, both from trusting the AppVM's reply
further than intended: a 22-digit count passed `^[0-9]+$`, overflowed bash
arithmetic and printed `[: integer expected` before reporting "ok" anyway; and
`mapped > configs`, which the counter cannot produce, also reported "ok". The
digits are now length-bounded and the impossible case is treated as an
unreadable answer.

**Not verified:** neither has run in a real disposable, because that needs a
built qube in dom0. What was exercised is the selection and counting logic on
fixtures, not the boot path around it.

**Per-config transport and the retry loop** (same qube, same method — the real
script text driven against fixtures, with a diff proving the only change was
the path prefix).

`build-endpoint-map.sh` was run end to end over a country folder mixing UDP,
TCP and WireGuard configs, and against twelve `remote`/`proto` shapes:
`remote host port proto`, `remote host proto`, `remote host` alone, a
standalone `proto`, `proto tcp-client`, `UDP4`/`tcp6-client` casing and
suffixes, extra whitespace, a second `remote` line, `remote-random`, and
`proto-force`. The last two are the ones that bite: `remote-random` must not be
read as a `remote`, and `proto-force` must not be read as a `proto` — both are
correctly ignored. An unrecognised protocol (`sctp`) is skipped, not guessed.

`vpn-endpoints-fetch` was driven through a stubbed qrexec against three-column,
two-column and mixed maps: protocols pass through as `IP:PORT/PROTO`, legacy
lines emit bare `IP:PORT` and raise exactly one warning for the whole map, the
warning goes to stderr so `mapfile` cannot swallow it into the endpoint list,
and a bogus third column is rejected outright rather than forwarded.

`vpn-firewall-apply` was driven through a stubbed `qvm-firewall`: per-endpoint
protocols produce per-endpoint rules, `-p` covers endpoints without one, exact
duplicates collapse while the same address on a *different* protocol correctly
stays a separate rule, and the terminal drop assertion still holds. Testing it
found a fail-open: a validation failure part-way through the loop left the qube
with the blanket accept already deleted, some accepts applied, and the terminal
`drop` — added only after the loop — never reached. Validation now completes
before anything is applied, so a rejected argument is a no-op against the
running qube. Verified by re-running the failing case and confirming the
existing ruleset is unchanged.

`vpn-up`'s retry loop was tested with scripted stubs standing in for
`wg-quick`, `wg` and `systemctl`, covering: first draw live; one and two dead
draws before a live one; all three dead; the interface never appearing; the
bring-up command itself failing; and a pool smaller than the attempt budget.
Confirmed in each case that a failed server is removed from the pool rather
than re-drawn, that teardown happens between attempts, that `/run/vpn-selected`
names the config actually in use rather than the first tried, that exhausting
the pool ends the loop instead of spinning, and that the two exit paths behave
differently on purpose — no interface at all reapplies the kill switch and
exits 1, while an interface that never handshaked is left up with a warning.
A 100-run repeat confirmed the pool filter still holds under retry: only
whitelisted configs are ever drawn, and each at most once per boot. The
OpenVPN branch was checked to emit `proto udp` and `proto tcp-client` from two
configs in the *same* folder under a single global `transport=udp` — the case
the third column exists for — and to fall back to `transport=` in both
directions on a two-column map. A missing `auth-user-pass.txt` stops after one
attempt rather than three.

**Not verified:** none of this has faced a real peer. The handshake check, the
`openvpn-client@vpn` unit query and the interface-disappearance wait were
exercised against stubs that model the documented behaviour, not against
`wg-quick` and OpenVPN themselves.

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
- **Installing the package in dom0.** Building and auditing it is proven, but
  no package has been transferred to dom0 or installed there. `rpm -Uvh`, the
  `.rpmnew` behaviour on upgrade, and `rpm -V` drift reporting are all
  reasoned-through and unexercised.
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
