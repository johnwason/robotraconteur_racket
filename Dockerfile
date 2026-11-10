# Development/test image for the Racket Robot Raconteur client.
# Contains Racket (the client) and the Python Robot Raconteur reference
# implementation (used only as a test service).
FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        racket python3 python3-pip python3-numpy ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages robotraconteur

WORKDIR /work

# Real-world services used for interop testing: Reynard the Robot and the
# AbstractRobot base class (used by test/loopback_robot.py).
# (pip's numpy is installed alongside Debian's python3-numpy, which pip cannot remove)
RUN pip3 install --no-cache-dir --break-system-packages --ignore-installed numpy \
    && pip3 install --no-cache-dir --break-system-packages \
        reynard-the-robot robotraconteur-abstract-robot robotraconteurcompanion \
        general-robotics-toolbox scipy pyyaml

# Toolchain for building the Robot Raconteur C++ test server
# (robotraconteur_test_server / robotraconteur_test_server_lib) from a
# read-only checkout. See build_cpp_test_server.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake g++ make libboost-all-dev libssl-dev libusb-1.0-0-dev \
        libdbus-1-dev libbluetooth-dev zlib1g-dev libgtest-dev \
    && rm -rf /var/lib/apt/lists/*

# iproute2: discovery tests create a tap interface inside the container's own
# network namespace (podman --network none --cap-add NET_ADMIN --device
# /dev/net/tun) so IPv6 link-local multicast works without touching any
# real network.
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*
