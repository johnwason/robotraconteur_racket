#!/bin/sh
# Run the integration tests inside the dev container with networking disabled
# (only the container's own loopback interface is available).
set -e
cd "$(dirname "$0")"
IMAGE=rr-racket-dev
podman image exists "$IMAGE" || podman build -t "$IMAGE" .
exec podman run --rm --network none -v "$PWD":/work:Z "$IMAGE" sh -c '
  set -e
  raco make robotraconteur/main.rkt test/test-client.rkt
  python3 test/test_service.py 22222 > /tmp/service.log 2>&1 &
  for i in $(seq 1 100); do grep -q READY /tmp/service.log && break; sleep 0.1; done
  grep -q READY /tmp/service.log || { cat /tmp/service.log; exit 1; }
  status=0
  raco test test/test-client.rkt || status=$?
  echo "---- service log ----"
  cat /tmp/service.log
  exit $status
'
