#!/usr/bin/env python3
"""Classify the state of the bridge in one shot.

"No device" has four distinct causes that need four different fixes, and the
usbmux protocol can tell them apart: whether anything is listening, whether the
far end actually speaks usbmux, and whether it reports any devices.

Prints one state token, then any device serials, one per line.
"""

import plistlib
import socket
import struct
import sys

TUNNEL_DOWN = "TUNNEL_DOWN"    # nothing listening — SSH tunnel from Windows is gone
FAR_END_DEAD = "FAR_END_DEAD"  # port open but no usbmux behind it — AMDS stopped
NO_DEVICE = "NO_DEVICE"        # usbmux answering, zero devices — phone locked/unplugged
READY = "READY"                # at least one device


def probe(port: int, timeout: float = 4.0):
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    except (ConnectionRefusedError, socket.timeout, OSError):
        return TUNNEL_DOWN, []

    try:
        payload = plistlib.dumps({
            "MessageType": "ListDevices",
            "ClientVersionString": "devicelink-probe",
            "ProgName": "devicelink",
        })
        sock.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)

        header = sock.recv(16)
        if len(header) < 16:
            return FAR_END_DEAD, []

        length, _version, _msg, _tag = struct.unpack("<IIII", header)
        body = b""
        while len(body) < length - 16:
            chunk = sock.recv(length - 16 - len(body))
            if not chunk:
                return FAR_END_DEAD, []
            body += chunk

        reply = plistlib.loads(body)
    except Exception:
        return FAR_END_DEAD, []
    finally:
        sock.close()

    serials = []
    for entry in reply.get("DeviceList", []):
        properties = entry.get("Properties", {})
        serial = properties.get("SerialNumber")
        if serial:
            serials.append(serial)

    return (READY, serials) if serials else (NO_DEVICE, [])


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 27015
    state, devices = probe(port)
    print(state)
    for device in devices:
        print(device)
