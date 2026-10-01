#!/usr/bin/env bash
# benchmark.sh - run STREAM and OSU on clones with the hpc-bench role and write a report.
#
#   STREAM  runs on every node: sustainable memory bandwidth.
#   OSU     latency + bandwidth between the first two nodes (MPI over TCP), and
#           inside the first node (shared memory) as the best-case reference.
# A temporary SSH key lets node 1 start an MPI rank on node 2; it is removed
# from both nodes when the run ends, even if it fails.
#
# Usage:  ./scripts/benchmark.sh                          # hpc-bench nodes from deploy/kvm/hosts.csv
#         ./scripts/benchmark.sh 10.10.20.31 10.10.20.32  # explicit node IPs
#         LABEL=after-tuning ./scripts/benchmark.sh       # name the run
# Output: reports/bench-<date>-<time>[-<label>]/  report.md, *.csv, raw/
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
HOSTS_FILE=${HOSTS_FILE:-${REPO_ROOT}/deploy/kvm/hosts.csv}
ADMIN_USER=${ADMIN_USER:-ops}
LABEL=${LABEL:-}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR=${OUT_DIR:-${REPO_ROOT}/reports/bench-${STAMP}${LABEL:+-${LABEL}}}
REPORT_SIZES=(1 8 64 512 4096 32768 262144 1048576 4194304)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

log() { printf '[bench] %s\n' "$*" >&2; }
die() { printf '[bench] ERROR: %s\n' "$*" >&2; exit 1; }
# The arguments form the command run ON the node, so they are meant to expand there
# shellcheck disable=SC2029
on()  { local host=$1; shift; ssh "${SSH_OPTS[@]}" "${ADMIN_USER}@${host}" "$@"; }

[[ ${LABEL} =~ ^[A-Za-z0-9._-]*$ ]] || die "LABEL may only use letters, digits, '.', '_' and '-'"

# --- Nodes ------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  hosts=("$@")
else
  mapfile -t hosts < <(awk -F, '!/^[[:space:]]*#/ && NF >= 6 && $2 != "dhcp" && $6 ~ /(^|\+)hpc-bench(\+|$|\r)/ {
                                  split($2, a, "/"); print a[1] }' "${HOSTS_FILE}")
