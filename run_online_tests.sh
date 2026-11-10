#!/bin/sh
# Tests that need internet access, kept out of run_tests.sh (which runs with
# networking disabled). Currently: rr+wss against wstest2.wasontech.com.
set -e
cd "$(dirname "$0")"
IMAGE=rr-racket-dev
podman image exists "$IMAGE" || podman build -t "$IMAGE" .
exec podman run --rm -v "$PWD":/work:Z "$IMAGE" sh -c '
  raco make robotraconteur/main.rkt test/test-wss-online.rkt
  raco test test/test-wss-online.rkt
'
