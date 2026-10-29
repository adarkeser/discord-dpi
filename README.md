# discord-dpi

Gets Discord working on macOS on Turkish networks that block it, without touching any other traffic.

For Windows, see [windows/README.md](windows/README.md). It uses the same byedpi bypass and the same `domains.txt`.

## How it works

Discord is blocked in two ways: the ISP's DNS returns a block page address, and the filter resets any TLS connection that names `discord.com` in its handshake.

- **DNS:** macOS lets each domain have its own DNS server (`/etc/resolver`). Only the domains in `domains.txt` are looked up through OpenDNS on port 443, which ISPs that hijack normal DNS don't touch. Every other lookup stays as it was.
- **Handshake:** a proxy config (PAC) sends only those same domains to [byedpi](https://github.com/hufrea/byedpi) running on `127.0.0.1:10800`. byedpi splits the TLS handshake so the filter can't read the site name. Everything else connects directly.
- **Updater:** Discord's built-in updater ignores proxy settings. `/etc/hosts` points `updates.discord.com` at this Mac, and a small relay on port 443 passes those connections through byedpi.
- **Voice** goes straight to Discord's servers over UDP and isn't filtered on the networks tested, so it needs nothing extra.

The filter matches the end of the name (anything ending in `discord.com`), so the split has to land inside that part. `test.sh` includes `updates.discord.com` for that reason.

Cost: byedpi uses about 8 MB of memory and no CPU while idle. The PAC server and the relay don't stay running; macOS starts them for a moment only when a connection comes in.

## Use

```bash
./install.sh     # builds byedpi, finds a method that works here, installs (asks for your password once)
./status.sh      # checks every piece
./uninstall.sh   # removes everything and restores the network settings
```

Then quit Discord completely (Cmd+Q) and open it again.

**If Discord stops working on another network:** run `./test.sh && ./install.sh`. That picks a method that works there. A fallback method is already set up and kicks in automatically when the main one gets blocked.

**If you add a new network adapter** (USB tethering, a new Ethernet dongle), run `./install.sh` again so the proxy config is set on it too.

## What it changes

| Where | What |
|---|---|
| `~/Library/Application Support/discord-dpi/` | byedpi binary, PAC file, PAC server and relay scripts |
| `~/Library/LaunchAgents/local.discord-dpi.*.plist` | starts byedpi and the PAC server at login |
| `/Library/LaunchDaemons/local.discord-dpi.relay.plist` | opens port 443 for the updater relay (the relay itself runs as you) |
| `/etc/resolver/<domain>` | per-domain DNS, one file per line of `domains.txt` |
| `/etc/hosts` | two lines for `updates.discord.com`, marked `# managed by discord-dpi` |
| Network settings | "Automatic proxy configuration" on each network service |
| `~/Library/Logs/discord-dpi.log` | byedpi errors, if any |

Ports, DNS servers and the byedpi version are set in `config.sh`.

## Credits

[byedpi](https://github.com/hufrea/byedpi) (MIT) does the actual bypass. The idea of wrapping it on macOS comes from the macOS port in [GoodbyeDPI-Turkey](https://github.com/cagritaskn/GoodbyeDPI-Turkey).
