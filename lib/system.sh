#!/bin/bash
# The part that needs admin rights. install.sh and uninstall.sh call this
# through sudo or the macOS password dialog.
#   system.sh install <relay plist>  per-domain DNS for Discord, PAC URL on every
#                                    network service, /etc/hosts entries and relay daemon
#   system.sh uninstall              undo all of it
set -euo pipefail
source "$(dirname "$0")/../config.sh"

[[ $EUID -eq 0 ]] || die "lib/system.sh must run as root."

flush_dns() {
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null || true
}

ours() { [[ -f "$1" ]] && grep -qF "$RESOLVER_MARKER" "$1"; }

install_dns() {
    mkdir -p /etc/resolver
    local d f s list
    list="$(domains)"
    for d in $list; do
        f="/etc/resolver/$d"
        if [[ -e "$f" ]] && ! ours "$f"; then
            warn "Leaving $f alone: it was not created by discord-dpi."
            continue
        fi
        {
            echo "$RESOLVER_MARKER"
            for s in $DNS_SERVERS; do echo "nameserver $s"; done
            echo "port $DNS_PORT"
        } > "$f"
        chmod 644 "$f"
    done
    # Drop files for domains that were removed from domains.txt since the last install.
    for f in /etc/resolver/*; do
        ours "$f" || continue
        grep -qxF "$(basename "$f")" <<< "$list" || rm -f "$f"
    done
}

uninstall_dns() {
    local f
    for f in /etc/resolver/*; do
        ours "$f" && rm -f "$f"
    done
    rmdir /etc/resolver 2>/dev/null || true
}

# networksetup prints "URL: ..." and "Enabled: Yes|No".
pac_field() { networksetup -getautoproxyurl "$1" | awk -F': ' -v k="$2" '$1 == k { print $2; exit }'; }

install_pac() {
    local svc
    while IFS= read -r svc; do
        if [[ "$(pac_field "$svc" Enabled)" == "Yes" && "$(pac_field "$svc" URL)" != "$PAC_URL" ]]; then
            warn "Skipping '$svc': it already uses another proxy config ($(pac_field "$svc" URL))."
            continue
        fi
        networksetup -setautoproxyurl "$svc" "$PAC_URL"
        networksetup -setautoproxystate "$svc" on
    done < <(network_services)
}

uninstall_pac() {
    local svc
    while IFS= read -r svc; do
        [[ "$(pac_field "$svc" URL)" == "$PAC_URL" ]] || continue
        networksetup -setautoproxystate "$svc" off
    done < <(network_services)
}

# Rewrite /etc/hosts without our lines, keeping the file itself (and its
# permissions) in place.
strip_hosts() {
    local kept
    kept="$(grep -vF "$RESOLVER_MARKER" /etc/hosts || true)"
    printf '%s\n' "$kept" > /etc/hosts
}

install_hosts() {
    local h
    strip_hosts
    for h in $RELAY_HOSTS; do
        printf '127.0.0.1\t%s %s\n::1\t\t%s %s\n' "$h" "$RESOLVER_MARKER" "$h" "$RESOLVER_MARKER" >> /etc/hosts
    done
}

install_relay() {
    local src="$1"
    [[ -f "$src" ]] || die "Relay plist not found: $src"
    launchctl bootout "system/$LABEL_RELAY" 2>/dev/null || true
    cp "$src" "$RELAY_PLIST"
    chown root:wheel "$RELAY_PLIST"
    chmod 644 "$RELAY_PLIST"
    local i
    for i in {1..40}; do
        launchctl bootstrap system "$RELAY_PLIST" 2>/dev/null && return 0
        sleep 0.25
    done
    die "launchd refused to load $RELAY_PLIST"
}

uninstall_relay() {
    launchctl bootout "system/$LABEL_RELAY" 2>/dev/null || true
    rm -f "$RELAY_PLIST"
}

case "${1:-}" in
    install)   install_dns; install_pac; install_relay "${2:-}"; install_hosts; flush_dns ;;
    uninstall) uninstall_pac; strip_hosts; uninstall_relay; uninstall_dns; flush_dns ;;
    *)         die "usage: lib/system.sh install <relay plist> | uninstall" ;;
esac