fi
[[ ${#hosts[@]} -ge 1 ]] || die "no nodes: pass IPs, or give nodes the hpc-bench role in ${HOSTS_FILE}"
node_a=${hosts[0]}
node_b=${hosts[1]:-}

mkdir -p "${OUT_DIR}/raw"
log "Writing results to ${OUT_DIR}"

# --- 1. System facts ----------------------------------------------------------
echo 'node,hostname,cpu_model,cpus,memory_gb,kernel,tuned_profile,thp,image,stream_array_size,osu_version' \
  > "${OUT_DIR}/system.csv"
declare -A host_name=()
for host in "${hosts[@]}"; do
  info=$(on "${host}" hpc-bench-node info) || die "${host}: cannot run hpc-bench-node (is the hpc-bench role applied?)"
  declare -A f=()
  while IFS='=' read -r key value; do
    if [[ -n ${key} ]]; then f[${key}]=${value//,/ }; fi
  done <<<"${info}"
  host_name[${host}]=${f[hostname]:-${host}}
  printf '%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s\n' "${host}" "${f[hostname]:-}" "${f[cpu_model]:-}" \
    "${f[cpus]:-}" "${f[memory_gb]:-}" "${f[kernel]:-}" "${f[tuned_profile]:-}" "${f[thp]:-}" \
    "${f[image]:-}" "${f[stream_array_size]:-}" "${f[osu_version]:-}" >> "${OUT_DIR}/system.csv"
  unset f
done

# --- 2. STREAM on every node --------------------------------------------------
echo 'node,hostname,function,best_rate_mbs' > "${OUT_DIR}/stream.csv"
for host in "${hosts[@]}"; do
  log "STREAM on ${host_name[${host}]} (${host})"
  on "${host}" hpc-bench-node stream 2> "${OUT_DIR}/raw/stream-${host}.log" |
    awk -F, -v n="${host}" -v h="${host_name[${host}]}" 'NF == 2 {print n "," h "," $1 "," $2}' \
    >> "${OUT_DIR}/stream.csv" || die "STREAM failed on ${host}, see ${OUT_DIR}/raw/stream-${host}.log"
done

# --- 3. OSU latency and bandwidth ---------------------------------------------
echo 'path,size_bytes,latency_us' > "${OUT_DIR}/osu_latency.csv"
echo 'path,size_bytes,bandwidth_mbs' > "${OUT_DIR}/osu_bw.csv"

run_osu() {  # run_osu <path label> <peer|local> [key]
  local path=$1 peer=$2 key=${3:-} test
  for test in latency bw; do
    log "OSU ${test}, ${path}"
    on "${node_a}" hpc-bench-node osu "${test}" "${peer}" "${key}" 2> "${OUT_DIR}/raw/osu_${test}-${path}.log" |
      awk -F, -v p="${path}" 'NF == 2 {print p "," $1 "," $2}' >> "${OUT_DIR}/osu_${test}.csv" ||
      die "OSU ${test} (${path}) failed, see ${OUT_DIR}/raw/osu_${test}-${path}.log"
  done
}

run_osu intra-node local

KEY_DIR=""
cleanup_key() {
  [[ -n ${KEY_DIR} ]] || return 0
  local host
  for host in "${node_a}" "${node_b}"; do
    on "${host}" "sed -i '/hpc-bench-temp/d' ~/.ssh/authorized_keys; rm -f ~/.ssh/hpc-bench-key" || true
  done
  rm -rf "${KEY_DIR}"
  KEY_DIR=""
}
trap cleanup_key EXIT

if [[ -n ${node_b} ]]; then
  log "Installing a temporary SSH key so ${host_name[${node_a}]} can start MPI ranks on ${host_name[${node_b}]}"
  KEY_DIR=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C "hpc-bench-temp-${STAMP}" -f "${KEY_DIR}/key"
  pub=$(<"${KEY_DIR}/key.pub")
  for host in "${node_a}" "${node_b}"; do
    on "${host}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pub}' >> ~/.ssh/authorized_keys"
  done
  on "${node_a}" 'umask 077 && cat > ~/.ssh/hpc-bench-key' < "${KEY_DIR}/key"
  # shellcheck disable=SC2088  # ~ must expand on the node, not here
  run_osu inter-node "${node_b}" '~/.ssh/hpc-bench-key'
  cleanup_key
else
  log "Only one node: skipping the between-nodes OSU tests"
fi

# --- 4. Report ----------------------------------------------------------------
commas() {  # 21037.4 -> 21,037 · small values keep decimals: 4.25, 38.6
  awk -v n="$1" 'BEGIN { if (n !~ /^[0-9.]+$/) { print n; exit }
    if (n < 10) { printf "%.2f\n", n; exit } if (n < 100) { printf "%.1f\n", n; exit }
    s = sprintf("%.0f", n); r = ""; while (length(s) > 3) { r = "," substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) } print s r }'; }
human_size() { awk -v b="$1" 'BEGIN { if (b >= 1048576) printf "%g MB", b / 1048576; else if (b >= 1024) printf "%g KB", b / 1024; else printf "%d B", b }'; }
value_at() {  # value_at <csv> <path> <size> -> value or "-"
  awk -F, -v p="$2" -v s="$3" '$1 == p && $2 == s {v = $3} END {print (v == "" ? "-" : v)}' "$1"
}
stream_value() {  # stream_value <node> <function>
  awk -F, -v n="$1" -v fn="$2" '$1 == n && $3 == fn {v = $4} END {print (v == "" ? "-" : v)}' "${OUT_DIR}/stream.csv"
}

read -r triad_avg triad_min triad_max triad_n < <(awk -F, '$3 == "Triad" {s += $4; n++; if (min == "" || $4 < min) min = $4; if ($4 > max) max = $4}
  END {if (n) printf "%.0f %.0f %.0f %d\n", s / n, min, max, n; else print "- - - 0"}' "${OUT_DIR}/stream.csv")
read -r peak_bw peak_size < <(awk -F, '$1 == "inter-node" && $3 > max {max = $3; size = $2}
  END {if (max != "") print max, size; else print "- -"}' "${OUT_DIR}/osu_bw.csv")
image=$(awk -F, 'NR == 2 {print $(NF - 2)}' "${OUT_DIR}/system.csv")
array_size=$(awk -F, 'NR == 2 {print $(NF - 1)}' "${OUT_DIR}/system.csv")
pair="${host_name[${node_a}]}"${node_b:+ and ${host_name[${node_b}]:-}}

report="${OUT_DIR}/report.md"
{
  echo "# HPC benchmark report"
  echo
  echo "**Run:** $(date -u '+%Y-%m-%d %H:%M UTC') · **Label:** ${LABEL:-none} · **Image:** ${image:-unknown} · **Nodes:** ${#hosts[@]}"
  echo
  echo "## Summary"
  echo
  echo "- **Memory bandwidth (STREAM Triad):** $(commas "${triad_avg}") MB/s average over ${triad_n} node(s), min $(commas "${triad_min}"), max $(commas "${triad_max}")"
  inter_8=$(value_at "${OUT_DIR}/osu_latency.csv" inter-node 8)
  [[ ${inter_8} == "-" ]] && inter_8="not measured (needs 2 nodes)" || inter_8="${inter_8} us"
  echo "- **MPI latency, 8 B messages:** $(value_at "${OUT_DIR}/osu_latency.csv" intra-node 8) us inside one node, ${inter_8} between nodes"
  if [[ ${peak_bw} != "-" ]]; then
    echo "- **MPI peak bandwidth between nodes:** $(commas "${peak_bw}") MB/s at $(human_size "${peak_size}") messages"
  fi
  echo
  echo "## Nodes"
  echo
  echo "| Node | Hostname | CPU | vCPUs | RAM (GB) | Kernel | tuned profile | THP |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
  awk -F'"' 'NR > 1 {split($1, a, ","); split($3, b, ",");
    printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", a[1], a[2], $2, b[2], b[3], b[4], b[5], b[6]}' "${OUT_DIR}/system.csv"
  echo
  echo "## STREAM memory bandwidth (MB/s, higher is better)"
  echo
  echo "Best rate of 10 runs, all vCPUs (OpenMP), ${array_size:-unknown} elements per array."
  echo
  echo "| Node | Copy | Scale | Add | Triad |"
  echo "| --- | --- | --- | --- | --- |"
  for host in "${hosts[@]}"; do
    printf '| %s | %s | %s | %s | %s |\n' "${host_name[${host}]}" \
      "$(commas "$(stream_value "${host}" Copy)")" "$(commas "$(stream_value "${host}" Scale)")" \
      "$(commas "$(stream_value "${host}" Add)")" "$(commas "$(stream_value "${host}" Triad)")"
  done
  echo
  echo "## OSU MPI latency (microseconds, lower is better)"
  echo
  echo "Inside one node: 2 ranks on ${host_name[${node_a}]}, shared memory. Between nodes: ${pair}, TCP."
  echo
  echo "| Message size | Inside one node | Between nodes |"
  echo "| --- | --- | --- |"
  for size in "${REPORT_SIZES[@]}"; do
    printf '| %s | %s | %s |\n' "$(human_size "${size}")" \
      "$(value_at "${OUT_DIR}/osu_latency.csv" intra-node "${size}")" \
      "$(value_at "${OUT_DIR}/osu_latency.csv" inter-node "${size}")"
  done
  echo
  echo "## OSU MPI bandwidth (MB/s, higher is better)"
  echo
  echo "| Message size | Inside one node | Between nodes |"
  echo "| --- | --- | --- |"
  for size in "${REPORT_SIZES[@]}"; do
    printf '| %s | %s | %s |\n' "$(human_size "${size}")" \
      "$(commas "$(value_at "${OUT_DIR}/osu_bw.csv" intra-node "${size}")")" \
      "$(commas "$(value_at "${OUT_DIR}/osu_bw.csv" inter-node "${size}")")"
  done
  echo
  echo "## Files"
  echo
  echo "- \`system.csv\`, \`stream.csv\`, \`osu_latency.csv\`, \`osu_bw.csv\`: full results for charts and comparisons"
  echo "- \`raw/\`: unedited tool output"
  echo
  echo "VM results depend on the host hardware and on other VMs sharing it, so compare runs made on the same hosts:"
  echo "\`make bench-compare A=reports/<earlier run> B=reports/$(basename "${OUT_DIR}")\`"
} > "${report}"

log "Report: ${report}"
cat "${report}"
