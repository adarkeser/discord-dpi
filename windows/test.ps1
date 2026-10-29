# Tries byedpi methods against the blocked Discord hosts and saves the ones
# that get through to method.conf (best first). install.ps1 runs this when
# method.conf is missing. Run it again (test.cmd) after switching to a network
# where Discord stops working, then run install.cmd.
. "$PSScriptRoot\config.ps1"

if (-not ((Test-Path $Ciadpi) -and (Test-Path $Helper))) {
    & "$KitDir\build.ps1"
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

$TestPort = 10899
# updates.discord.com matters: the filter matches the end of the name
# ("*.discord.com"), so a split near the start of a long name doesn't help.
$Names = @('discord.com', 'gateway.discord.gg', 'cdn.discordapp.com', 'updates.discord.com')
# The first two are the macOS kit's method.conf, which gets through on eduroam
# where GoodbyeDPI does not. "-o -5+se" sends one byte as TCP urgent data,
# 5 bytes before the end of the name: the filter reads it as part of the name,
# the server drops it. Trying these first means a test at home still picks a
# method that also works on eduroam. The rest go cheapest first.
$Methods = @(
    '-o -5+se'
    '-o -5+se -r 1+s'
    '-s 1+s'
    '-d 1+s'
    '-o 1+s'
    '-s -5+se'
    '-d -5+se'
    '-q -5+se'
    '-o 1+s -o -5+se'
    '-s 1+s -d -5+se'
    '-r -5+se'
    '-s 1+s -d 3+s -r 3+s'
)

$ips = @()
foreach ($name in $Names) {
    $ip = Get-RealIp $name
    if (-not $ip) { Die "Could not look up $name on an unfiltered DNS server." }
    $ips += $ip
}

# Without the bypass these should fail. If they don't, nothing is blocked here.
$directOk = 0
for ($i = 0; $i -lt $Names.Count; $i++) {
    $code = Get-HttpCode "https://$($Names[$i])/" @('--resolve', "$($Names[$i]):443:$($ips[$i])") 5
    if ($code -ne '000') { $directOk++ }
}
if ($directOk -eq $Names.Count) { Log 'Discord is reachable without any bypass on this network. Testing anyway.' }

# Clear copies left over from an interrupted run, and never leave one behind.
function Stop-TestProxies {
    Get-CimInstance Win32_Process -Filter "Name='ciadpi.exe'" |
        Where-Object { $_.CommandLine -like "*-p $TestPort *" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
Stop-TestProxies

$passing = @()
Write-Host ''
Write-Host ('  {0,-24} {1}' -f 'method', "result (2 rounds x $($Names.Count) hosts)")
try {
    foreach ($m in $Methods) {
        $proc = Start-Process -FilePath $Ciadpi -WindowStyle Hidden -PassThru `
            -ArgumentList (@('-i', '127.0.0.1', '-p', "$TestPort") + ($m -split ' '))
        if (-not (Wait-Port $TestPort) -or $proc.HasExited) {
            Die "ciadpi did not start. Is something else using port $TestPort?"
        }
        $ok = 0; $total = 0
        foreach ($round in 1, 2) {
            for ($i = 0; $i -lt $Names.Count; $i++) {
                $total++
                $code = Get-HttpCode "https://$($Names[$i])/" `
                    @('--socks5', "127.0.0.1:$TestPort", '--resolve', "$($Names[$i]):443:$($ips[$i])") 6
                if ($code -ne '000') { $ok++ }
            }
        }
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc.WaitForExit(3000) | Out-Null
        Write-Host ('  {0,-24} ' -f $m) -NoNewline
        if ($ok -eq $total) {
            Write-Host "$ok/$total works" -ForegroundColor Green
            $passing += $m
        } else {
            Write-Host "$ok/$total" -ForegroundColor Red
        }
    }
} finally {
    Stop-TestProxies
}
Write-Host ''

if ($passing.Count -eq 0) { Die 'No method got through on this network.' }

$passing | Select-Object -First 2 | Set-Content -Path $MethodFile -Encoding ASCII
$fallback = if ($passing.Count -gt 1) { ", fallback: '$($passing[1])'" } else { '' }
Log "Saved to method.conf. Main: '$($passing[0])'$fallback"
exit 0
