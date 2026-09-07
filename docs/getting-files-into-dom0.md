# Getting the files into dom0

How to get the dom0 half of this project into dom0 as **one signed package**
you can verify, list, check for drift and cleanly remove — instead of an
archive you unpack and hope about.

---

## The short version

**dom0 is the most protected part of Qubes. Nothing is allowed to hand it
files.** There is no "copy to dom0" — Qubes leaves that service out on
purpose. So the only way in is the other direction: dom0 reaches out and
grabs the file itself.

That never changes. What changes is *what* it grabs and *what it does with
it*:

```sh
# in dom0
qvm-run --pass-io --no-gui vpn-rpm-build 'cat ~/rpmbuild-vpn/RPMS/noarch/qubes-vpn-dvm-dom0-1.0.0-1.noarch.rpm' > pkg.rpm
rpmkeys -Kv pkg.rpm          # must say: Signature ... OK
sudo rpm -Uvh pkg.rpm
```

Three lines. dom0 pulls one file, checks a signature, and installs. Every
piece of inspection happens somewhere else, beforehand.

---

## What signing actually buys you — and what it does not

This is worth getting straight before you follow the recipe, because it is
easy to over-trust.

**A GPG signature answers exactly one question: did this package leave my
build VM unmodified?** That is all. It is a statement about *transit and
storage*, not about *contents*.

So, plainly:

- **Signing does not remove the need to check the package.** If you sign a
  package containing a backdoor, you get a validly signed backdoor. dom0 will
  install it without complaint, because the signature is perfectly good.
- **Signing does not defend against a compromised source qube.** If
  `salt-configs-vm` hands the build VM a poisoned `vpn-build`, the build VM
  will faithfully package it and faithfully sign it. This is the main threat
  in this project's model, and signing does nothing about it.

An RPM is in some ways **more** dangerous than the tar it replaces. It can do
things a tar cannot:

| RPM can | Consequence |
|---|---|
| `%pre` / `%post` / `%pretrans` / `%posttrans` scriptlets | **Arbitrary code as root in dom0 at install time**, before you have run anything yourself |
| Absolute paths as standard | No "strip leading `/`" backstop — tar had one, rpm does not, because absolute paths are the whole design |
| `Obsoletes:` / `Conflicts:` | Have dnf *remove* another dom0 package. `Obsoletes: qubes-core-dom0` is a valid line |
| `%ghost` entries | Create and delete paths that are not in the payload at all, so nothing you inspected covers them |
| Compressed payload by default | Reintroduces the decompression-bomb surface the tar workflow deliberately avoided |

So the honest summary is: **signing does not replace the checking; it
relocates it.** That relocation is the real win, and it is a big one.

With the tar workflow, dom0 had to inspect the archive itself. The inspection
ran on the machine you were protecting, using dom0's own `tar` on bytes
another qube chose — you were exposed *before* you had read a single line.

With this workflow:

- every check runs **in the build VM**, on a package that has not been near
  dom0. If a malformed package crashes a parser, it crashes an ordinary qube
  you can delete and rebuild.
- dom0 does two things only: **verify a signature, and install.**
- the signature is what makes that split trustworthy. It is the thing that
  lets dom0 conclude "this is the same bytes the build VM audited" without
  re-doing the audit.

The signature is not the security. The signature is what lets the security
happen somewhere safe.

