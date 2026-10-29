#!/bin/bash
# Installs the Discord-only bypass. Safe to run again, for example after
# editing domains.txt or re-running test.sh on a new network.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$KIT_DIR/lib/admin.sh"
source "$KIT_DIR/lib/render.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "This only runs on macOS."
[[ $EUID -ne 0 ]] || die "Run it without sudo. It asks for your password when it needs it."

[[ -x "$BIN" ]] || "$KIT_DIR/build.sh"
[[ -s "$METHOD_FILE" ]] || "$KIT_DIR/test.sh"

main="$(sed -n 1p "$METHOD_FILE")"
fallback="$(sed -n 2p "$METHOD_FILE")"
[[ -n "$main" ]] || die "method.conf is empty. Run ./test.sh"

# ciadpi listens on localhost only, so nothing else on the network can use it.
# If the main method gets reset, it retries with the fallback. (No -T timeout:
# byedpi only compiles that option on Linux and Windows.)
proxy_args=("$INSTALL_DIR/ciadpi" -i 127.0.0.1 -p "$SOCKS_PORT")
# shellcheck disable=SC2206
proxy_args+=($main)
# shellcheck disable=SC2206
[[ -n "$fallback" ]] && proxy_args+=(-A torst,ssl_err $fallback)

load_agent() {
    local label="$1" plist="$HOME/Library/LaunchAgents/$1.plist" i
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    # bootout returns before the old job is fully gone, so retry for a moment.
    for i in {1..40}; do
        launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null && return 0
        sleep 0.25
    done
    die "launchd refused to load $plist"
}

log "Method: '$main'${fallback:+ (fallback: '$fallback')}"

mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$(dirname "$LOG_FILE")"
rm -f "$INSTALL_DIR/ciadpi"
cp "$BIN" "$INSTALL_DIR/ciadpi"
cp "$KIT_DIR/lib/pac-server.sh" "$KIT_DIR/lib/relay.sh" "$INSTALL_DIR/"
write_pac > "$INSTALL_DIR/proxy.pac"

write_proxy_plist "${proxy_args[@]}" > "$HOME/Library/LaunchAgents/$LABEL_PROXY.plist"
write_pac_plist > "$HOME/Library/LaunchAgents/$LABEL_PAC.plist"
# lib/system.sh copies this one into /Library/LaunchDaemons.
write_relay_plist "$USER" > "$INSTALL_DIR/$LABEL_RELAY.plist"
plutil -lint -s "$HOME/Library/LaunchAgents/$LABEL_PROXY.plist" "$HOME/Library/LaunchAgents/$LABEL_PAC.plist" \
    "$INSTALL_DIR/$LABEL_RELAY.plist"

log "Starting background services"
load_agent "$LABEL_PROXY"
load_agent "$LABEL_PAC"
wait_for_port "$SOCKS_PORT" || die "ciadpi did not start. See $LOG_FILE"
curl -sf --max-time 3 --noproxy '*' "$PAC_URL" | grep -q FindProxyForURL \
    || die "The proxy config server on port $PAC_PORT is not answering."

for host in discord.com $RELAY_HOSTS; do
    ip="$(real_ip "$host")"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 --socks5 "127.0.0.1:$SOCKS_PORT" \
        --resolve "$host:443:$ip" "https://$host/" || true)"
    [[ "$code" != "000" ]] || die "Bypass check failed for $host. Run ./test.sh to pick a new method."
done

log "Setting DNS, proxy config and the updater relay (needs your password)"
run_as_admin install "$INSTALL_DIR/$LABEL_RELAY.plist"

echo
"$KIT_DIR/status.sh" || true
echo
log "Done. Quit Discord completely (Cmd+Q) and open it again."
