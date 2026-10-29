# Shows whether each piece of the bypass is in place and working.
. "$PSScriptRoot\config.ps1"
$ErrorActionPreference = 'Continue'

$script:failed = 0
function Ok([string]$msg) { Write-Host '  OK    ' -ForegroundColor Green -NoNewline; Write-Host $msg }
function Bad([string]$msg) { Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline; Write-Host $msg; $script:failed = 1 }

foreach ($name in $ServiceProxy, $ServiceHelper) {
    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { Ok "service '$name' is running" }
    else { Bad "service '$name' is not running (log: $LogFile)" }
}

if (Test-Listening $SocksPort '127.0.0.1') { Ok "ciadpi is listening on 127.0.0.1:$SocksPort" }
else { Bad "ciadpi is not listening on 127.0.0.1:$SocksPort" }

if (Test-Listening 53 $DnsListen -Udp) { Ok "the helper answers DNS on ${DnsListen}:53" }
else { Bad "nothing answers DNS on ${DnsListen}:53 (log: $LogFile)" }

if (Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $NrptComment }) {
    Ok 'Discord DNS lookups go to the helper (NRPT rule)'
} else {
    Bad 'the NRPT rule for Discord domains is missing'
}

# What Windows itself resolves discord.com to.
$addr = $null
try {
    $addr = [Net.Dns]::GetHostAddresses('discord.com') |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
} catch { }
if ($addr -and "$addr".StartsWith("$RelayPrefix.")) { Ok "discord.com resolves to $addr (the local relay)" }
else { Bad "discord.com resolves to '$addr', not the local relay" }

$code = Get-HttpCode 'https://discord.com/api/v9/gateway'
if ($code -eq '200') { Ok 'discord.com answers through the bypass' }
else { Bad "discord.com did not answer through the bypass (HTTP $code)" }

# Discord's updater ignores proxy settings. It goes through the relay like
# everything else, so a plain request tests the same path.
$code = Get-HttpCode 'https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=win&arch=x64' -timeout 10
if ($code -ne '000') { Ok "Discord's updater can reach updates.discord.com (HTTP $code)" }
else { Bad "Discord's updater cannot reach updates.discord.com" }

exit $script:failed
