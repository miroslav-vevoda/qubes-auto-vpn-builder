# /etc/profile.d/vpn-status.sh
#
# Master copy lives at /rw/config/vpn-status.sh. It is INSTALLED into
# /etc/profile.d/ by /rw/config/rc.local at every boot, and is deliberately
# not deployed to /etc directly, because /etc is on the root volume -- a
# copy-on-write snapshot of the base template that is discarded at shutdown
# and re-copied at every start. Only the private volume (/rw and /home)
# reaches a disposable, so the master has to live there and be copied into
# place each boot.
#
# Prints tunnel status when you open a terminal, and keeps a short marker in
# the prompt so it cannot go stale while the terminal is open.
#
# Sourced by every interactive shell: /etc/bashrc loops over
# /etc/profile.d/*.sh for non-login interactive shells too, not just login
# ones, and only lets them print when a prompt exists. So this file must:
#
#   * print nothing when the shell is not interactive
#   * never call "exit" -- that would close the caller's shell
#   * leave behind only what the prompt marker needs
#
# All state comes from /run/vpn-status, written by /rw/config/vpn-statusd.
# Nothing here needs root, and nothing here inspects the network.

# Line 1 of the status file is fixed vocabulary chosen by vpn-statusd -- never
# anything derived from a config file, a filename or the network. It is safe
# to parse with a bare read.
#
# Returns 0 fresh, 1 unreadable or malformed, 2 stale.
#
# The staleness test lives HERE rather than in the banner so that every
# consumer inherits it. Without it the prompt marker happily reports "VPN up"
# forever after vpn-statusd dies -- reading a state word nobody has refreshed
# in fifteen minutes -- which is the exact failure the marker exists to catch.
__vpn_status_read() {
    __vpn_state=unknown
    __vpn_armed=unknown
    __vpn_ts=0
    __vpn_age=0

    [ -r /run/vpn-status ] || return 1
    read -r __vpn_state __vpn_armed __vpn_ts < /run/vpn-status || return 1

    # A corrupt or truncated file must not reach the arithmetic below.
    case "${__vpn_ts:-}" in
        ''|*[!0-9]*) __vpn_state=unknown; __vpn_armed=unknown; return 1 ;;
    esac

    # vpn-statusd rewrites every 30s; 150s is five missed cycles.
    __vpn_age=$(( $(date +%s) - __vpn_ts ))
    # A timestamp in the future gives a negative age, which is never "> 150",
    # so without this a stale file would read as fresh indefinitely. Reachable
    # with no attacker at all: a disposable that writes a status before the
    # clock settles, then time steps backwards.
    if [ "$__vpn_age" -lt 0 ]; then
        __vpn_state=stale
        __vpn_armed=stale
        return 2
    fi
    if [ "$__vpn_age" -gt 150 ]; then
        __vpn_state=stale
        __vpn_armed=stale
        return 2
    fi
    return 0
}

# Deliberately no colour here. Bash counts prompt width using \[ \] markers,
# and those are NOT reprocessed when they arrive via command substitution, so
# a coloured marker would corrupt line editing on long command lines. Plain
# text is always correct. Colour lives in the banner, which is ordinary output.
__vpn_mark() {
    if ! __vpn_status_read; then printf '[VPN?]'; return; fi
    case "$__vpn_state" in
        up)   printf '[VPN up]' ;;
        down) printf '[VPN DOWN]' ;;
        *)    printf '[VPN?]' ;;
    esac
}

__vpn_status_banner() {
    __v_r=''; __v_ok=''; __v_warn=''; __v_bad=''; __v_dim=''
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != dumb ]; then
        __v_r=$(printf '\033[0m')
        __v_ok=$(printf '\033[1;32m')
        __v_warn=$(printf '\033[1;33m')
        __v_bad=$(printf '\033[1;31m')
        __v_dim=$(printf '\033[2m')
    fi

    __vpn_status_read
    case $? in
      1)
        printf '%s  VPN    NO STATUS%s  vpn-statusd is not running\n' "$__v_warn" "$__v_r"
        printf '%s                    check: systemctl status vpn-statusd%s\n' "$__v_dim" "$__v_r"
        unset __v_r __v_ok __v_warn __v_bad __v_dim
        return ;;
      2)
        printf '%s  VPN    STALE%s      status is %ss old - vpn-statusd may have died\n' \
            "$__v_warn" "$__v_r" "$__vpn_age"
        printf '%s                    check: systemctl status vpn-statusd%s\n' "$__v_dim" "$__v_r"
        unset __v_r __v_ok __v_warn __v_bad __v_dim
        return ;;
    esac

    case "$__vpn_state" in
        up)   __v_c="$__v_ok";   __v_l='UP     ' ;;
        down) __v_c="$__v_bad";  __v_l='DOWN   ' ;;
        *)    __v_c="$__v_warn"; __v_l='UNKNOWN' ;;
    esac
    printf '%s  VPN    %s%s  %s\n' "$__v_c" "$__v_l" "$__v_r" "$(sed -n 2p /run/vpn-status)"

    # "open" is the one that should be impossible: qubes-firewall-user-script
    # forces a bare kill switch on every failure path, so an unarmed chain
    # means something went wrong that the script itself could not recover from.
    case "$__vpn_armed" in
        armed) __v_c="$__v_ok";   __v_l='ARMED  ' ;;
        open)  __v_c="$__v_bad";  __v_l='OPEN   ' ;;
        *)     __v_c="$__v_warn"; __v_l='UNKNOWN' ;;
    esac
    printf '%s         %s%s  %s\n' "$__v_c" "$__v_l" "$__v_r" "$(sed -n 3p /run/vpn-status)"

    unset __v_r __v_ok __v_warn __v_bad __v_dim __v_c __v_l
}

case $- in
  *i*)
    __vpn_status_banner

    # Prompt marker, so the banner cannot go stale while the terminal is open.
    # Bash only -- \[ \] width accounting and PROMPT_COMMAND are bash features.
    # Opt out with:  export VPN_STATUS_NO_PS1=1
    if [ -n "${BASH_VERSION:-}" ] && [ -z "${VPN_STATUS_NO_PS1:-}" ]; then
        case "${PS1:-}" in
            *__vpn_mark*) ;;
            *) PS1='$(__vpn_mark) '"${PS1:-}" ;;
        esac
    fi
    ;;
esac

# The banner runs once; only the marker needs to survive into the session.
unset -f __vpn_status_banner 2>/dev/null
