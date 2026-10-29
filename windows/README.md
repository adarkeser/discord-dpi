# discord-dpi for Windows

Gets Discord working on Windows on networks that block it, without touching any other traffic. Same bypass as the macOS kit in the folder above, wired into Windows differently.

## Why not GoodbyeDPI

The macOS kit's test found that plain splits of the TLS handshake don't get through: the filter puts the pieces back together and still reads `discord.com`. What works (and works on eduroam) is byedpi's `-o -5+se`, saved in the macOS kit's `method.conf`. It sends one extra byte as TCP "urgent" data 5 bytes before the end of the name. The filter counts that byte as part of the name, the server drops it. GoodbyeDPI has no such mode: it only splits and sends fake packets.

## How it works

- **ciadpi** ([byedpi](https://github.com/hufrea/byedpi)'s official Windows build) runs as a service on `127.0.0.1:10800` and does the bypass, exactly as on macOS.
- **DNS:** an NRPT rule (Windows' per-domain DNS setting) sends lookups for the domains in `../domains.txt` to a small helper service on `127.0.0.1:53`. It answers each Discord name with its own loopback address (`127.21.x.y`). Every other lookup stays as it was.
- **Relay:** the helper listens on those addresses on port 443. It reads the site name from the TLS handshake, finds the real address on OpenDNS (port 443, which networks that hijack DNS don't touch) and passes the connection through ciadpi.
- **Why not a proxy setting like on macOS:** Discord on Windows does not reliably follow the system proxy, and its updater ignores it. DNS catches every program, the updater included.
- **Voice** goes straight to Discord's servers over UDP by IP address, so nothing changes for it.

The helper is one C# file in `src/`. `build.ps1` compiles it with the C# compiler that is part of Windows (.NET Framework 4), so nothing extra gets installed.

## Use

Double-click:

- `install.cmd`: downloads byedpi, builds the helper, finds a method that works on this network, installs. Windows asks for administrator rights once.
- `status.cmd`: checks every piece.
- `uninstall.cmd`: removes everything and puts DNS back.

Then quit Discord completely (right-click its tray icon, Quit Discord) and open it again.

**If Discord stops working on another network:** run `test.cmd`, then `install.cmd`. The test tries the eduroam method first, so a test at home picks it too whenever it works there. A fallback method is set up as well and kicks in automatically when the main one gets blocked.

## What it changes

| Where | What |
|---|---|
| `C:\Program Files\discord-dpi\` | `ciadpi.exe`, `discord-dpi.exe`, `settings.ini` |
| Services `discord-dpi-proxy` and `discord-dpi` | start with Windows, run as LOCAL SERVICE, restart after a crash |
| NRPT rule (`Get-DnsClientNrptRule`) | Discord domains go to `127.0.0.1`, comment `managed by discord-dpi` |
| `C:\ProgramData\discord-dpi\discord-dpi.log` | helper errors, if any (kept under 1 MB) |

Ports, DNS servers and the byedpi version are set in `config.ps1`. Nothing is changed in the proxy settings or the hosts file.

## If something fails

- **GoodbyeDPI or zapret is running:** stop it. It changes the same connections.
- **Windows Security removes `ciadpi.exe`:** some antivirus tools flag DPI bypass tools. Allow it, then run `install.cmd` again.
- **"Cannot listen for DNS on 127.0.0.1:53" in the log:** another program (a local DNS server, Docker) uses that port. Change `$DnsListen` in `config.ps1` to another loopback address such as `127.0.0.53` and install again.
- **A compile error during install:** copy the error lines. This port was written on a Mac and has not run on Windows yet.
