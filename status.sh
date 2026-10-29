#!/bin/bash
# Shows whether each piece of the bypass is in place and working.
set -uo pipefail
source "$(dirname "$0")/config.sh"

ok()  { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; failed=1; }
failed=0

if launchctl print "gui/$UID/$LABEL_PROXY" 2>/dev/null | grep -q 'state = running'; then
    ok "ciadpi is running on 127.0.0.1:$SOCKS_PORT"
else
    bad "ciadpi is not running (log: $LOG_FILE)"
fi

if curl -sf --max-time 3 --noproxy '*' "$PAC_URL" | grep -q FindProxyForURL; then
    ok "proxy config is served at $PAC_URL"
else
    bad "proxy config server is not answering"
fi

while IFS= read -r svc; do
    url="$(networksetup -getautoproxyurl "$svc" | awk -F': ' '$1 == "URL" { print $2 }')"
    on="$(networksetup -getautoproxyurl "$svc" | awk -F': ' '$1 == "Enabled" { print $2 }')"
    if [[ "$url" == "$PAC_URL" && "$on" == "Yes" ]]; then
        ok "'$svc' uses the proxy config"
    else
        bad "'$svc' does not use the proxy config"
    fi
done < <(network_services)

# What macOS itself resolves discord.com to, compared with the unfiltered answer.
sys_ip="$(dscacheutil -q host -a name discord.com | awk '/^ip_address:/ { print $2; exit }')"
good_ips="$(for s in $DNS_SERVERS; do dig +short +time=2 +tries=1 @"$s" -p "$DNS_PORT" discord.com A; done)"
if [[ -n "$sys_ip" ]] && grep -qxF "$sys_ip" <<< "$good_ips"; then
    ok "discord.com resolves to $sys_ip (unfiltered)"
else
    bad "discord.com resolves to '${sys_ip:-nothing}', which looks filtered"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://discord.com/api/v9/gateway)"
if [[ "$code" == "200" ]]; then
    ok "discord.com answers through the bypass"
else
    bad "discord.com did not answer through the bypass (HTTP $code)"
fi

# The updater connects directly with no proxy, so test it the same way.
for host in $RELAY_HOSTS; do
    hosts_ip="$(dscacheutil -q host -a name "$host" | awk '/^ip_address:/ { print $2; exit }')"
    if [[ "$hosts_ip" == "127.0.0.1" ]]; then
        ok "$host points at the local relay"
    else
        bad "$host resolves to '${hosts_ip:-nothing}', not the local relay"
    fi
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --noproxy '*' \
    'https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=osx&arch=arm64')"
if [[ "$code" == "200" ]]; then
    ok "Discord's updater can reach updates.discord.com"
else
    bad "Discord's updater cannot reach updates.discord.com (HTTP $code)"
fi

exit "$failed"
