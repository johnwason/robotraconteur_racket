#!/bin/sh
# Run the integration tests inside the dev container with networking disabled
# (only the container's own loopback interface is available).
# The full suite runs once per transport, each against a fresh service.
set -e
cd "$(dirname "$0")"
IMAGE=rr-racket-dev
podman image exists "$IMAGE" || podman build -t "$IMAGE" .
exec podman run --rm --network none -v "$PWD":/work:Z "$IMAGE" sh -c '
  set -e
  raco make robotraconteur/main.rkt test/test-client.rkt
  status=0
  run_suite() {
    name=$1; port=$2; url=$3
    log=/tmp/service_$name.log
    python3 test/test_service.py $port > $log 2>&1 &
    pid=$!
    for i in $(seq 1 100); do grep -q READY $log && break; sleep 0.1; done
    grep -q READY $log || { cat $log; return 1; }
    echo "==== transport: $name ($url) ===="
    RR_TEST_URL="$url" raco test test/test-client.rkt || status=1
    kill $pid 2>/dev/null || true
    echo "---- service log ($name) ----"
    cat $log
  }
  run_suite tcp 22222 "rr+tcp://127.0.0.1:22222/?service=test"
  run_suite ws  22223 "rr+ws://127.0.0.1:22223/?service=test"
  exit $status
'
