# Installs the Discord-only bypass on Windows. Start it with install.cmd, which
# asks for administrator rights. Safe to run again, for example after editing
# domains.txt or running test.cmd on a new network.
. "$PSScriptRoot\config.ps1"
Assert-Admin

if (-not ((Test-Path $Ciadpi) -and (Test-Path $Helper))) {
    & "$KitDir\build.ps1"
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
if (-not ((Test-Path $MethodFile) -and (Get-Content $MethodFile))) {
    & "$KitDir\test.ps1"
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

$methods = @(Get-Content $MethodFile | Where-Object { $_.Trim() })
$main = $methods[0]
$fallback = if ($methods.Count -gt 1) { $methods[1] } else { '' }
if (-not $main) { Die 'method.conf is empty. Run test.cmd' }

# ciadpi listens on localhost only, so nothing else on the network can use it.
# If the main method gets reset, or gets no answer within 5 s (-T, which byedpi
# has on Windows but not on macOS), it retries with the fallback.
$proxyCmd = "`"$InstallDir\ciadpi.exe`" -i 127.0.0.1 -p $SocksPort -T 5 $main"
if ($fallback) { $proxyCmd += " -A torst,ssl_err $fallback" }

if (Get-Process goodbyedpi -ErrorAction SilentlyContinue) {
    Warn 'GoodbyeDPI is running. It changes the same connections and can break this bypass. Stop it first.'
}
Log "Method: '$main'$(if ($fallback) { " (fallback: '$fallback')" })"

# The DNS rule goes first and comes back last, so a failed install leaves
# Discord names resolving normally instead of pointing at a missing helper.
Log 'Removing the old setup, if any'
Remove-KitDns
Remove-KitService $ServiceHelper
Remove-KitService $ServiceProxy
Stop-KitProcesses

Log 'Copying files'
New-Item -ItemType Directory -Force $InstallDir, $DataDir | Out-Null
Copy-Item $Ciadpi, $Helper $InstallDir -Force
@(
    '# Written by install.ps1, read by discord-dpi.exe when it starts.'
    "socks_port=$SocksPort"
    "dns_listen=$DnsListen"
    "relay_prefix=$RelayPrefix"
    "dns_servers=$($DnsServers -join ',')"
    "dns_port=$DnsPort"
    "domains=$((Get-Domains) -join ',')"
    "log_file=$LogFile"
) | Set-Content -Path (Join-Path $InstallDir 'settings.ini') -Encoding ASCII
# The services run as LOCAL SERVICE (S-1-5-19), which may write only here.
& icacls.exe $DataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null

Log 'Starting the services'
New-KitService $ServiceProxy 'discord-dpi proxy' 'byedpi (ciadpi) on 127.0.0.1, used by discord-dpi.' $proxyCmd
New-KitService $ServiceHelper 'discord-dpi' 'Sends Discord connections through the local byedpi proxy.' "`"$InstallDir\discord-dpi.exe`""
try {
    Start-Service $ServiceProxy
    Start-Service $ServiceHelper
} catch {
    Die "A service did not start: $($_.Exception.Message) See $LogFile"
}
if (-not (Wait-Port $SocksPort)) { Die "ciadpi did not start. Is something else using port $SocksPort?" }

# The bypass on its own, the same way test.ps1 checks it.
foreach ($name in 'discord.com', 'updates.discord.com') {
    $ip = Get-RealIp $name
    if (-not $ip) { Die "Could not look up $name on an unfiltered DNS server." }
    $code = Get-HttpCode "https://$name/" @('--socks5', "127.0.0.1:$SocksPort", '--resolve', "${name}:443:$ip")
    if ($code -eq '000') { Die "Bypass check failed for $name. Run test.cmd to pick a new method." }
}

# Then the helper: ask it for discord.com directly and connect to the address
# it hands out, before any real lookup is sent its way.
$relayIp = $null
try {
    $relayIp = (Resolve-DnsName discord.com -Server $DnsListen -Type A -DnsOnly -QuickTimeout |
        Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
} catch { }
if (-not $relayIp) { Die "The helper does not answer DNS on ${DnsListen}:53. See $LogFile" }
$code = Get-HttpCode 'https://discord.com/api/v9/gateway' @('--resolve', "discord.com:443:$relayIp")
if ($code -ne '200') { Die "discord.com did not answer through the helper (HTTP $code). See $LogFile" }

Log 'Sending Discord DNS lookups to the helper'
$namespaces = foreach ($d in Get-Domains) { ".$d"; $d }   # ".x" covers subdomains, "x" the name itself
Add-DnsClientNrptRule -Namespace $namespaces -NameServers $DnsListen -Comment $NrptComment | Out-Null
Clear-DnsClientCache

Write-Host ''
& "$KitDir\status.ps1"
Write-Host ''
Log 'Done. Quit Discord completely (right-click its tray icon, Quit Discord) and open it again.'
exit 0
