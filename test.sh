#!/bin/bash
# Tries byedpi methods against the blocked Discord hosts and saves the ones
# that get through to method.conf (best first). install.sh runs this when
# method.conf is missing; run it by hand after switching to a network where
# Discord stops working.
set -euo pipefail
source "$(dirname "$0")/config.sh"

[[ -x "$BIN" ]] || die "ciadpi is not built yet. Run ./build.sh first."

TEST_PORT=10899
# updates.discord.com matters: the filter matches the end of the name
# ("*.discord.com"), so a split near the start of a long name doesn't help.
HOSTS=(discord.com gateway.discord.gg cdn.discordapp.com updates.discord.com)
# Cheapest first: fewer extra packets means less that can go wrong.
# "-5+se" splits 5 bytes before the end of the name, inside "discord.com" etc.
METHODS=(
    "-s 1+s"
    "-d 1+s"
    "-o 1+s"
    "-s -5+se"
    "-d -5+se"
    "-o -5+se"
    "-q -5+se"
    "-o 1+s -o -5+se"
    "-s 1+s -d -5+se"
    "-r -5+se"
    "-o -5+se -r 1+s"
    "-s 1+s -d 3+s -r 3+s"
)

declare -a IPS=()
for h in "${HOSTS[@]}"; do
    ip="$(real_ip "$h")"
    [[ -n "$ip" ]] || die "Could not look up $h on an unfiltered DNS server."
    IPS+=("$ip")
done

# Without the bypass these should fail. If they don't, nothing is blocked here.
direct_ok=0
for i in "${!HOSTS[@]}"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "${HOSTS[$i]}:443:${IPS[$i]}" "https://${HOSTS[$i]}/" || true)"
    [[ "$code" != "000" ]] && direct_ok=$((direct_ok + 1))
done
if (( direct_ok == ${#HOSTS[@]} )); then
    log "Discord is reachable without any bypass on this network. Testing anyway."
fi

# ciadpi ignores SIGTERM on macOS (its handler calls shutdown() on the listening
# socket, which only wakes the event loop on Linux), so test copies get SIGKILL.
# Clear any left over from an interrupted run, and never leave one behind.
pid=""
pkill -9 -f "ciadpi -i 127.0.0.1 -p $TEST_PORT" 2>/dev/null || true
trap '[[ -z "$pid" ]] || kill -9 "$pid" 2>/dev/null || true' EXIT

passing=()
printf '\n  %-24s %s\n' "method" "result (2 rounds x ${#HOSTS[@]} hosts)"
for m in "${METHODS[@]}"; do
    # shellcheck disable=SC2086
    "$BIN" -i 127.0.0.1 -p "$TEST_PORT" $m >/dev/null 2>&1 &
    pid=$!
    if ! wait_for_port "$TEST_PORT" || ! kill -0 "$pid" 2>/dev/null; then
        die "ciadpi did not start. Is something else using port $TEST_PORT?"
    fi
    ok=0; total=0
    for round in 1 2; do
        for i in "${!HOSTS[@]}"; do
            total=$((total + 1))
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
                --socks5 "127.0.0.1:$TEST_PORT" \
                --resolve "${HOSTS[$i]}:443:${IPS[$i]}" "https://${HOSTS[$i]}/" || true)"
            [[ "$code" != "000" ]] && ok=$((ok + 1))
        done
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
    if (( ok == total )); then
        printf '  %-24s \033[32m%d/%d works\033[0m\n' "$m" "$ok" "$total"
        passing+=("$m")
    else
        printf '  %-24s \033[31m%d/%d\033[0m\n' "$m" "$ok" "$total"
    fi
done
echo

(( ${#passing[@]} > 0 )) || die "No method got through on this network."

printf '%s\n' "${passing[@]:0:2}" > "$METHOD_FILE"
log "Saved to method.conf. Main: '${passing[0]}'${passing[1]:+, fallback: '${passing[1]}'}"
