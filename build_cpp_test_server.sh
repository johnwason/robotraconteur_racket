#!/bin/sh
# Build the Robot Raconteur C++ test server (executable and shared library)
# inside the dev container.
#
# The robotraconteur checkout is mounted read-only; all build output goes to
# build/rr-cpp in this repository. Networking is disabled: every dependency
# comes from the image.
#
#   RR_SRC=~/RobotRaconteur2/robotraconteur ./build_cpp_test_server.sh
set -e
cd "$(dirname "$0")"
IMAGE=rr-racket-dev
RR_SRC=${RR_SRC:-$HOME/RobotRaconteur2/robotraconteur}
JOBS=${JOBS:-$(nproc)}
[ -f "$RR_SRC/test/data/test_vectors.bin" ] || { echo "RR_SRC=$RR_SRC is not a robotraconteur checkout with test vectors"; exit 1; }
podman image exists "$IMAGE" || podman build -t "$IMAGE" .
mkdir -p build/rr-cpp
exec podman run --rm --network none \
  -v "$RR_SRC":/src:ro,Z -v "$PWD":/work:Z "$IMAGE" sh -c "
  set -e
  cmake -S /src -B /work/build/rr-cpp -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=ON -DBUILD_GEN=ON -DBUILD_DOCUMENTATION=OFF
  cmake --build /work/build/rr-cpp -j $JOBS \
        --target robotraconteur_test_server_lib robotraconteur_test_server
  find /work/build/rr-cpp -name 'librobotraconteur_test_server_lib.so' -o -name 'robotraconteur_test_server' -type f
"
