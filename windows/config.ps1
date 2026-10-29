# Settings and helpers shared by every discord-dpi script on Windows.
# Dot-sourced, not run. Keep this file ASCII: Windows PowerShell 5.1 reads
# files without a BOM in the local code page.

$ErrorActionPreference = 'Stop'

$KitDir = $PSScriptRoot
$DomainsFile = Join-Path (Split-Path $KitDir -Parent) 'domains.txt'
$MethodFile = Join-Path $KitDir 'method.conf'
$BuildDir = Join-Path $KitDir '.build'
$BinDir = Join-Path $KitDir 'bin'
$Ciadpi = Join-Path $BinDir 'ciadpi.exe'
$Helper = Join-Path $BinDir 'discord-dpi.exe'

# byedpi's official Windows build, the same release as the macOS kit, checked
# against the SHA-256 that GitHub lists for the file.
$ByedpiUrl = 'https://github.com/hufrea/byedpi/releases/download/v0.17.3/byedpi-17.3-x86_64-w64.zip'
$ByedpiSha256 = '70d2c94147193cb915f9c6eb5144b8d404dacbcfa90bda2383b6b211afafa456'

$SocksPort = 10800

# DNS used to find the real addresses of Discord hosts. Plain DNS on port 443
# gets past networks that hijack normal DNS traffic on port 53. If OpenDNS ever
# stops answering, Yandex works as a fallback: 77.88.8.8, 77.88.8.1 on port 1253.
$DnsServers = @('208.67.222.222', '208.67.220.220')
$DnsPort = 443

# Where the helper answers DNS (the NRPT rule points here; NRPT has no port
# setting, so it must be 53), and the loopback range it hands out to Discord
# names. Each name gets its own 127.21.x.y.
$DnsListen = '127.0.0.1'
$RelayPrefix = '127.21'

$ServiceProxy = 'discord-dpi-proxy'
$ServiceHelper = 'discord-dpi'
$InstallDir = Join-Path $env:ProgramFiles 'discord-dpi'
$DataDir = Join-Path $env:ProgramData 'discord-dpi'
$LogFile = Join-Path $DataDir 'discord-dpi.log'

# Written into the NRPT rule, so uninstall only removes our own.
$NrptComment = 'managed by discord-dpi'

function Log([string]$msg) { Write-Host "[discord-dpi] $msg" -ForegroundColor Cyan }
function Warn([string]$msg) { Write-Host "[discord-dpi] $msg" -ForegroundColor Yellow }
function Die([string]$msg) { Write-Host "[discord-dpi] $msg" -ForegroundColor Red; exit 1 }

function Assert-Admin {
    $me = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die 'This needs administrator rights. Start it with install.cmd or uninstall.cmd, which ask for them.'
    }
}

# Domains from domains.txt, one per line, comments and blanks dropped.
function Get-Domains {
    Get-Content $DomainsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}

# Real IP for a Discord host, asked from the unfiltered DNS servers directly.
function Get-RealIp([string]$name) {
    $ip = & $Helper resolve $name $DnsPort @DnsServers
    if ($LASTEXITCODE -eq 0) { $ip } else { $null }
}

# HTTP status code of a request, or '000' if it never got an answer.
# curl.exe ships with Windows 10 1803 and later. Plain "curl" would be the
# PowerShell alias for Invoke-WebRequest.
function Get-HttpCode([string]$url, [string[]]$extra = @(), [int]$timeout = 8) {
    $code = & curl.exe -s -o NUL -w '%{http_code}' --ssl-no-revoke --max-time $timeout @extra $url
    if ($code) { "$code" } else { '000' }
}

function Test-Listening([int]$port, [string]$address = '', [switch]$Udp) {
    $props = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $list = if ($Udp) { $props.GetActiveUdpListeners() } else { $props.GetActiveTcpListeners() }
    [bool]($list | Where-Object { $_.Port -eq $port -and (-not $address -or $_.Address.ToString() -eq $address) })
}

function Wait-Port([int]$port) {
    for ($i = 0; $i -lt 40; $i++) {
        if (Test-Listening $port) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Remove-KitDns {
    Get-DnsClientNrptRule | Where-Object { $_.Comment -eq $NrptComment } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }
    Clear-DnsClientCache
}

function Remove-KitService([string]$name) {
    if (-not (Get-Service $name -ErrorAction SilentlyContinue)) { return }
    Stop-Service $name -Force -ErrorAction SilentlyContinue
    & sc.exe delete $name | Out-Null
    # Windows only removes it once nothing holds it open.
    for ($i = 0; $i -lt 40 -and (Get-Service $name -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 250
    }
    if (Get-Service $name -ErrorAction SilentlyContinue) {
        Die "Windows has not removed the old '$name' service yet. Close the Services window if it is open, then try again."
    }
}

# Anything still running from the install folder, for example after a crash.
function Stop-KitProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function New-KitService([string]$name, [string]$display, [string]$description, [string]$command) {
    New-Service -Name $name -DisplayName $display -Description $description `
        -BinaryPathName $command -StartupType Automatic | Out-Null
    # LOCAL SERVICE instead of SYSTEM: neither program needs more than that.
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
    $r = Invoke-CimMethod -InputObject $svc -MethodName Change `
        -Arguments @{ StartName = 'NT AUTHORITY\LocalService'; StartPassword = '' }
    if ($r.ReturnValue -ne 0) { Die "Could not set the account for '$name' (error $($r.ReturnValue))." }
    # Restart after a crash: after 5 s, 5 s, then every minute.
    & sc.exe failure $name reset= 86400 actions= restart/5000/restart/5000/restart/60000 | Out-Null
}
