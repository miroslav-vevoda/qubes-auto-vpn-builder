#!/usr/bin/env bash
#
# build-endpoint-map.sh
#
# Builds endpoint-map.txt for each country folder, from the VPN provider's
# config files.
#
# WHERE TO RUN THIS
#
#   In the NETWORKED qube where you download the configs, BEFORE copying them
#   into vpn-config-files-vm. It needs DNS, and this is the only point in the
#   whole workflow where DNS is available:
#
#     - vpn-config-files-vm has netvm = none
#     - dom0 has no network at all
#     - the VPN qube has DNS dropped by the dom0 firewall
#
#   So any hostname in a config has to be resolved here, once, at gathering
#   time. That is the entire reason this script exists as a separate step.
#
# WHAT IT DOES
#
#   For every <base>/<iso>/ directory, reads each *.conf and extracts the
#   server address:
#
#     WireGuard   Endpoint = <host>:<port>
#     OpenVPN     remote <host> [port] [proto]   (first remote line only)
#
#   Hostnames are resolved to IPv4. Every address is range-checked and
#   rejected if an octet has a leading zero. The result is written to
#   <base>/<iso>/endpoint-map.txt as:
#
#     <config-filename> <ip>:<port>
#
# USAGE
#
#   ./build-endpoint-map.sh [BASE_CONFIG_DIR]
#
#   Default BASE_CONFIG_DIR is ./configs, then ~/configs.

set -euo pipefail

#############################################
# Dependencies
#############################################

missing=()
for cmd in awk grep sort mktemp basename; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

# At least one resolver must exist. getent is in glibc and needs no extra
# package; dig and host come from bind-utils.
resolver=""
for cmd in getent dig host; do
    if command -v "$cmd" >/dev/null 2>&1; then resolver="$cmd"; break; fi
done
[ -n "$resolver" ] || missing+=("getent or dig or host")

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing dependencies:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo >&2
    echo "On Fedora:  sudo dnf install -y gawk grep coreutils bind-utils" >&2
    echo "On Debian:  sudo apt install -y gawk grep coreutils dnsutils" >&2
    exit 1
fi

#############################################
# Input
#############################################

if [ $# -ge 1 ]; then
    BASE_CONFIG_DIR="$1"
elif [ -d "./configs" ]; then
    BASE_CONFIG_DIR="./configs"
else
    BASE_CONFIG_DIR="$HOME/configs"
fi

if [ ! -d "$BASE_CONFIG_DIR" ]; then
    echo "Directory not found: $BASE_CONFIG_DIR" >&2
    echo "usage: $0 [BASE_CONFIG_DIR]" >&2
    exit 1
fi

#############################################
# Validation helpers
#############################################

# Reject anything that is not an unambiguous dotted quad. Leading zeros are
# refused because "010.0.0.1" is read as octal by some parsers and decimal by
# others -- dom0 applies the same rule, this just fails earlier and louder.
valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1:4}"; do
        [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( o <= 255 )) || return 1
    done
    return 0
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    (( $1 <= 65535 ))
}

# True for anything made only of digits and dots, i.e. something the author
# clearly meant as a literal address rather than a name.
#
# This must be checked before falling through to the resolver. getent happily
# accepts "010.0.0.1" and returns 8.0.0.1, because glibc reads a leading zero
# as octal -- so an address rejected by valid_ipv4 for being ambiguous would
# come back out of the resolver as a different, confidently wrong address, and
# get whitelisted. Anything numeric that valid_ipv4 refuses must be refused
# outright, never resolved.
looks_numeric() {
    [[ "$1" =~ ^[0-9.]+$ ]]
}

# dom0 expects <stem>.<provider>.<tld>.conf where <stem> is two letters plus
# 1-4 digits, and skips anything else. Warn here so it can be fixed by
# renaming, rather than showing up later as an unexplained missing server.
# This only warns -- dom0 remains the authority on what it accepts.
warn_if_bad_name() {
    [[ "$1" =~ ^[a-z]{2}[0-9]{1,4}\.[a-z0-9-]+\.[a-z]{2,6}\.conf$ ]] && return 0
    echo "  ! $1 - dom0 will skip this: name must look like uk123.provider.com.conf" >&2
    return 0
}

