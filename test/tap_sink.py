"""Hold a tap interface open so it has carrier (and an IPv6 link-local
address), discarding every frame written to it.

Usage: python3 tap_sink.py IFNAME

Used by the discovery tests: inside the container's own network namespace
(podman --network none) the tap is a stand-in for a LAN interface. Multicast
sent on it is looped back to local sockets; nothing reaches a real network.
"""
import fcntl
import os
import struct
import sys

TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000

fd = os.open("/dev/net/tun", os.O_RDWR)
fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", sys.argv[1].encode(), IFF_TAP | IFF_NO_PI))
print("READY", flush=True)
while True:
    os.read(fd, 65536)
