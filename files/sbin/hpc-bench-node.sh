#!/usr/bin/env bash
# hpc-bench-node - node-side helper used by scripts/benchmark.sh.
# Needs the hpc-bench role. Results go to stdout as CSV, raw tool output to stderr.
#
#   hpc-bench-node info                      system facts, one key=value per line
#   hpc-bench-node stream                    STREAM: function,best_rate_mbs
#   hpc-bench-node osu TEST local            OSU TEST (latency|bw|bibw), 2 ranks on this node
#   hpc-bench-node osu TEST PEER_IP KEYFILE  OSU TEST, 1 rank here + 1 rank on PEER_IP over TCP
set -euo pipefail

BENCH_DIR=${BENCH_DIR:-/opt/hpc-bench}

die() { echo "hpc-bench-node: $*" >&2; exit 1; }
need() { [[ -x ${BENCH_DIR}/bin/$1 ]] || die "${BENCH_DIR}/bin/$1 missing: apply the hpc-bench role first"; }

cmd_info() {
  # shellcheck disable=SC1091
  . /etc/golden-image-release 2>/dev/null || true
  # shellcheck disable=SC1091
  . "${BENCH_DIR}/build-info" 2>/dev/null || true
  echo "hostname=$(hostname)"
  echo "cpu_model=$(lscpu | awk -F: '/^Model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}')"
  echo "cpus=$(nproc)"
  echo "memory_gb=$(awk '/^MemTotal/ {printf "%.1f", $2 / 1048576}' /proc/meminfo)"
  echo "kernel=$(uname -r)"
  echo "tuned_profile=$(tuned-adm active 2>/dev/null | awk -F': ' '{print $2}')"
  echo "thp=$(sed -E 's/.*\[(.*)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
  echo "image=${IMAGE_VERSION:-unknown}"
  echo "stream_array_size=${STREAM_ARRAY_SIZE:-unknown}"
  echo "osu_version=${OSU_VERSION:-unknown}"
}

cmd_stream() {
  need stream
  export OMP_NUM_THREADS=${OMP_NUM_THREADS:-$(nproc)}
  export OMP_PROC_BIND=${OMP_PROC_BIND:-spread} OMP_PLACES=${OMP_PLACES:-cores}
  local out
  out=$("${BENCH_DIR}/bin/stream")
  printf '%s\n' "${out}" >&2
  awk '/^(Copy|Scale|Add|Triad):/ {sub(":", "", $1); print $1 "," $2}' <<<"${out}"
}

cmd_osu() {
  local test=${1:?test: latency, bw or bibw} peer=${2:?peer IP or local} key=${3:-}
  need "osu_${test}"
  local -a mpi=(mpirun -np 2 --mca pml ob1 --mca btl_base_warn_component_unused 0)
  if [[ ${peer} == local ]]; then
    # Shared-memory path inside one node: the best case MPI can reach
    mpi+=(--oversubscribe --host "localhost:2" --mca btl "self,vader")
  else
    [[ -r ${key} ]] || die "SSH key ${key} not readable"
    local cidr self_ip
    cidr=$(ip -o -4 route show scope link | awk '{print $1; exit}')
    self_ip=$(ip -o -4 route get "${peer}" | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')
    mpi+=(--host "${self_ip}:1,${peer}:1"
          --mca btl "self,tcp" --mca btl_tcp_if_include "${cidr}" --mca oob_tcp_if_include "${cidr}"
          --mca plm_rsh_args "-i ${key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR")
  fi
  local out
  out=$("${mpi[@]}" "${BENCH_DIR}/bin/osu_${test}")
  printf '%s\n' "${out}" >&2
  awk '!/^#/ && NF >= 2 && $1 ~ /^[0-9]+$/ {print $1 "," $2}' <<<"${out}"
}

case ${1:-} in
  info)   cmd_info ;;
  stream) cmd_stream ;;
  osu)    shift; cmd_osu "$@" ;;
  *)      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
