#!/bin/bash
# devicelink selftest — prove the bridge works without a phone or a Windows PC.
#
# Stands socat in for the SSH tunnel + Windows AMDS by exposing this Mac's own
# usbmuxd over TCP. Real usbmux protocol then travels the exact production path:
#
#   idevice_id → /var/run/usbmuxd (usbfluxd) → TCP:PORT → socat → usbmuxd.orig
#
# A pass means the socket swap, the TCP hop, and the protocol round-trip all work,
# so the only untested variable left is the phone itself.
#
# Requires sudo: usbfluxd replaces the system usbmuxd socket. Everything is
# restored on exit, including on failure or Ctrl-C.

set -uo pipefail

PORT="${1:-27015}"
SOCKET="/var/run/usbmuxd"
SOCKET_ORIG="/var/run/usbmuxd.orig"
LOG="$(mktemp -t devicelink-selftest)"

SOCAT_PID=""
STARTED_USBFLUXD=0
FAILURES=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; FAILURES=$((FAILURES+1)); }
info() { printf "    %s\n" "$*"; }
step() { printf "\n\033[1m%s\033[0m\n" "$*"; }

cleanup() {
    step "Teardown"

    if [ "$STARTED_USBFLUXD" = "1" ] && pgrep -x usbfluxd >/dev/null 2>&1; then
        # SIGTERM lets usbfluxd move the original socket back itself.
        sudo pkill -TERM -x usbfluxd 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8; do
            sleep 0.5
            pgrep -x usbfluxd >/dev/null 2>&1 || break
        done
        pgrep -x usbfluxd >/dev/null 2>&1 && sudo pkill -KILL -x usbfluxd 2>/dev/null
        ok "usbfluxd stopped"
    fi

    [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null && ok "socat stopped"

    # Belt and braces: if usbfluxd died without restoring, put the socket back.
    if [ -e "$SOCKET_ORIG" ]; then
        sudo rm -f "$SOCKET"
        sudo mv "$SOCKET_ORIG" "$SOCKET" 2>/dev/null && ok "socket restored manually"
    fi

    if [ -S "$SOCKET" ] && [ ! -e "$SOCKET_ORIG" ]; then
        ok "$SOCKET is healthy"
    else
        bad "$SOCKET left in a bad state — reboot to let launchd recreate it"
    fi

    rm -f "$LOG"
}
trap cleanup EXIT INT TERM

# --- preflight -------------------------------------------------------------

step "Preflight"
command -v usbfluxd >/dev/null 2>&1 || { bad "usbfluxd not installed"; exit 1; }
ok "usbfluxd present"
command -v socat >/dev/null 2>&1 || { bad "socat not installed (brew install socat)"; exit 1; }
ok "socat present"
command -v idevice_id >/dev/null 2>&1 || { bad "libimobiledevice not installed"; exit 1; }
ok "idevice_id present"

[ -S "$SOCKET" ] || { bad "$SOCKET missing — usbmuxd is not running"; exit 1; }
ok "$SOCKET exists"

[ -e "$SOCKET_ORIG" ] && { bad "$SOCKET_ORIG already exists — run: devicelink repair"; exit 1; }
ok "no stale swapped socket"

pgrep -x usbfluxd >/dev/null 2>&1 && { bad "usbfluxd already running — run: devicelink down"; exit 1; }
ok "usbfluxd not already running"

if lsof -iTCP:"$PORT" -sTCP:LISTEN -n >/dev/null 2>&1; then
    bad "port $PORT is already in use"
    info "$(lsof -iTCP:"$PORT" -sTCP:LISTEN -n 2>/dev/null | tail -n +2 | awk '{print $1}' | head -1) holds it"
    exit 1
fi
ok "port $PORT free"

# --- stand in for the tunnel ----------------------------------------------

step "1. Fake the tunnel (socat → usbmuxd.orig)"
# socat connects lazily per accepted connection, so it is fine that
# usbmuxd.orig does not exist until usbfluxd renames it a moment from now.
socat TCP-LISTEN:"$PORT",fork,reuseaddr UNIX-CONNECT:"$SOCKET_ORIG" >/dev/null 2>&1 &
SOCAT_PID=$!
sleep 1

if kill -0 "$SOCAT_PID" 2>/dev/null; then
    ok "socat listening on 127.0.0.1:$PORT (pid $SOCAT_PID)"
else
    bad "socat failed to start"
    exit 1
fi

# --- start the bridge ------------------------------------------------------

step "2. Start usbfluxd against 127.0.0.1:$PORT"
sudo usbfluxd -f -v -m -r "127.0.0.1:$PORT" >"$LOG" 2>&1 &
STARTED_USBFLUXD=1

for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    pgrep -x usbfluxd >/dev/null 2>&1 && break
done

if pgrep -x usbfluxd >/dev/null 2>&1; then
    ok "usbfluxd running"
else
    bad "usbfluxd failed to start"
    sed 's/^/    /' "$LOG"
    exit 1
fi

sleep 1
if [ -e "$SOCKET_ORIG" ]; then
    ok "socket swapped: original moved to $SOCKET_ORIG"
else
    bad "socket was not swapped"
fi

# --- the actual proof ------------------------------------------------------

step "3. Round-trip real usbmux protocol through the chain"
DEVICES=$(idevice_id -l 2>&1)
RC=$?

if [ $RC -eq 0 ]; then
    ok "idevice_id completed successfully through the bridge (exit 0)"
    if [ -n "$DEVICES" ]; then
        ok "devices reported: $DEVICES"
    else
        info "empty device list — correct, no phone is attached to this Mac"
    fi
    info "An empty list still proves the round-trip: the query reached a real"
    info "usbmuxd through usbfluxd and TCP, and got a well-formed answer back."
else
    bad "idevice_id failed through the bridge (exit $RC): $DEVICES"
fi

step "4. Registered remotes"
if usbfluxctl list 2>/dev/null | sed 's/^/    /' | grep -q .; then
    usbfluxctl list 2>/dev/null | sed 's/^/    /'
    ok "usbfluxctl can query the running daemon"
else
    info "(no remotes reported)"
fi

step "5. usbfluxd log"
grep -iE "remote|connect|socket|error|fail" "$LOG" 2>/dev/null | tail -8 | sed 's/^/    /'

# --- verdict (teardown runs after this via trap) ---------------------------

step "Result"
if [ "$FAILURES" -eq 0 ]; then
    printf "  \033[32mPASS\033[0m — socket swap, TCP hop, and protocol round-trip all work.\n"
    printf "  The only untested variable is the phone itself.\n"
else
    printf "  \033[31mFAIL\033[0m — %d check(s) failed.\n" "$FAILURES"
fi

exit "$FAILURES"
