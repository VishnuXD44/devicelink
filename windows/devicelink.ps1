<#
.SYNOPSIS
    Publish a locally-attached iPhone to a remote Mac so Xcode there can use it.

.DESCRIPTION
    Your iPhone stays plugged into this PC. Apple's Mobile Device Service (installed
    with the Apple Devices app or iTunes) already listens on 127.0.0.1:27015 and
    speaks the usbmux protocol, so no third-party USB-over-IP software is needed.
    This script preflights that service, then opens an SSH reverse tunnel carrying
    port 27015 to the Mac, reconnecting automatically if it drops.

    Because this PC initiates the connection, it works from behind NAT with no
    inbound firewall rules.

    On the Mac, run:  devicelink up

.PARAMETER MacHost
    Hostname or IP of the remote Mac.

.PARAMETER User
    SSH user on the Mac. Defaults to your Windows username; EC2 macOS instances
    use ec2-user.

.PARAMETER IdentityFile
    Path to the SSH private key (e.g. your EC2 .pem). If omitted, the script
    searches the usual places for a .pem and uses it when there's exactly one
    obvious match.

.PARAMETER KeyName
    Base name of the expected key file, without extension. Used to pick the
    right one during auto-discovery when several .pem files are lying around.

.PARAMETER RemotePort
    Port to open on the Mac's loopback. Defaults to 27015.
    Avoid 5000 — macOS AirPlay Receiver holds it.

.PARAMETER NoReconnect
    Exit when the tunnel drops instead of retrying.

.EXAMPLE
    .\devicelink.ps1 -MacHost 12.34.56.78 -IdentityFile C:\keys\mac.pem
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MacHost,
    [string]$User = $env:USERNAME,
    [string]$IdentityFile,
    [string]$KeyName = "",
    [int]$RemotePort = 27015,
    [int]$LocalPort = 27015,
    [switch]$NoReconnect
)

$ErrorActionPreference = "Stop"

function Write-Ok    { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "  [fail] $m" -ForegroundColor Red }
function Write-Step  { param($m) Write-Host "`n$m" -ForegroundColor Cyan }

# --- preflight -------------------------------------------------------------

Write-Step "1. Apple Mobile Device Service"
$amds = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
if (-not $amds) {
    Write-Fail "not installed"
    Write-Host "         Install the Apple Devices app from the Microsoft Store (or iTunes)."
    Write-Host "         It provides the usbmux endpoint this whole setup depends on."
    exit 1
}
if ($amds.Status -ne "Running") {
    Write-Warn "installed but not running - starting it"
    try { Start-Service $amds; Start-Sleep -Seconds 3 }
    catch { Write-Fail "could not start (try an elevated PowerShell)"; exit 1 }
}
Write-Ok "running"

Write-Step "2. usbmux endpoint on 127.0.0.1:$LocalPort"
$listening = $false
try {
    $probe = New-Object System.Net.Sockets.TcpClient
    $probe.Connect("127.0.0.1", $LocalPort)
    $listening = $probe.Connected
    $probe.Close()
} catch { $listening = $false }

if (-not $listening) {
    Write-Fail "nothing listening"
    Write-Host "         Plug the iPhone in over USB-C and unlock it. If this is the first"
    Write-Host "         time, tap Trust This Computer on the phone, then rerun."
    exit 1
}
Write-Ok "listening"

Write-Step "3. Attached Apple device"
$apple = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.FriendlyName -like "*Apple*" -and $_.Status -eq "OK" }
if ($apple) {
    foreach ($d in $apple) { Write-Ok $d.FriendlyName }
} else {
    Write-Warn "no Apple USB device detected"
    Write-Host "         The tunnel will still open, but the Mac will see no device"
    Write-Host "         until the phone is connected and trusted."
}

Write-Step "4. SSH client"
$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh) {
    Write-Fail "OpenSSH client not found"
    Write-Host "         Enable it: Settings > System > Optional features > OpenSSH Client"
    exit 1
}
Write-Ok $ssh.Source

