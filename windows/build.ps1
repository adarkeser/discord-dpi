# Downloads byedpi's official Windows build (pinned, SHA-256 checked) and
# compiles the helper with the C# compiler that ships with Windows, into bin\.
. "$PSScriptRoot\config.ps1"

if (-not [Environment]::Is64BitOperatingSystem) { Die 'This needs 64-bit Windows.' }

$ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow in PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force $BuildDir, $BinDir | Out-Null

$zip = Join-Path $BuildDir (Split-Path $ByedpiUrl -Leaf)
if (-not (Test-Path $zip)) {
    Log 'Downloading byedpi'
    Invoke-WebRequest -Uri $ByedpiUrl -OutFile $zip -UseBasicParsing
}
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $ByedpiSha256) {
    Remove-Item $zip -Force
    Die "byedpi download does not match: expected $ByedpiSha256, got $hash. Run it again."
}

$unpacked = Join-Path $BuildDir 'byedpi'
if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
Expand-Archive -Path $zip -DestinationPath $unpacked
$exe = Get-ChildItem $unpacked -Recurse -Filter 'ciadpi.exe' | Select-Object -First 1
if (-not $exe) { Die 'ciadpi.exe is not in the byedpi download.' }
Copy-Item $exe.FullName $Ciadpi -Force

# .NET Framework 4 is part of Windows 10 and 11, and its folder has csc.exe.
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { Die "The C# compiler is missing ($csc). Is .NET Framework 4 turned off in Windows Features?" }
Log 'Compiling the helper'
& $csc /nologo /optimize+ /target:exe "/out:$Helper" /reference:System.ServiceProcess.dll (Join-Path $KitDir 'src\discord-dpi.cs')
if ($LASTEXITCODE -ne 0) { Die 'Compiling the helper failed (errors above).' }

Log "Built $Ciadpi and $Helper"
exit 0
