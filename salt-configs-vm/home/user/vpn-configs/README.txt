~/vpn-configs/   (in salt-configs-vm)

A set of selection files built in one go by dom0's vpn-build-all. Each file
has exactly the format of ~/vpn-selection.conf -- same keys, same validation.
Nothing new to learn; there is just more than one of them.

    vpn-build-all               # build the whole set
    vpn-build-all -n            # validate only, create nothing

To rebuild ONE of them after an edit, without touching the others, name it:

    vpn-build vpn-configs/20-de77.conf

Its uplink is read from the file as usual, so a chained qube stays chained.
What that gives up is the cross-config validation -- seeing one file,
vpn-build cannot check the mtu against its parent or spot a name collision
with another config. Run "vpn-build-all -n" first if more than that one file
changed.

NAMING

    NN-anything.conf            NN = 2 to 4 digits

Files that do not match are ignored, so an editor backup or a note in this
directory will not break a build. Two files sharing a number is an error --
the order is the entire point of the number.

Number in tens (10, 20, 30) so you can insert a hop later without renaming
everything, and keep the width the same across the set.

ORDER AND UPLINK ARE DIFFERENT THINGS

The number decides WHEN a config is built. The uplink field decides WHERE the
qube attaches. "20 comes after 10" does not mean "20 routes through 10" --
two independent VPN qubes both on sys-firewall are a perfectly normal set.

Chaining has one rule: a config's uplink may name a qube built by a
LOWER-numbered config, or a qube that already exists, or none. It may not
name a higher-numbered one. That single rule is also what makes a routing
loop impossible to write, so there is no cycle to detect.

CHAINING AND MTU

Each hop's tunnel has to fit inside the one it runs through -- about 60 bytes
per WireGuard hop, ~69 for OpenVPN/udp, ~89 for OpenVPN/tcp. So a chain
descends:

    sys-firewall 1500 -> 1420 -> 1360 -> 1300 ...

The floor is 1280, which puts a practical limit of about three WireGuard hops
on a 1500-byte uplink. vpn-build-all checks the whole descent before building
anything and tells you which hop does not fit. Use --no-mtu-check if your
provider's real overhead is smaller than the conservative figures above.

This is a check no single config can do: every mtu in a broken chain is
inside 1280-1500, so each file passes on its own. Get it wrong without the
check and you get a tunnel where pings work and anything large vanishes.

NOTHING IS BUILT UNTIL THE WHOLE SET VALIDATES

vpn-build-all reads every file, resolves the chain, checks the MTU descent,
and confirms endpoints exist for every country -- all before it creates the
first qube. A set that fails any of that is refused entirely.

That is deliberate. A half-built chain is worse than an unbuilt one: qubes
holding live key material, a child pointing at a parent that does not exist,
and nothing telling you which qubes were yours.

NOTHING IS STARTED EITHER

The build is a build. When it finishes it prints the start order -- a chained
qube needs its uplink running first -- and you start them yourself.

EXAMPLE SET

    10-uk123.conf    uplink=sys-firewall           entry hop
    20-de77.conf     uplink=nordvpn-uk123-vpn      chained inside it
    30-nl04.conf     uplink=none                   attach by hand later

Delete these and write your own; they are examples, not defaults.
