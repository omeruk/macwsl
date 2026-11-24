#!/usr/bin/python3 -I
"""A DNS server for checking split DNS without a VPN (prompts/08-networking.md, pull request B).

It answers on 127.0.0.1, UDP port 53535, only: every name under maw-check.internal has the
address 192.0.2.53 (TEST-NET-1, RFC 5737), and every other query is refused. Python's standard
library only; run it with Apple's /usr/bin/python3 and stop it with Ctrl-C.

macOS asks it only while a scoped resolver file sends that domain here. To add the file, which
needs an administrator's password:

    sudo mkdir -p /etc/resolver
    printf 'nameserver 127.0.0.1\\nport 53535\\n' | sudo tee /etc/resolver/maw-check.internal

To remove it afterwards:

    sudo rm /etc/resolver/maw-check.internal

Then, on the Mac, `dscacheutil -q host -a name probe.maw-check.internal` and, in a
distribution, `getent hosts probe.maw-check.internal` print 192.0.2.53 while the file and this
server are there, and nothing after the file is removed.

Usage: /usr/bin/python3 -I scripts/dns-test-responder.py
"""

import socket
import struct

DOMAIN = ("maw-check", "internal")
ADDRESS = bytes([192, 0, 2, 53])


def answer(query):
    """The response to one query, or None for a message that gets none."""
    if len(query) < 12 or query[2] & 0x80:
        return None
    labels = []
    offset = 12
    while offset < len(query) and query[offset] != 0:
        length = query[offset]
        if length > 63 or offset + 1 + length > len(query):
            return None
        labels.append(query[offset + 1 : offset + 1 + length].decode("ascii", "replace").lower())
        offset += 1 + length
    if offset + 5 > len(query):
        return None
    question = query[12 : offset + 5]
    qtype, qclass = struct.unpack("!HH", query[offset + 1 : offset + 5])
    flags = 0x8400 | (query[2] << 8 & 0x0100)  # QR, AA, RD copied
    if tuple(labels[-2:]) != DOMAIN or qclass != 1:
        return query[:2] + struct.pack("!HHHHH", flags | 5, 1, 0, 0, 0) + question
    if qtype != 1:
        return query[:2] + struct.pack("!HHHHH", flags, 1, 0, 0, 0) + question
    record = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + ADDRESS
    return query[:2] + struct.pack("!HHHHH", flags, 1, 1, 0, 0) + question + record


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 53535))
    print("dns-test-responder: answering maw-check.internal on 127.0.0.1:53535", flush=True)
    try:
        while True:
            query, peer = server.recvfrom(4096)
            response = answer(query)
            if response is not None:
                server.sendto(response, peer)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
