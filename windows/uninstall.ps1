# Removes everything install.ps1 set up. Start it with uninstall.cmd, which
# asks for administrator rights.
. "$PSScriptRoot\config.ps1"
Assert-Admin

# DNS first, so Discord names don't keep pointing at a helper that is gone.
Log 'Removing the DNS rule'
Remove-KitDns

Log 'Removing the services'
Remove-KitService $ServiceHelper
Remove-KitService $ServiceProxy
Stop-KitProcesses

Remove-Item -Recurse -Force $InstallDir, $DataDir -ErrorAction SilentlyContinue
Log 'Uninstalled. The kit folder itself is untouched; delete it if you no longer need it.'
exit 0
