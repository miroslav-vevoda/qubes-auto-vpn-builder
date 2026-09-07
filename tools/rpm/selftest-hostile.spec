# tools/rpm/selftest-hostile.spec
#
# A DELIBERATELY BAD PACKAGE, for checking that vpn-rpm-audit actually works.
#
# An audit script that passes everything looks exactly like an audit script
# that works. This spec builds a package carrying one instance of each thing
# vpn-rpm-audit is supposed to refuse, so you can watch it refuse them.
#
# BUILD AND AUDIT IT IN THE BUILD VM. Never copy the result to dom0. It is
# not subtle -- it is a package that writes a root cron job and runs a
# scriptlet -- and it exists only to be rejected.
#
#     cd ~/vpn-build/tools/rpm
#     mkdir -p /tmp/selftest
#     rpmbuild --define "_topdir /tmp/selftest" -bb selftest-hostile.spec
#     bash vpn-rpm-audit /tmp/selftest/RPMS/noarch/vpn-audit-selftest-*.rpm
#
# EXPECTED RESULT: "RESULT: FAILED" and exit status 1, with 14 FAIL lines.
#
# Verified 2026-09-07 against rpm 6.0.2 / rpmbuild on Fedora 43: all 14 fire.
#
#     [2] signature            -- unsigned
#     [3] no scriptlets        -- the %post below
#     [4] no OBSOLETE entries  -- Obsoletes: qubes-core-dom0
#     [4] no CONFLICT entries  -- Conflicts: qubes-mgmt-salt-dom0
#     [4] Requires limited to rpmlib()   -- see the note on /bin/sh below
#     [5] payload uncompressed -- no w.ufdio here, so rpm compresses it
#     [6] paths inside allowed prefixes  -- /etc/cron.d/evil
#     [6] only regular files and directories -- the symlink to /etc/shadow
#     [6] no setuid/... /world-writable  -- suidthing, worldwritable.sls
#     [6] everything owned root:root     -- worldwritable.sls is user:user
#     [6] no %ghost or %missingok        -- phantom.sls
#     [7] no manifest entry missing      -- nothing here is in manifest.txt
#     [7] no path beyond the manifest    -- the five bad paths
#     [8] digests match the source tree  -- vpn-build differs from dom0/
#     [8] every file has a source counterpart -- no counterparts
#     [9] payload holds only regular files and directories -- the symlink
#
# Two of those are worth understanding, because they were not predicted when
# this fixture was written and they are the more interesting half of the
# result:
#
#   [4] /bin/sh -- rpm injects a /bin/sh dependency because a scriptlet
#       exists, EVEN THOUGH this spec sets AutoReqProv: no. Install-time code
#       leaks into dependency metadata, so check [4] catches scriptlets
#       independently of check [3]. Two unrelated checks, one cause.
#
#   [9] the symlink -- already caught by [6] from header metadata. [9] finds
#       it again in the UNPACKED payload. That is the point of having both:
#       [6] believes the header, [9] believes the bytes. A package whose
#       header and payload disagree fails one but not the other.
#
# If any of those PASSES, the corresponding check is broken and you should not
# rely on it. If the audit reports FAILED for all of them, the tool works.
#
# Note what rpmbuild does NOT do. It builds this package and exits 0. Its only
# objection is one warning:
#
#     warning: absolute symlink: /srv/user_salt/vpn/peek -> /etc/shadow
#
# Nothing at the packaging layer stops you shipping a setuid binary, a root
# cron job, an Obsoletes: on qubes-core-dom0, or a scriptlet that runs as root
# in dom0 -- and the one warning it does emit is easily lost in build output.
# That is the entire reason vpn-rpm-audit exists.

Name:           vpn-audit-selftest
Version:        0
Release:        0
Summary:        Deliberately bad package -- for testing vpn-rpm-audit only
License:        GPL-2.0-only
BuildArch:      noarch
AutoReqProv:    no

# Metadata that would disturb dom0. Obsoletes on qubes-core-dom0 is the
# nastiest line here: it asks the package manager to remove the thing that
# makes the machine a Qubes host.
Obsoletes:      qubes-core-dom0 < 99
Conflicts:      qubes-mgmt-salt-dom0

%description
Not a real package. Builds one instance of everything vpn-rpm-audit refuses,
so the refusals can be observed rather than assumed. Do not install this
anywhere, and above all not in dom0.

%install
mkdir -p %{buildroot}/usr/local/bin \
         %{buildroot}/etc/cron.d \
         %{buildroot}/srv/user_salt/vpn

# a path outside every allowed prefix, and a nasty one
echo '* * * * * root id > /tmp/selftest-marker' > %{buildroot}/etc/cron.d/evil

# a plausible-looking file, so the audit has something legitimate to compare
echo '#!/bin/bash' > %{buildroot}/usr/local/bin/vpn-build

# setuid
echo 'x' > %{buildroot}/usr/local/bin/suidthing

# world-writable and not owned by root
echo 'y' > %{buildroot}/srv/user_salt/vpn/worldwritable.sls

# a symlink pointing at something in dom0 worth reading
ln -s /etc/shadow %{buildroot}/srv/user_salt/vpn/peek

# code that runs as root at install time, before you have read anything
%post
echo "a scriptlet ran as root at $(date)" > /tmp/selftest-scriptlet-ran

%files
%attr(0755,root,root) /usr/local/bin/vpn-build
%attr(0644,root,root) /etc/cron.d/evil
%attr(4755,root,root) /usr/local/bin/suidthing
%attr(0666,user,user) /srv/user_salt/vpn/worldwritable.sls
/srv/user_salt/vpn/peek
# %ghost: a path rpm will create and delete without it ever being in the
# payload, so nothing you inspected covers it
%ghost /srv/user_salt/vpn/phantom.sls

%changelog
* Thu Jan 01 1970 nobody <nobody@localhost> - 0-0
- Test fixture. Not a release.
