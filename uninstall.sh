#!/bin/bash
# Removes everything install.sh set up and puts the network settings back.
set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$KIT_DIR/lib/admin.sh"

[[ $EUID -ne 0 ]] || die "Run it without sudo. It asks for your password when it needs it."

# Proxy config first, so no app is left pointing at a proxy that is gone.
log "Removing DNS and proxy settings (needs your password)"
run_as_admin uninstall

log "Stopping background services"
for label in "$LABEL_PROXY" "$LABEL_PAC"; do
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done

rm -rf "$INSTALL_DIR"
rm -f "$LOG_FILE"
log "Uninstalled. The kit folder itself is untouched; delete it if you no longer need it."