Write-Step "5. SSH key"
if (-not $IdentityFile) {
    # Look where AWS keys actually land, preferring an exact key-pair-name match.
    $searchDirs = @(
        (Get-Location).Path,
        (Join-Path $HOME "Downloads"),
        (Join-Path $HOME ".ssh"),
        $HOME,
        (Join-Path $HOME "Desktop"),
        (Join-Path $HOME "Documents")
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $candidates = foreach ($dir in $searchDirs) {
        Get-ChildItem -Path $dir -Filter "*.pem" -File -ErrorAction SilentlyContinue
    }

    $exact = $candidates | Where-Object { $_.BaseName -eq $KeyName } | Select-Object -First 1
    if ($exact) {
        $IdentityFile = $exact.FullName
        Write-Ok "found $KeyName.pem at $IdentityFile"
    }
    elseif (($candidates | Measure-Object).Count -eq 1) {
        $IdentityFile = $candidates[0].FullName
        Write-Warn "using the only .pem found: $IdentityFile"
    }
    elseif (($candidates | Measure-Object).Count -gt 1) {
        Write-Fail "several .pem files found - pass one with -IdentityFile"
        $candidates | Select-Object -First 8 | ForEach-Object { Write-Host "           $($_.FullName)" }
        exit 1
    }
    else {
        $wanted = if ($KeyName) { "$KeyName.pem" } else { "*.pem" }
        Write-Fail "no .pem found in the usual places."
        Write-Host "         Search wider with:"
        Write-Host "           Get-ChildItem -Path C:\ -Filter $wanted -Recurse -ErrorAction SilentlyContinue"
        Write-Host "         Then rerun with -IdentityFile <path>."
        exit 1
    }
}
elseif (-not (Test-Path $IdentityFile)) {
    Write-Fail "identity file not found: $IdentityFile"
    exit 1
}
else {
    Write-Ok $IdentityFile
}

# OpenSSH refuses a key that other accounts can read. Windows inherits loose ACLs
# onto anything in Downloads, so this rejection is the norm, not the exception.
$acl = Get-Acl $IdentityFile
$others = $acl.Access | Where-Object {
    $_.IdentityReference -notmatch [regex]::Escape($env:USERNAME) -and
    $_.IdentityReference -notmatch "NT AUTHORITY\\SYSTEM" -and
    $_.IdentityReference -notmatch "BUILTIN\\Administrators"
}
if ($others -or $acl.Access.Count -gt 3) {
    Write-Warn "key permissions are too open for OpenSSH - tightening"
    try {
        icacls $IdentityFile /inheritance:r /grant:r "${env:USERNAME}:(R)" | Out-Null
        Write-Ok "permissions fixed"
    } catch {
        Write-Warn "could not fix automatically. Run:"
        Write-Host "           icacls `"$IdentityFile`" /inheritance:r /grant:r `"${env:USERNAME}:(R)`""
    }
} else {
    Write-Ok "permissions look correct"
}

# --- tunnel ----------------------------------------------------------------

$sshArgs = @(
    "-N",                                   # no remote shell, forwarding only
    "-o", "ExitOnForwardFailure=yes",       # fail loudly if the port is taken on the Mac
    "-o", "ServerAliveInterval=30",         # keep NAT mappings warm
    "-o", "ServerAliveCountMax=3",
    "-R", "${RemotePort}:127.0.0.1:${LocalPort}"
)
$sshArgs += @("-i", $IdentityFile, "$User@$MacHost")

Write-Step "6. Tunnel"
Write-Host "  $User@$MacHost : forwarding Mac 127.0.0.1:$RemotePort -> this PC 127.0.0.1:$LocalPort"
Write-Host ""
Write-Host "  On the Mac, now run:  devicelink up" -ForegroundColor White
Write-Host "  Start the bridge BEFORE opening Xcode, or Xcode will not see the phone."
Write-Host "  Press Ctrl+C here to take the phone offline."
Write-Host ""

$attempt = 0
while ($true) {
    $attempt++
    $started = Get-Date
    Write-Host "  [$(Get-Date -Format HH:mm:ss)] connecting (attempt $attempt)..." -ForegroundColor DarkGray

    & ssh @sshArgs
    $code = $LASTEXITCODE

    $seconds = [int]((Get-Date) - $started).TotalSeconds
    if ($NoReconnect) {
        Write-Warn "tunnel closed (exit $code) after ${seconds}s"
        break
    }

    # A tunnel that dies instantly is a config error, not a network blip;
    # backing off avoids hammering the Mac with a broken invocation.
    if ($seconds -lt 5) {
        Write-Fail "tunnel exited immediately (exit $code)"
        Write-Host "         Usually: wrong key/user/host, or port $RemotePort already in use on the Mac."
        Write-Host "         Check on the Mac with: devicelink doctor"
        break
    }

    Write-Warn "tunnel dropped after ${seconds}s - reconnecting in 5s"
    Start-Sleep -Seconds 5
}