**And none of it tells you the code is safe to run as root.** That check has
no script and never will. See [Read the source](#5-read-the-source-this-is-the-real-step).

---

## The checking is a script, and it lives in the build VM

`tools/rpm/vpn-rpm-audit` interrogates a built `.rpm` and refuses it unless
every one of these holds:

| # | Check |
|---|---|
| 1 | rpm can parse the header at all |
| 2 | Signature verifies, and against the key you expected |
| 3 | **No scriptlets, no triggers, no file triggers** — nothing executes at install time |
| 4 | No `Obsoletes`, `Conflicts`, `Recommends`, `Suggests`, `Supplements`, `Enhances`; `Requires` limited to `rpmlib()` features |
| 5 | Payload is uncompressed cpio; file size, installed size and expansion ratio all within caps |
| 6 | Every path: absolute, no `..`, no doubled slash, no control characters, inside an allowed prefix; regular files and directories only — no symlink, device, fifo or socket; no setuid, setgid, sticky, group- or world-writable; owned `root:root`; no `%ghost` or `%missingok` |
| 7 | The file set matches `tools/rpm/manifest.txt` exactly — nothing missing, nothing extra, every mode and every `%config` marking as listed |
| 8 | Every file's SHA-256 matches the reviewed source tree in `dom0/` |
| 9 | The payload is unpacked and compared against the header, so the header's claims are not taken on trust |

Check 8 is the one that makes the signature mean something. The signature says
the package left the build VM intact; check 8 says the package contains the
bytes you actually read, and no others.

`vpn-rpm-audit` **refuses to run in dom0.** Unpacking a payload and running
rpm's parsers over attacker-chosen bytes is the exact thing this workflow
exists to keep out of dom0. Auditing there would reintroduce it.

`tools/rpm/manifest.txt` is the list to review. It is the single source of
truth: `build-rpm.sh` generates the spec's `%files` from it, and
`vpn-rpm-audit` checks the finished package against it. They run in opposite
directions on purpose — one says what should be there, the other asks what is
there — so a build that goes wrong shows up as a mismatch rather than as
agreement.

### Check the checker first

An audit script that passes everything looks exactly like an audit script that
works. Before you trust it, make it fail.

Do this on your first run, and do not skip it — not because the audit is
unproven, but because it is the only way to know it is working *on your
machine, against your rpm version*.

Both scripts have been exercised on rpm 6.0.2 / Fedora 43. `vpn-rpm-audit`
raises 14 FAIL lines and exits 1 on the hostile package; `build-rpm.sh` passes
all 31 assertions when signed with a matching key, and deletes the package
when unsigned or signed by the wrong one.

That testing found two bugs that reading the code had not. Both are fixed, and
both are worth knowing about because they show what this kind of testing
actually catches:

- **`brp-mangle-shebangs` was rewriting the payload.** Fedora's rpmbuild runs
  policy scripts over the buildroot after `%install`; one of them rewrites
  `#!/bin/bash` to `#!/usr/bin/bash` in every file carrying the execute bit.
  The package therefore shipped bytes that were *not* the reviewed bytes —
  harmless in effect, since `/bin` is a symlink to `/usr/bin`, but fatal to
  the guarantee the whole install path rests on. Check 8 caught it, failing on
  exactly the ten 0755 files and no others. Fixed with
  `%global __os_install_post %{nil}` in the generated spec.
- **The `--key` check could never pass on rpm 6.** rpm 4/5 print
  `key ID <16 hex>`; rpm 6 prints `key fingerprint: <40 hex>`. The audit
  matched only the older wording, so a correctly signed package was rejected
  as signed by *"a different key: "* — with nothing after the colon. A false
  failure in a security tool is worse than no check at all, because the
  reasonable response to it is to stop believing the tool. It now accepts
  either wording, matches a short id as a suffix of the fingerprint, and
  **fails loudly** if it can parse no key id rather than passing silently.

**Both bugs were version-specific**, which is the argument for running this
yourself rather than trusting the result above: your rpm may differ from the
one this was tested against, in exactly the way that produced these two.

And one reason the fixture stays in the repo rather than being run once and
deleted: the signature is only worth trusting because the build refuses to
sign anything that fails the audit. That makes the audit's soundness the
load-bearing part of the entire dom0 install path — so it is the one thing
worth re-testing whenever the toolchain underneath it changes.

`tools/rpm/selftest-hostile.spec` builds a package carrying one instance of
each thing `vpn-rpm-audit` is supposed to refuse: a `%post` scriptlet, a
symlink to `/etc/shadow`, a setuid file, a world-writable file owned by
`user`, a `%ghost`, `Obsoletes: qubes-core-dom0`, a file in `/etc/cron.d`, and
a compressed payload.

```sh
# in vpn-rpm-build, never in dom0
mkdir -p /tmp/selftest
rpmbuild --define "_topdir /tmp/selftest" -bb ~/vpn-build/tools/rpm/selftest-hostile.spec
bash ~/vpn-build/tools/rpm/vpn-rpm-audit /tmp/selftest/RPMS/noarch/vpn-audit-selftest-*.rpm
```

You want `RESULT: FAILED`, exit status 1, and **14** `FAIL` lines. The spec's
header lists which check should catch which trait; if one of them *passes*,
that check is broken and you should not rely on it.

Worth noticing while you do this: **`rpmbuild` builds all of it and exits 0.**
Its sole objection is one line —

```
warning: absolute symlink: /srv/user_salt/vpn/peek -> /etc/shadow
```

— and nothing at the packaging layer stops you shipping a setuid binary, a
root cron job, an `Obsoletes:` on `qubes-core-dom0`, or a scriptlet that runs
as root in dom0. One warning, easily lost in build output, against nine
traits. That is why the audit exists rather than being left to rpm.

One result is worth understanding rather than just observing: check 4 fails
with an unexpected `/bin/sh` requirement. rpm adds that dependency because a
scriptlet exists, **even though the spec sets `AutoReqProv: no`**. Install-time
code leaks into dependency metadata, so checks 3 and 4 catch it by two
unrelated routes. Likewise the symlink fails check 6 (from the header) *and*
check 9 (from the unpacked payload) — one reads rpm's claims, the other reads
the bytes, and a package whose header and payload disagree fails only one.

Delete `/tmp/selftest` afterwards, and never copy that package anywhere.

---

## One-time setup

### A. Create a build qube

```sh
# in dom0
qvm-create --class AppVM --label orange --template fedora-41-xfce vpn-rpm-build
qvm-prefs vpn-rpm-build netvm none
qvm-prefs vpn-rpm-build maxmem 4000
```

Two reasons it is its own qube rather than `salt-configs-vm`:

- **The signing key never needs a network.** With `netvm none` it cannot
  leave, whatever else goes wrong in there.
- **Parsers run somewhere disposable.** The audit unpacks an untrusted payload;
  do that in a qube whose loss costs nothing.

Be clear about what this does *not* buy: if `salt-configs-vm` is compromised,
the source it sends here is already poisoned, and an offline build VM will
sign that poison just as happily. This separation protects the key, not the
source.

Match the template to dom0's Fedora release where you can — a package built by
a much newer `rpm` may use a header format dom0's `rpm` will not read. If you
get that wrong you find out at `rpmkeys -Kv` time, loudly, not silently. Check
with `rpm --version` in dom0 and in the build qube.

Install the toolchain (temporarily give it a netvm, or install into the
template):

```sh
# in vpn-rpm-build
sudo dnf install -y rpm-build rpm-sign
```

### B. Generate a signing key

```sh
# in vpn-rpm-build, with netvm none
gpg --full-generate-key
```

Choose **RSA and RSA**, **4096** bits, and a real passphrase. RSA rather than
an elliptic curve simply because every `rpm` version understands it; ed25519
support depends on which crypto backend dom0's rpm was built against, and
this is not a place to discover an incompatibility.

Note the key ID and fingerprint:

```sh
gpg --list-keys --keyid-format LONG
gpg --fingerprint
```

Back the private key up somewhere offline. If you lose it you cannot issue
upgrades that dom0 will accept — you have to import a new public key, which
means redoing step C.

### C. Get the public key into dom0 — the trust anchor

```sh
# in vpn-rpm-build
gpg --armor --export <KEYID> > ~/RPM-GPG-KEY-vpn-dvm
```

```sh
# in dom0
qvm-run --pass-io --no-gui vpn-rpm-build 'cat ~/RPM-GPG-KEY-vpn-dvm' > ~/RPM-GPG-KEY-vpn-dvm
```

**Stop and read this before importing.** This one transfer is unverified, and
it cannot be otherwise. It is the chicken-and-egg at the bottom of every
signing scheme: the first key has nothing to check it against. Every signature
you verify afterwards is only as good as this moment.

So verify the fingerprint *by eye*, on both sides, and compare them yourself:

```sh
# in dom0
gpg --show-keys --fingerprint ~/RPM-GPG-KEY-vpn-dvm
```

```sh
# in vpn-rpm-build
gpg --fingerprint <KEYID>
```

Read all forty hex characters. Not the first four and the last four — the
whole thing. If they match, import:

```sh
# in dom0
sudo rpmkeys --import ~/RPM-GPG-KEY-vpn-dvm
rpm -qa 'gpg-pubkey*' --qf '%{VERSION}-%{RELEASE} %{SUMMARY}\n'
```

You do this once. Never again unless you change keys.

---

## Every build

### 1. Get the source into the build qube

The source lives in `salt-configs-vm`. Copy it across the normal VM-to-VM
way — this transfer does not involve dom0 at all, so it is an ordinary file
copy with ordinary risks:

```sh
# in salt-configs-vm
qvm-copy ~/vpn-build
```

Accept it into `vpn-rpm-build`, then:

```sh
# in vpn-rpm-build
rm -rf ~/vpn-build && mv ~/QubesIncoming/salt-configs-vm/vpn-build ~/
```

Both scripts below are invoked with `bash`, so a checkout that lost its
execute bits still works — and, more to the point, an unreadable audit script
fails the audit rather than skipping it.

### 2. Build, sign and audit

One command does all three, and refuses to leave a package behind if the
audit fails:

```sh
# in vpn-rpm-build
bash ~/vpn-build/tools/rpm/build-rpm.sh --version 1.0.0 --release 1 --sign <KEYID>
```

Expected ending:

```
RESULT: PASSED -- every check above.
Package ready:
  /home/user/rpmbuild-vpn/RPMS/noarch/qubes-vpn-dvm-dom0-1.0.0-1.noarch.rpm
```

**Any `FAIL` line means stop.** The script deletes the package for you so it
cannot be copied across by mistake, but understand what failed before you
rebuild — a failure here is either a mistake in `manifest.txt` or something
you did not put there.

To audit a package on its own, without rebuilding:

```sh
bash ~/vpn-build/tools/rpm/vpn-rpm-audit --key <KEYID> ~/rpmbuild-vpn/RPMS/noarch/*.rpm
```

The generated spec is at `~/rpmbuild-vpn/SPECS/qubes-vpn-dvm-dom0.spec`. Read
it if you want to see exactly what was built rather than what was intended.

### 3. Read the source — this is the real step

Nothing above tells you the code is safe. Check 8 proves the package contains
the bytes in `dom0/`; it says nothing about whether those bytes are good. A
`.sls` file in `/srv/user_salt` is **code salt runs as root in dom0**, and the
`vpn-*` commands are shell scripts you will run there yourself.

```sh
# in vpn-rpm-build
find ~/vpn-build/dom0 -type f -exec sh -c 'echo "=== $1"; cat -v "$1"' _ {} \; | less
```

`cat -v`, not `cat` or `less` alone: a file from another qube can contain
terminal escape sequences that make your screen *display* something different
from what the file says. `cat -v` prints the codes instead of obeying them.

Do this properly the first time and on every change you did not make
yourself. It is the only defence against a compromised source qube, and there
is no tool that can do it for you.

### 4. Pull it into dom0

```sh
# in dom0
V=1.0.0-1
qvm-run --pass-io --no-gui vpn-rpm-build \
  "cat ~/rpmbuild-vpn/RPMS/noarch/qubes-vpn-dvm-dom0-$V.noarch.rpm" \
  > ~/qubes-vpn-dvm-dom0-$V.noarch.rpm
```

### 5. Verify in dom0, then install

```sh
# in dom0
rpmkeys -Kv ~/qubes-vpn-dvm-dom0-$V.noarch.rpm
```

You are looking for a line containing **`Signature`** and **`OK`**, naming
your key ID. Two failure modes to know by sight:

- **`NOKEY`** — the signature is present but dom0 does not have the public
  key. Nothing has been verified. Go back to setup step C.
- **No `Signature` line at all, only digests** — the package is *unsigned*.
  The digest lines say `OK` regardless, because a digest only proves the file
  is internally consistent. Do not install it.

Then:

```sh
sudo rpm -Uvh ~/qubes-vpn-dvm-dom0-$V.noarch.rpm
rpm -ql qubes-vpn-dvm-dom0
```

`rpm -Uvh` handles both first install and upgrade. Use `rpm` rather than `dnf
install ./file.rpm`: dnf's signature enforcement for a local file depends on
repository configuration that does not apply here, and the explicit
`rpmkeys -Kv` above is the gate you actually want to read with your own eyes.

Confirm what landed:

```sh
rpm -V qubes-vpn-dvm-dom0     # silence means disk matches the package
```

### 6. Clean up

```sh
# in dom0
rm -f ~/qubes-vpn-dvm-dom0-*.rpm
```

---

## Upgrades

Bump the release (or version), rebuild, re-audit, pull, verify, `rpm -Uvh`.
Same steps, no special cases.

Two files are marked `%config(noreplace)`: `/srv/user_salt/top.sls` and
`/srv/user_pillar/top.sls`. If you have edited them — to run other salt states
alongside this project — an upgrade leaves your version in place and writes
the new one beside it as `.rpmnew`. Check for those after every upgrade:

```sh
find /srv/user_salt /srv/user_pillar -name '*.rpmnew' -o -name '*.rpmsave'
```

## Removing it

```sh
sudo rpm -e qubes-vpn-dvm-dom0
```

This is a real gain over the tar workflow, where "uninstall" meant remembering
nineteen paths. Anything the package did not create — the generated
`/srv/user_pillar/vpn.sls`, and the qubes themselves — survives, and should:
`rpm -e` removes the tooling, not your VPN qubes.

## Checking dom0 has not drifted

```sh
rpm -V qubes-vpn-dvm-dom0
```

Silence means every installed file still matches the signed package. Output
means something changed since install. Columns to recognise: `5` a changed
digest, `M` changed mode, `U`/`G` changed owner, `T` changed mtime, `missing`
gone entirely. For `%config` files a `c` marker means the change is expected
if it was you who made it.

This is a genuinely new capability. The tar workflow had no way to ask "is
what is in dom0 still what I put there?"

## How this interacts with `vpn-salt-sync`

`vpn-salt-sync` pulls an edited state tree straight into
`/srv/user_salt/vpn/`, which the package now owns. That is still the right
tool for the **authoring loop** — you are changing salt code and want it in
dom0 without a full build-sign-verify round trip — but be aware of two things:

- After running it, `rpm -V qubes-vpn-dvm-dom0` will report the changed files.
  That is correct and useful: it is telling you dom0 has drifted from the
  signed package.
- The next `rpm -Uvh` overwrites those files, because they are not `%config`.
  Nothing is lost — the edits live in `salt-configs-vm` — but do not treat
  dom0 as where your work is kept.

When the change is finished, roll it into a new package version. `vpn-salt-sync`
is for iterating, not for shipping. It must still never be automated, wired
into `vpn-build`, or run from a timer.

## What this protects you from, and what it does not

**Protected:**

- The other qube cannot initiate a transfer into dom0, or reach into it.
- Tampering between the build VM and dom0 — the signature catches it.
- Anything installing itself: no scriptlet runs, because the audit refuses a
  package that has one.
- Files landing outside the reviewed manifest, or with the wrong mode, owner,
  or type.
- Silent drift after install — `rpm -V` reports it.
- A decompression bomb: the payload is uncompressed, so installed size cannot
  exceed the file you pulled.
- Terminal spoofing while you read — `cat -v` neutralises escape sequences.
- Parser exposure in dom0: the payload is unpacked and inspected in the build
  VM. dom0's rpm parses a header whose signature it has already verified.

**Not protected:**

- **A compromised source qube.** If `salt-configs-vm` sends a plausible-looking
  `vpn-build` that quietly does something else, every check above passes: the
  manifest matches, the digests match the source tree, the signature is valid.
  You will have signed it yourself. **Reading the source is the only defence,
  and it is on you.**
- **The first public-key transfer.** Setup step C is unverified by
  construction; comparing the fingerprint by eye is the whole of it.
- **The signing key.** Anyone who gets it can produce packages dom0 accepts.
  That is why the build qube has `netvm none`.
- **dom0's rpm parsing a signed header.** Small, unavoidable, and much smaller
  than the tar workflow's exposure — signature verification comes before the
  payload is touched, and the payload has already been unpacked and compared
  in the build VM.

## Why the state tree is in the package at all

A `.sls` file in `/srv/user_salt` is code that runs as root in dom0, so it is
the most consequential thing this project moves across the boundary. Putting
it in a signed package means it moves under a signature, appears in `rpm -ql`,
and gets checked by `rpm -V` — rather than being nineteen `install` commands
you hope you got right.

It also does not need to move often. Every value that varies between builds —
protocol, transport, MTU, country, server, and the derived qube names —
reaches those files as a `{{ }}` pillar reference, never as a literal. The
pillar is written by dom0 itself, by `vpn-params-fetch`, from values it
validated. So the state tree is identical whether you are building a WireGuard
UK tunnel or an OpenVPN-over-TCP German one.

Changing a setting means editing `vpn-selection.conf` in `salt-configs-vm` and
running `vpn-build`. Nothing in the package is touched, and nothing crosses
into dom0 except about a dozen `key=value` lines, parsed by `vpn-params-fetch`
against a fixed whitelist.