#############################################
# Resolver
#############################################

# Prints one IPv4 address per line, deduplicated. Empty output means the name
# did not resolve.
resolve_ipv4() {
    local host="$1" out=""

    if command -v getent >/dev/null 2>&1; then
        out=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u) || true
    fi
    if [ -z "$out" ] && command -v dig >/dev/null 2>&1; then
        out=$(dig +short A "$host" 2>/dev/null \
              | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u) || true
    fi
    if [ -z "$out" ] && command -v host >/dev/null 2>&1; then
        out=$(host -t A "$host" 2>/dev/null \
              | awk '/has address/{print $NF}' | sort -u) || true
    fi

    [ -z "$out" ] || printf '%s\n' "$out"
}

# Cache lookups: providers often point many configs at the same hostname, and
# a cold DNS miss is the slowest thing this script does.
declare -A RESOLVED=()

resolve_cached() {
    local host="$1"
    if [ -n "${RESOLVED[$host]+set}" ]; then
        printf '%s' "${RESOLVED[$host]}"
        return 0
    fi
    local ips
    ips=$(resolve_ipv4 "$host")
    RESOLVED[$host]="$ips"
    printf '%s' "$ips"
}

#############################################
# Extraction
#############################################

# WireGuard: "Endpoint = host:port", any spacing, either case.
wg_endpoint() {
    awk '
        /^[[:space:]]*[Ee]ndpoint[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0)
            gsub(/[[:space:]]/, "", $0)
            print; exit
        }' "$1" 2>/dev/null || true
}

# OpenVPN: first "remote <host> [port] [proto]". Requires whitespace after the
# keyword, so "remote-cert-tls" and "remote-random" do not match. Falls back to
# a standalone "port <n>" directive, then to 1194.
ovpn_remote() {
    awk '
        /^[[:space:]]*port[[:space:]]+[0-9]+[[:space:]]*$/ && !defport { defport = $2 }
        /^[[:space:]]*remote[[:space:]]+/ && !done {
            host = $2
            port = (NF >= 3 && $3 ~ /^[0-9]+$/) ? $3 : ""
            done = 1
        }
        END {
            if (!done) exit
            if (port == "") port = (defport != "") ? defport : "1194"
            print host, port
        }' "$1" 2>/dev/null || true
}

#############################################
# Main
#############################################

shopt -s nullglob

total_written=0
total_skipped=0
countries=0

