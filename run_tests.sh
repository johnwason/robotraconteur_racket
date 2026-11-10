#!/bin/sh
# Run the integration tests inside the dev container with networking disabled
# (only the container's own loopback interface is available).
# The full suite runs once per transport (rr+tcp, rr+ws, rr+wss through a
# local TLS relay with a throwaway certificate, and rrs+tcp against a secure
# service using a throwaway Robot Raconteur-style PKI), each against a fresh
# service, then
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
            test/test-wss.rkt test/test-rrs.rkt test/servicetest/*.rkt
  status=0
  wait_ready() {
    for i in $(seq 1 100); do grep -q READY $1 && return 0; sleep 0.1; done
    cat $1; return 1
  }
  run_suite() {
    name=$1; port=$2; url=$3
    log=/tmp/service_$name.log
    python3 test/test_service.py $port > $log 2>&1 &
    pid=$!
    wait_ready $log || return 1
    echo "==== transport: $name ($url) ===="
    RR_TEST_URL="$url" raco test test/test-client.rkt || status=1
    kill $pid 2>/dev/null || true
    echo "---- service log ($name) ----"
    cat $log
  }
  run_suite tcp 22222 "rr+tcp://127.0.0.1:22222/?service=test"
  run_suite ws  22223 "rr+ws://127.0.0.1:22223/?service=test"

  # rr+wss: a TLS relay (standing in for a reverse proxy) in front of the
  # rr+ws service, with a self-signed certificate valid for DNS:localhost only
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
          -subj /CN=localhost -addext subjectAltName=DNS:localhost \
          -keyout /tmp/wss.key -out /tmp/wss.pem 2>/dev/null
  python3 test/test_service.py 22224 > /tmp/service_wss.log 2>&1 &
  wss_pid=$!
  python3 test/tls_proxy.py 22443 22224 /tmp/wss.pem /tmp/wss.key > /tmp/tls_proxy.log 2>&1 &
  proxy_pid=$!
  wait_ready /tmp/service_wss.log && wait_ready /tmp/tls_proxy.log || status=1
  echo "==== transport: wss (rr+wss://localhost:22443 via TLS relay) ===="
  RR_TEST_URL="rr+wss://localhost:22443/?service=test" RR_TEST_CA=/tmp/wss.pem \
    raco test test/test-client.rkt || status=1
  echo "==== wss certificate checks ===="
  RR_WSS_PORT=22443 RR_TEST_CA=/tmp/wss.pem raco test test/test-wss.rkt || status=1
  kill $wss_pid $proxy_pid 2>/dev/null || true

  # rrs+tcp: secure services (TLS required) with certificates from a test PKI
  # shaped like the Robot Raconteur node PKI; one server per certificate case
  ID_GOOD={11111111-2222-3333-4444-555555555555}
  ID_WRONGCN={22222222-2222-3333-4444-555555555555}
  ID_NOOID={33333333-2222-3333-4444-555555555555}
  ID_EXTRAEXT={44444444-2222-3333-4444-555555555555}
  test/make_test_pki.sh /tmp/pki $ID_GOOD $ID_WRONGCN $ID_NOOID $ID_EXTRAEXT
  rrs_pids=""
  start_secure() {
    name=$1; port=$2; id=$3
    ROBOTRACONTEUR_SYSTEM_CONFIG_DIR=/tmp/pki/$name ROBOTRACONTEUR_USER_CONFIG_DIR=/tmp/pki/$name \
      RR_TEST_TLS_NODEID=$id python3 test/test_service.py $port > /tmp/service_rrs_$name.log 2>&1 &
    rrs_pids="$rrs_pids $!"
    wait_ready /tmp/service_rrs_$name.log || status=1
  }
  start_secure good     22225 $ID_GOOD
  start_secure wrongcn  22226 $ID_WRONGCN
  start_secure nooid    22227 $ID_NOOID
  start_secure extraext 22228 $ID_EXTRAEXT
  echo "==== transport: rrs+tcp (rrs+tcp://127.0.0.1:22225, test PKI) ===="
  RR_TEST_URL="rrs+tcp://127.0.0.1:22225/?service=test" RR_TEST_TLS_ROOT=/tmp/pki/root.pem \
    raco test test/test-client.rkt || status=1
  echo "==== rrs+tcp certificate checks ===="
  RR_TEST_TLS_ROOT=/tmp/pki/root.pem RR_RRS_GOOD="22225 $ID_GOOD" RR_RRS_WRONGCN="22226 $ID_WRONGCN" \
    RR_RRS_NOOID="22227 $ID_NOOID" RR_RRS_EXTRAEXT="22228 $ID_EXTRAEXT" \
    raco test test/test-rrs.rkt || status=1
  kill $rrs_pids 2>/dev/null || true

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
