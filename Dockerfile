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
