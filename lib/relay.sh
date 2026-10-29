#!/bin/bash
# Relays one connection for a RELAY_HOSTS name through ciadpi. launchd listens
# on port 443 and starts this once per connection with the socket on
# stdin/stdout. The real address is looked up on the unfiltered DNS servers,
# because /etc/hosts points the name back at this Mac.
# Args: <host> <socks port> <dns port> <dns server>...
host="$1" socks_port="$2" dns_port="$3"
shift 3

ip=""
for server in "$@"; do
    ip="$(/usr/bin/dig +short +time=2 +tries=1 @"$server" -p "$dns_port" "$host" A 2>/dev/null \
        | /usr/bin/grep -E '^[0-9.]+$' | /usr/bin/head -1)"
    [[ -n "$ip" ]] && break
done
[[ -n "$ip" ]] || exit 1

exec /usr/bin/nc -X 5 -x "127.0.0.1:$socks_port" "$ip" 443