for iso_dir in "$BASE_CONFIG_DIR"/*/; do
    iso=$(basename "$iso_dir")

    if [[ ! "$iso" =~ ^[a-z]{2}$ ]]; then
        echo "Skipping '$iso' - not a two-letter lowercase country code" >&2
        continue
    fi

    configs=("$iso_dir"*.conf)
    if [ ${#configs[@]} -eq 0 ]; then
        echo "Skipping '$iso' - no .conf files" >&2
        continue
    fi

    echo "Processing $iso (${#configs[@]} configs)"
    countries=$((countries + 1))

    tmp=$(mktemp "$iso_dir/.endpoint-map.XXXXXX")
    # Single quotes: the trap body must be expanded when it FIRES, not when it
    # is set. Expanding now would embed the path literally, and a quote
    # anywhere in it would make the trap body a syntax error -- which only
    # shows up on the error path, exactly when the cleanup is needed.
    trap 'rm -f "$tmp"' EXIT

    {
        echo "# Generated by build-endpoint-map.sh on $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "# <config-filename> <ip>:<port>   -- hostnames already resolved"
    } > "$tmp"

    written=0
    skipped=0

    for conf in "${configs[@]}"; do
        base=$(basename "$conf")

        # Whichever the file has. A config is one or the other, never both.
        endpoint=$(wg_endpoint "$conf")
        proto_kind="wireguard"
        if [ -z "$endpoint" ]; then
            remote=$(ovpn_remote "$conf")
            proto_kind="openvpn"
            if [ -n "$remote" ]; then
                endpoint="${remote% *}:${remote#* }"
            fi
        fi

        if [ -z "$endpoint" ]; then
            echo "  ! $base - no Endpoint or remote line" >&2
            skipped=$((skipped + 1))
            continue
        fi

        host="${endpoint%:*}"
        port="${endpoint##*:}"

        # An IPv6 literal survives the split above as "[2001:db8::1" and would
        # otherwise be handed to the resolver and reported as an unresolvable
        # hostname, which is not the real reason it failed.
        case "$host" in
            *:*|\[*)
                echo "  ! $base - '$host' looks like IPv6. This design is IPv4" >&2
                echo "      only: qvm-firewall is given dst4 rules and the VPN" >&2
                echo "      qube has IPv6 disabled." >&2
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        if ! valid_port "$port"; then
            echo "  ! $base - invalid port '$port'" >&2
            skipped=$((skipped + 1))
            continue
        fi

        if valid_ipv4 "$host"; then
            ip="$host"
        elif looks_numeric "$host"; then
            echo "  ! $base - '$host' is a malformed address (leading zero, or" >&2
            echo "      out of range). Not resolving it: the resolver would read" >&2
            echo "      it as octal and return a different address." >&2
            skipped=$((skipped + 1))
            continue
        else
            # A hostname. This is the step that needs network.
            ips=$(resolve_cached "$host")
            if [ -z "$ips" ]; then
                echo "  ! $base - could not resolve '$host'" >&2
                skipped=$((skipped + 1))
                continue
            fi

            n=$(printf '%s\n' "$ips" | grep -c .)
            ip=$(printf '%s\n' "$ips" | head -n1)

            if ! valid_ipv4 "$ip"; then
                echo "  ! $base - '$host' resolved to unusable address '$ip'" >&2
                skipped=$((skipped + 1))
                continue
            fi

            if [ "$n" -gt 1 ]; then
                echo "  · $base - '$host' has $n addresses, pinning $ip" >&2
            fi

            # wg-quick resolves Endpoint itself, inside the VPN qube, where
            # there is no DNS. The map fixes the firewall but not the config,
            # so this one needs the address written into the .conf as well.
            if [ "$proto_kind" = "wireguard" ]; then
                echo "  ! $base - WireGuard Endpoint is a hostname." >&2
                echo "      The map will whitelist $ip, but wg-quick cannot resolve" >&2
                echo "      '$host' inside the VPN qube. Edit the config to read:" >&2
                echo "          Endpoint = $ip:$port" >&2
            fi
        fi

        warn_if_bad_name "$base"

        printf '%s %s:%s\n' "$base" "$ip" "$port" >> "$tmp"
        written=$((written + 1))
    done

    if [ "$written" -eq 0 ]; then
        echo "  no usable endpoints for $iso - leaving any existing map alone" >&2
        rm -f "$tmp"
        trap - EXIT
        total_skipped=$((total_skipped + skipped))
        continue
    fi

    # Written to a temp file and moved into place, so an interrupted run never
    # leaves a half-built map that a build would then read as authoritative.
    chmod 644 "$tmp"
    mv "$tmp" "$iso_dir/endpoint-map.txt"
    trap - EXIT

    echo "  wrote $written, skipped $skipped -> ${iso_dir}endpoint-map.txt"
    total_written=$((total_written + written))
    total_skipped=$((total_skipped + skipped))
done

echo
if [ "$countries" -eq 0 ]; then
    echo "No country directories found under $BASE_CONFIG_DIR" >&2
    echo "Expected e.g. $BASE_CONFIG_DIR/uk/uk123.provider.com.conf" >&2
    exit 1
fi

echo "Done: $total_written endpoints across $countries countries, $total_skipped skipped."
[ "$total_skipped" -eq 0 ] || echo "Re-run after fixing the items marked ! above."
