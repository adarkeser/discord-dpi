# Runs lib/system.sh with admin rights. Sourced by install.sh and uninstall.sh.
# Uses sudo in a terminal and the macOS password dialog everywhere else
# (for example when started from an app that has no terminal attached).
run_as_admin() {
    local script="$KIT_DIR/lib/system.sh"
    if sudo -n true 2>/dev/null || [[ -t 0 ]]; then
        sudo /bin/bash "$script" "$@"
    else
        osascript - /bin/bash "$script" "$@" <<'APPLESCRIPT'
on run argv
    set cmd to ""
    repeat with a in argv
        set cmd to cmd & quoted form of (a as text) & " "
    end repeat
    return do shell script cmd with administrator privileges
end run
APPLESCRIPT
    fi
}
