#!/usr/bin/env bash
# Role: hpc-bench - builds the STREAM and OSU Micro-Benchmarks on this node.
# Use it together with hpc-compute (OpenMPI). Run the benchmarks and get a
# report from your workstation with `make bench`.
#
# Settings (role.env):
#   STREAM_ARRAY_SIZE  elements per STREAM array (default: 20000000, about 480 MB for
#                      the three arrays). Rule: each array at least 4x the CPU's
#                      last-level cache, so the test measures RAM, not cache.
#   OSU_VERSION        OSU Micro-Benchmarks release (default: 7.5.2)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

BENCH_DIR=/opt/hpc-bench
STREAM_ARRAY_SIZE=${STREAM_ARRAY_SIZE:-20000000}
OSU_VERSION=${OSU_VERSION:-7.5.2}
STREAM_URL=https://www.cs.virginia.edu/stream/FTP/Code/stream.c
OSU_URL=https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz

apt-get install -y -q build-essential openmpi-bin libopenmpi-dev
install -d -m 0755 "${BENCH_DIR}/bin" "${BENCH_DIR}/src"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# --- STREAM: sustainable memory bandwidth (OpenMP, all cores) -----------------
echo "hpc-bench: building STREAM (array size ${STREAM_ARRAY_SIZE})"
curl -fsSL -o "${BENCH_DIR}/src/stream.c" "${STREAM_URL}"
gcc -O3 -march=native -fopenmp -mcmodel=medium \
    -DSTREAM_ARRAY_SIZE="${STREAM_ARRAY_SIZE}" -DNTIMES=10 \
    "${BENCH_DIR}/src/stream.c" -o "${BENCH_DIR}/bin/stream"

# --- OSU Micro-Benchmarks: MPI latency and bandwidth --------------------------
echo "hpc-bench: building OSU Micro-Benchmarks ${OSU_VERSION}"
curl -fsSL -o "${work}/osu.tar.gz" "${OSU_URL}"
tar -xzf "${work}/osu.tar.gz" -C "${work}"
cd "${work}/osu-micro-benchmarks-${OSU_VERSION}"
./configure CC=mpicc CXX=mpicxx --prefix="${BENCH_DIR}/osu" > "${work}/configure.log" 2>&1 ||
  { tail -n 30 "${work}/configure.log" >&2; exit 1; }
make -j"$(nproc)" > "${work}/make.log" 2>&1 ||
  { tail -n 30 "${work}/make.log" >&2; exit 1; }
make install > /dev/null

# The install layout differs between OSU releases, so find the binaries
for test in osu_latency osu_bw osu_bibw; do
  bin=$(find "${BENCH_DIR}/osu" -type f -name "${test}" -perm -u+x -print -quit)
  [[ -n ${bin} ]] || { echo "hpc-bench: ${test} not found after the build" >&2; exit 1; }
  ln -sf "${bin}" "${BENCH_DIR}/bin/${test}"
done

cat > "${BENCH_DIR}/build-info" <<EOF
STREAM_ARRAY_SIZE=${STREAM_ARRAY_SIZE}
OSU_VERSION=${OSU_VERSION}
BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "hpc-bench: STREAM and OSU ${OSU_VERSION} ready in ${BENCH_DIR}/bin"
