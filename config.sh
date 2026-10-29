# Settings shared by every discord-dpi script. Sourced, not executed.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="$KIT_DIR/domains.txt"
METHOD_FILE="$KIT_DIR/method.conf"
BIN="$KIT_DIR/bin/ciadpi"

# byedpi is pinned to a release and verified by commit hash at build time.
BYEDPI_REPO="https://github.com/hufrea/byedpi.git"
BYEDPI_TAG="v0.17.3"
BYEDPI_COMMIT="7efde1b1296eaaa187b70e951894dde17527489c"

SOCKS_PORT=10800
PAC_PORT=10801
PAC_URL="http://127.0.0.1:$PAC_PORT/proxy.pac"

# DNS used for Discord domains only. Plain DNS on port 443 gets past ISPs that
# hijack normal DNS traffic on port 53. If OpenDNS ever stops answering, Yandex
# works as a fallback: DNS_SERVERS="77.88.8.8 77.88.8.1" and DNS_PORT=1253.
DNS_SERVERS="208.67.222.222 208.67.220.220"
DNS_PORT=443

# Discord's built-in updater ignores proxy settings. /etc/hosts points these
# names at this Mac, where a relay on port 443 passes them through ciadpi.
RELAY_HOSTS="updates.discord.com"

LABEL_PROXY="local.discord-dpi.proxy"
LABEL_PAC="local.discord-dpi.pac"
LABEL_RELAY="local.discord-dpi.relay"
RELAY_PLIST="/Library/LaunchDaemons/$LABEL_RELAY.plist"
# HOME can be unset when lib/system.sh runs as root, and it doesn't need these.
INSTALL_DIR="${HOME:-}/Library/Application Support/discord-dpi"
LOG_FILE="${HOME:-}/Library/Logs/discord-dpi.log"

# Marker written into every file we put in /etc/resolver and every line we add
# to /etc/hosts, so uninstall only removes our own.
RESOLVER_MARKER="# managed by discord-dpi"

log()  { printf '\033[1;34m[discord-dpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[discord-dpi]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[discord-dpi]\033[0m %s\n' "$*" >&2; exit 1; }

# Domains from domains.txt, one per line, comments and blanks dropped.
domains() { grep -vE '^[[:space:]]*(#|$)' "$DOMAINS_FILE" | tr -d '[:blank:]'; }

# Network services that are not disabled (the first line of the listing is a header).
network_services() { networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' || true; }

# Real IP for a Discord host, asked from the unfiltered DNS servers directly.
real_ip() {
    local s ip
    for s in $DNS_SERVERS; do
        ip="$(dig +short +time=2 +tries=1 @"$s" -p "$DNS_PORT" "$1" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    done
    dig +short +time=2 +tries=1 @8.8.8.8 "$1" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1
}

wait_for_port() {
    local i
    for i in {1..40}; do
        nc -z 127.0.0.1 "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
