#!/bin/sh
# Run the integration tests inside the dev container with networking disabled
# (only the container's own loopback interface is available).
# The full suite runs once per transport, each against a fresh service, then
# interop tests run against Reynard the Robot and a loopback AbstractRobot,
# then the ServiceTest ports run against the Robot Raconteur C++ test server
# (built by build_cpp_test_server.sh; skipped if it has not been built).
#
# RR_SRC (default ~/RobotRaconteur2/robotraconteur) is mounted read-only when
# present, to check that test/data/test_vectors.bin matches the checkout.
set -e
cd "$(dirname "$0")"
IMAGE=rr-racket-dev
RR_SRC=${RR_SRC:-$HOME/RobotRaconteur2/robotraconteur}
podman image exists "$IMAGE" || podman build -t "$IMAGE" .
SRC_MOUNT=""
[ -d "$RR_SRC/test/data" ] && SRC_MOUNT="-v $RR_SRC:/src:ro,Z"
exec podman run --rm --network none -v "$PWD":/work:Z $SRC_MOUNT "$IMAGE" sh -c '
  set -e
  raco make robotraconteur/main.rkt test/test-client.rkt test/test-reynard.rkt test/test-robot.rkt \
            test/servicetest/*.rkt
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

  # start a service, wait until its TCP port accepts connections, run a test file
  run_interop() {
    name=$1; port=$2; test=$3; shift 3
    log=/tmp/service_$name.log
    "$@" > $log 2>&1 &
    pid=$!
    ok=0
    for i in $(seq 1 150); do
      if python3 -c "import socket; socket.create_connection((\"127.0.0.1\", $port), 1)" 2>/dev/null; then ok=1; break; fi
      sleep 0.2
    done
    [ $ok = 1 ] || { echo "$name did not start"; cat $log; status=1; return; }
    sleep 1
    echo "==== interop: $name ===="
    raco test $test || status=1
    kill $pid 2>/dev/null || true
  }
  run_interop reynard 29200 test/test-reynard.rkt python3 -m reynard_the_robot --quiet
  run_interop loopback-robot 59926 test/test-robot.rkt python3 test/loopback_robot.py 59926

  # ServiceTest ports against the in-process C++ test server
  echo "==== servicetest: C++ test server ===="
  if [ -f build/rr-cpp/test/out/lib/librobotraconteur_test_server_lib.so ]; then
    if [ -d /src/test/data ]; then
      if cmp -s test/data/test_vectors.bin /src/test/data/test_vectors.bin; then
        echo "test_vectors.bin matches the robotraconteur checkout"
      else
        echo "test_vectors.bin differs from the robotraconteur checkout"; status=1
      fi
    fi
    raco test test/servicetest || status=1
  else
    echo "SKIPPED: C++ test server not built (run ./build_cpp_test_server.sh)"
  fi
  exit $status
'
