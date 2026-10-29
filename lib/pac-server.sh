#!/bin/bash
# Serves proxy.pac over HTTP. Discord (Chromium) refuses file:// PAC URLs, so it
# has to come from a server. launchd runs one copy of this per connection with
# the socket on stdin/stdout (inetd mode), so nothing stays running in between.

pac="$(dirname "$0")/proxy.pac"

# Read the request headers before answering. Closing a socket with unread
# data in it resets the connection, and the client can lose the response.
while IFS= read -r -t 2 line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
done

len="$(wc -c < "$pac" | tr -d ' ')"
printf 'HTTP/1.0 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$len"
cat "$pac"
