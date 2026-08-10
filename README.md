# devicelink

Use an iPhone that's plugged into a **Windows PC** from Xcode on a **remote Mac**.

```
Windows PC                                        the Mac
──────────                                        ───────
iPhone ─USB─▶ Apple Mobile Device Service
                      :27015 ──ssh -R──▶ 127.0.0.1:27015
                                                  │
                                              usbfluxd
                                                  │
                                          /var/run/usbmuxd ──▶ Xcode / Finder
```

Cloud Macs (EC2, MacStadium, a Mac in another room) have no USB port you can
reach. This bridges the gap without any USB-over-IP hardware or licence.

## Why there's no USB-over-IP product here

There doesn't need to be. On Windows, Apple's own `AppleMobileDeviceService.exe`
already exposes the usbmux protocol on TCP `127.0.0.1:27015` — the same protocol
macOS serves on the `/var/run/usbmuxd` Unix socket. So the phone is *already* a
network service on Windows. All that's missing is a pipe, and something on the
Mac willing to treat a remote usbmuxd as local — which is exactly what
[usbfluxd](https://github.com/corellium/usbfluxd) does.

This also avoids a dead end: **VirtualHere's iPhone-to-Mac support broke after
macOS 10.14** and is [unsupported on Monterey and later](https://www.virtualhere.com/node/3601).
On macOS 26 it is not an option at all.

Because the PC initiates the SSH connection, this works from behind NAT with no
inbound firewall rules on either side.

## Setup

### One time, on the Mac

```bash
git clone https://github.com/VishnuXD44/devicelink.git
cd devicelink
./devicelink install
```

`install` pulls in libimobiledevice via Homebrew and builds usbfluxd from source,
putting both binaries in `/usr/local/bin`.

To get the CLI itself on your `PATH`, symlink it — the script resolves symlinks,
so it still finds its own helper files:

```bash
ln -s "$PWD/devicelink" ~/.local/bin/devicelink
```

### One time, on Windows

Install the **Apple Devices** app from the Microsoft Store (or iTunes). That is
what provides the usbmux endpoint; nothing else on Windows is required. Then
enable the OpenSSH client if it isn't already: *Settings → System → Optional
features → OpenSSH Client*.

### Getting the script across

**The repo does not need to move.** The Mac is the build machine; exactly one
file — `windows/devicelink.ps1` — belongs on Windows. Run this on the Mac and it
prints copy-paste commands with your addresses already filled in:

```bash
devicelink windows
```

It covers `scp`, an SSH-only variant if `scp` isn't available, and a clipboard
fallback for console/VNC sessions (`--emit-base64` writes a paste-safe blob).

You can also skip the file entirely. The tunnel is one command:

```powershell
ssh -N -R 27015:127.0.0.1:27015 <user>@<mac>
```

That is fully functional on its own — the script only adds preflight checks and
auto-reconnect.

> Windows blocks unsigned scripts and flags copied files. Run
> `Unblock-File .\devicelink.ps1` once, and invoke with
> `powershell -ExecutionPolicy Bypass -File .\devicelink.ps1 ...`

## Each session

**1. Windows** — plug in the phone, unlock it, tap **Trust**, then:

```powershell
.\devicelink.ps1 -MacHost <mac-ip> -User <mac-user> -IdentityFile C:\keys\mac.pem
```

It preflights the Apple service, the usbmux port, and the attached device before
opening the tunnel, and reconnects automatically if the link drops.

**2. Mac** — start the bridge, then open Xcode:

```bash
devicelink up
```

Order matters: **usbfluxd must be running before Xcode launches**, or Xcode won't
see the device. If you got it backwards, quit Xcode and reopen it.

**3. When you're done**

```bash
devicelink down
```

## Commands

| Command | What it does |
|---|---|
| `install` | Build and install usbfluxd + dependencies |
| `up` | Start the bridge (refuses if the tunnel isn't open, so it never half-configures) |
| `down` | Stop the bridge and restore the original socket |
| `status` | Quick check of bridge, tunnel, socket, and visible devices |
| `doctor` | Diagnose every leg of the chain and say what to fix |
| `watch` | Live monitor of connects and disconnects, repairing what it can |
| `wait` | Block until a device is reachable — for scripts and CI |
| `windows` | Print the copy-paste commands for the Windows side |
| `selftest` | Prove the bridge works with no phone and no Windows PC (see below) |
| `repair` | Restore `/var/run/usbmuxd` after a crash |

`--port N` overrides the tunnel port on both sides; `DEVICELINK_PORT` persists it.

## Scripting against it

`wait` exits 0 as soon as a device is reachable and non-zero on timeout, so an
install script can heal a dropped tunnel instead of failing:

```bash
devicelink wait --timeout 60 || { devicelink down; devicelink up; }
xcodebuild -project MyApp.xcodeproj -scheme MyApp \
    -destination 'generic/platform=iOS' -derivedDataPath build build
ideviceinstaller install build/MyApp.ipa
```

## Gotchas this tool handles for you

- **`xcrun devicectl` and `xcrun xctrace` will never see the phone.** They speak
  CoreDevice; the bridge carries only the older usbmux protocol. "No devices
  found" from `devicectl` means nothing — use `idevice_id -l` and the
  `libimobiledevice` tools, and check `devicelink status`.
- **The bridge does not pick up a tunnel that appears underneath it.** If
  usbfluxd was already running when the PC reconnected, it registered only the
  local socket and the phone stays invisible. `watch` and `wait` re-register the
  remote automatically; by hand it's `devicelink down && devicelink up`.
- **Port 5000 is unusable on macOS.** AirPlay Receiver (ControlCenter) holds it.
  The default here is 27015; `doctor` calls this out explicitly if you override it.
- **A crashed usbfluxd leaves the Mac's iOS tooling broken**, because the real
  socket is still sitting at `/var/run/usbmuxd.orig`. `repair` puts it back, and
  `up` refuses to start into that state rather than compounding it.
- **First attach is slow.** iOS syncs roughly 4 GB of symbol cache — budget 15–20
  minutes before the device is usable for debugging. This is not a hang.

## The thing this does *not* solve

USB forwarding gets the **app onto the phone**. It does not give the phone
**network access to the Mac**, so an app that calls a dev server running on the
Mac will still fail: that server is on the Mac's private address, which the
phone cannot route to.

Put the phone and the Mac on a [Tailscale](https://tailscale.com) tailnet and
point the app at the Mac's tailnet address. That solves phone→server, and can
replace the SSH tunnel for usbfluxd too.

## Security

The tunnel is loopback-bound on both ends — `ssh -R` binds to the Mac's
`127.0.0.1` unless `GatewayPorts` is enabled, so the phone is not exposed to your
network or the internet. Keep it that way. An unauthenticated usbmux endpoint on
a routable interface hands anyone on the network full control of an unlocked
phone.

## Verifying without a phone

```bash
devicelink selftest
```

This substitutes `socat` for the SSH tunnel and the Windows service by exposing
the Mac's own usbmuxd over TCP, so **real usbmux protocol travels the exact
production path**: `idevice_id` → usbfluxd → TCP → socat → the real usbmuxd. It
confirms the socket swap, the TCP hop, and the protocol round-trip, then restores
everything — including on failure or Ctrl-C.

An empty device list is a pass. It still proves the round-trip: the query reached
a real usbmuxd through the bridge and came back well-formed. Run this first
whenever something breaks; it separates "the bridge is broken" from "the phone or
the tunnel is."

## Status

- usbfluxd 1.2.1 builds and runs on macOS 26.3.1 / Apple Silicon (verified, arm64).
- `selftest` passes: socket swap, TCP hop, and usbmux round-trip all confirmed,
  with the system socket verified byte-identical afterwards.
- `help`, `status`, `doctor`, `repair`, `windows`, `wait` and the `up` no-tunnel
  guard are exercised; `devicelink.ps1` parses cleanly under PowerShell 7.
- Developed against an EC2 mac instance. The `windows` command reads EC2 instance
  metadata to fill in the Mac's public address and falls back to `hostname`
  elsewhere; everything else is host-agnostic.

## Layout

```
devicelink              the CLI — everything on the Mac side
probe.py                one-shot usbmux state probe, used by watch/wait
selftest.sh             the no-phone proof
windows/devicelink.ps1  the only file that goes to the Windows PC
```

## License

MIT — see [LICENSE](LICENSE).
